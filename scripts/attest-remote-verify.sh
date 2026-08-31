#!/bin/bash
# attest-remote-verify.sh — Remote TPM Attestation Verifier
# Secure Embedded Platform PoC — Phase 2
#
# Challenges a remote device (the RPi, over SSH) for a TPM quote covering
# PCR 1 (U-Boot bootargs), PCR 8 (U-Boot kernel image), and PCR 10 (kernel
# IMA userspace measurements), then verifies:
#   - the quote is genuinely signed by that device's AK (0x81000002,
#     provisioned in Phase 1) — proves device identity, not just "a" TPM
#   - the nonce matches what was sent (anti-replay — without this, a
#     recorded quote could be replayed forever as if freshly generated)
#   - PCR 1/8 match this project's known golden baseline (deterministic,
#     see phase2/README.md's Measured Boot section)
#   - PCR 10 is reported and compared against a locally-captured baseline,
#     but a mismatch is a WARNING, not a failure — IMA measures every
#     executed program, so PCR 10 legitimately changes as the device is
#     used. There is no single fixed "golden" PCR 10 the way PCR 1/8 have
#     one; see phase2/README.md's IMA section.
#
# PCR values are decoded directly from the quote's own PCR output file
# (tpm2_quote -F values: just the selected digests, concatenated, in PCR
# order, no struct/header framing) rather than a separate tpm2_pcrread
# call — verified via tpm2_checkquote's -l flag, which makes it parse that
# same headerless format instead of the default self-describing one
# (confirmed by reading tpm2-tools 5.7's actual source,
# tools/misc/tpm2_checkquote.c — parse_selection_data_from_selection_string
# vs parse_selection_data_from_file). This closes a real gap an earlier
# version of this script had: reading PCR values via a second, independent,
# unverified command instead of the file that was already cryptographically
# checked against the signed quote digest two steps earlier.
#
# EK provenance IS validated (added 2026-08-30): on first enrollment, this
# script fetches the device's real EK certificate over SSH and verifies it
# chains to Infineon's manufacturer CA — the same standard-form chain a
# browser does for TLS, just with Infineon's OPTIGA TPM root instead of a
# public web CA. This proves "genuine Infineon-manufactured TPM", not a
# software TPM or a clone. The EK cert's embedded public key is then
# cross-checked against the live EK at 0x81010001, so a verified cert can't
# be replayed against a different device's EK.
#
# NOTE on chain files: certs/infineon_{rsa,ecc}_chain_ca042.pem in this repo
# are specific to THIS device's SLB9670 (Xenon board) — its EK certs are
# issued by Infineon's "CA 042" batch, chaining to the older
# "OptigaRsaRootCA"/"OptigaEccRootCA" (no "2" suffix). This is genuinely
# different from certs/infineon_{rsa,ecc}_chain.pem (CA 066 / "...Root CA 2"),
# which is Phase 1's separate SLB9673 I2C HAT — a different physical chip
# with its own unique EK and its own CA generation. Confirmed by extracting
# and inspecting both real certs, not assumed — see phase2/README.md's
# Remote Attestation section for the full story.
#
# Deliberately NOT implemented: full TPM2_ActivateCredential-based proof
# that the AK is resident in the SAME TPM as the verified EK (the standard
# TCG credential-activation protocol — see TPM2_MakeCredential/
# TPM2_ActivateCredential in the spec). Attempted on real hardware and hit a
# reproducible, silent failure in tpm2-tools' credential-activation code
# (`tpm2_makecredential`, tool_rc_general_error/-2 with zero diagnostic
# output even under TSS2_LOG=esys+trace) — confirmed on both tpm2-tools 5.2
# (this verifier machine) and 5.7 (the Pi), via both the offline PEM+-G path
# and the online ESAPI path (loading the EK as an external object on a real
# TPM and calling Esys_MakeCredential directly) — same silent failure both
# ways, so it isn't a config or version mismatch on this project's end. What
# IS proven instead: EK provenance (this is a genuine Infineon chip, not a
# clone) via the cert-chain check above. What's still missing: cryptographic
# proof that the specific AK used for quotes lives inside that exact chip
# (currently trust-on-first-use for the AK itself, same as before). A real
# deployment would either resolve the tpm2-tools issue or reimplement
# MakeCredential's RSA-OAEP+HMAC/AES-CFB blob construction directly against
# the TCG spec.
#
# Usage:
#   ./attest-remote-verify.sh <pi-host-or-ip> [ak-pub-file]
#
# Requires: tpm2-tools, openssl, ssh/scp, xxd — on THIS machine (the
# verifier), not the Pi. Verification must never run on the device being
# verified — a compromised device could just lie about its own
# verification result.
#
# Every device-side tpm2-tools call below is pinned to
# --tcti=device:/dev/tpmrm0. Without it, tpm2-tools tries the tabrmd TCTI
# (talks to tpm2-abrmd over D-Bus) first and only falls back to the device
# on failure — this image has no D-Bus daemon at all (busybox init, no
# systemd), so that first attempt always fails with a noisy
# "failed to allocate dbus proxy object" error before silently succeeding
# via the fallback. tpm2-abrmd itself runs fine; it just can't be reached
# this way on this image. Pinning the TCTI skips the doomed first attempt
# entirely instead of just hiding its output.

set -euo pipefail

PI_HOST="${1:?Usage: $0 <pi-host-or-ip> [ak-pub-file]}"
AK_PUB="${2:-./ak_public.pem}"
AK_HANDLE="0x81000002"
EK_HANDLE="0x81010001"
PCR_LIST="sha256:1,8,10"
WORK_DIR="$(mktemp -d)"
GOLDEN_DIR="${HOME}/.tpm-poc-rpi-attest"
GOLDEN_PCR10="${GOLDEN_DIR}/pcr10-golden.txt"

# This device's SLB9670 EK certs chain to Infineon's "CA 042" batch, not the
# "CA 066" batch Phase 1's separate SLB9673 HAT uses — see the header
# comment. Resolved relative to this script's own location so it works
# regardless of the caller's current directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RSA_CHAIN_PEM="${SCRIPT_DIR}/../certs/infineon_rsa_chain_ca042.pem"
ECC_CHAIN_PEM="${SCRIPT_DIR}/../certs/infineon_ecc_chain_ca042.pem"

# Verified golden baseline for PCR 1/8 — see phase2/README.md, confirmed
# identical across two genuine power cycles, 2026-08-29. These change only
# if the boot chain itself changes (new kernel, new bootargs, new U-Boot
# build) — update here if that ever happens deliberately.
#
# Re-baselined 2026-08-29 (same day): the original values above were
# captured before the IMA work landed. Adding ima_policy=tcb to the kernel
# command line changed bootargs (PCR 1), and the kernel rebuild to add
# CONFIG_IMA=y etc. changed the kernel image itself (PCR 8) — both
# legitimate, expected changes to the actual boot chain, not drift or
# tampering. First caught by this very script correctly flagging a
# mismatch against the stale baseline; the new values were then confirmed
# identical across two genuine power cycles before being trusted here,
# same standard as the original baseline.
GOLDEN_PCR1="0x1872401838DC0197D6499A2950DD20A9400067441ED311E37095A9725B1B2AC8"
GOLDEN_PCR8="0x208261DF4C05E875E696FBEF1A4801FA9C13A3F9C6B3680967647196F3815708"

# accept-new: trust a genuinely new host key on first contact (no
# interactive prompt, needed for this script to run non-interactively) but
# still loudly fail — the real MITM protection — if an *already-trusted*
# key for this host suddenly changes. The device regenerates its SSH host
# keys on every image rebuild/reflash (confirmed 2026-08-29 — the "WARNING:
# REMOTE HOST IDENTIFICATION HAS CHANGED" that shows up after reflashing is
# expected in that specific case, not a real alarm).
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

banner() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$GOLDEN_DIR"

banner "Remote Attestation — ${PI_HOST}"

# --- EK provenance: verify the device's real EK cert chains to Infineon's
# manufacturer CA, and that the cert actually belongs to the live TPM we're
# talking to (not a cert file from some other chip). Run every time, not
# cached — cheap (no network fetch, the chain PEMs ship in this repo) and
# avoids a stale trust-once-forever cache. ---
info "Fetching EK certificate from ${PI_HOST}..."
ssh "${SSH_OPTS[@]}" "root@${PI_HOST}" \
    "tpm2_getekcertificate --tcti=device:/dev/tpmrm0 -o /tmp/ek_cert_rsa.der -o /tmp/ek_cert_ecc.der >/dev/null 2>&1" \
    || fail "Could not fetch EK certificate from device"
scp -q "${SSH_OPTS[@]}" "root@${PI_HOST}:/tmp/ek_cert_rsa.der" "$WORK_DIR/" \
    || fail "Could not retrieve EK certificate"

# Split the bundled chain PEM (intermediate cert, then root — see how these
# files are built in phase2/README.md) into its two certs so openssl only
# trusts the actual root, chaining through the intermediate, rather than
# trusting both certs in the bundle equally.
awk -v n=0 '/-----BEGIN CERTIFICATE-----/{n++} {print > ("'"$WORK_DIR"'/rsa_chain_" n ".pem")}' "$RSA_CHAIN_PEM"
openssl x509 -inform der -in "$WORK_DIR/ek_cert_rsa.der" -out "$WORK_DIR/ek_cert_rsa.pem" \
    || fail "Device's EK certificate is not valid DER — this alone is grounds for not trusting it"
openssl verify -CAfile "$WORK_DIR/rsa_chain_2.pem" -untrusted "$WORK_DIR/rsa_chain_1.pem" \
    "$WORK_DIR/ek_cert_rsa.pem" > /dev/null \
    || fail "EK certificate does NOT chain to Infineon's manufacturer CA — refusing to trust this device (possible clone/software TPM impersonating the real chip)"
pass "EK certificate chains to Infineon's manufacturer CA (genuine SLB9670, not a clone)"

# Cross-check: the cert's embedded public key must match the LIVE EK at
# 0x81010001 on the device right now — otherwise a verified-but-unrelated
# cert could be presented alongside a different, untrusted EK.
ssh "${SSH_OPTS[@]}" "root@${PI_HOST}" \
    "tpm2_readpublic --tcti=device:/dev/tpmrm0 -c ${EK_HANDLE} -f pem -o /tmp/ek_live.pem >/dev/null 2>&1" \
    || fail "Could not read live EK public key from device"
scp -q "${SSH_OPTS[@]}" "root@${PI_HOST}:/tmp/ek_live.pem" "$WORK_DIR/" \
    || fail "Could not retrieve live EK public key"
CERT_MODULUS=$(openssl x509 -in "$WORK_DIR/ek_cert_rsa.pem" -noout -pubkey | openssl rsa -pubin -noout -modulus 2>/dev/null)
LIVE_MODULUS=$(openssl rsa -pubin -in "$WORK_DIR/ek_live.pem" -noout -modulus 2>/dev/null)
[[ -n "$CERT_MODULUS" && "$CERT_MODULUS" == "$LIVE_MODULUS" ]] \
    || fail "EK certificate's public key does NOT match the device's live EK — cert does not belong to this chip"
pass "EK certificate's public key matches this device's live EK — verified device identity is genuine"

# --- One-time: fetch the AK public key if we don't have it locally yet ---
# The AK never changes across boots (it's a persistent handle), so this is
# a genuine "enroll once, trust thereafter" step — see the scope note
# above about what a hardened version of this step would also check.
if [[ ! -f "$AK_PUB" ]]; then
    info "No local AK public key at ${AK_PUB} — fetching once from ${PI_HOST}"
    ssh "${SSH_OPTS[@]}" "root@${PI_HOST}" "tpm2_readpublic --tcti=device:/dev/tpmrm0 -c ${AK_HANDLE} -f pem -o /tmp/ak_public.pem" > /dev/null
    scp -q "${SSH_OPTS[@]}" "root@${PI_HOST}:/tmp/ak_public.pem" "$AK_PUB"
    pass "AK public key saved to ${AK_PUB} — reused on every future run"
else
    info "Using cached AK public key: ${AK_PUB}"
fi

# --- Generate a fresh nonce (anti-replay) ---
NONCE=$(openssl rand -hex 20)
info "Nonce: ${NONCE}"

# --- Challenge the device: generate the quote, PCR output in "values" ---
# format (-F values): just the selected PCR digests, concatenated in PCR
# order, no struct framing — see the header comment for why.
info "Requesting quote from ${PI_HOST} over PCR 1/8/10..."
ssh "${SSH_OPTS[@]}" "root@${PI_HOST}" "
    tpm2_quote --tcti=device:/dev/tpmrm0 -c ${AK_HANDLE} -l ${PCR_LIST} -q ${NONCE} \
        -m /tmp/quote.msg -s /tmp/quote.sig -o /tmp/quote.pcrs -F values -g sha256 >/dev/null
"
pass "Quote generated on device"

scp -q "${SSH_OPTS[@]}" "root@${PI_HOST}:/tmp/quote.msg" "root@${PI_HOST}:/tmp/quote.sig" "root@${PI_HOST}:/tmp/quote.pcrs" "$WORK_DIR/"
pass "Quote files retrieved"

# --- Verify: signature (chains to the AK) and nonce freshness ---
# -l here makes checkquote parse quote.pcrs with the same headerless
# "values" reader used to write it (parse_selection_data_from_selection_
# string in tpm2-tools' own source), instead of the default
# self-describing "serialized" format tpm2_quote writes without -F.
info "Verifying quote signature and nonce..."
VERIFY_OUT=$(tpm2_checkquote -u "$AK_PUB" -m "${WORK_DIR}/quote.msg" -s "${WORK_DIR}/quote.sig" \
    -f "${WORK_DIR}/quote.pcrs" -l "$PCR_LIST" -g sha256 -q "$NONCE" 2>&1) \
    || fail "Quote/signature verification failed:\n${VERIFY_OUT}"
pass "Quote signature verified — genuinely signed by this device's AK, over this exact nonce"

# --- Decode PCR 1/8/10 directly from the now-verified quote.pcrs file ---
# sha256 = 32-byte digests, concatenated in the exact order requested
# (1, 8, 10) — this is the same file checkquote just validated against the
# signed digest above, not a separate unverified read.
QUOTE_PCRS="${WORK_DIR}/quote.pcrs"
ACTUAL_SIZE=$(stat -c%s "$QUOTE_PCRS")
[[ "$ACTUAL_SIZE" -eq 96 ]] || fail "quote.pcrs is ${ACTUAL_SIZE} bytes, expected 96 (3 PCRs x 32 bytes sha256) — format mismatch?"

decode_pcr() {
    # $1 = 0-based chunk index (0=PCR1, 1=PCR8, 2=PCR10, matching PCR_LIST order)
    echo "0x$(xxd -p -s $(( $1 * 32 )) -l 32 "$QUOTE_PCRS" | tr -d '\n' | tr 'a-f' 'A-F')"
}
PCR1=$(decode_pcr 0)
PCR8=$(decode_pcr 1)
PCR10=$(decode_pcr 2)

banner "PCR Comparison"

if [[ "${PCR1^^}" == "${GOLDEN_PCR1^^}" ]]; then
    pass "PCR 1 (bootargs) matches golden baseline"
else
    fail "PCR 1 MISMATCH — expected ${GOLDEN_PCR1}, got ${PCR1}"
fi

if [[ "${PCR8^^}" == "${GOLDEN_PCR8^^}" ]]; then
    pass "PCR 8 (kernel image) matches golden baseline"
else
    fail "PCR 8 MISMATCH — expected ${GOLDEN_PCR8}, got ${PCR8}"
fi

if [[ -f "$GOLDEN_PCR10" ]]; then
    SAVED_PCR10=$(cat "$GOLDEN_PCR10")
    if [[ "${PCR10^^}" == "${SAVED_PCR10^^}" ]]; then
        pass "PCR 10 (IMA) matches this session's captured baseline"
    else
        warn "PCR 10 differs from the captured baseline — expected if programs ran since boot/last capture (IMA measures every exec'd program). Not a hard failure."
        echo "         captured: ${SAVED_PCR10}"
        echo "         current:  ${PCR10}"
    fi
else
    echo "$PCR10" > "$GOLDEN_PCR10"
    info "No PCR 10 baseline captured yet — saved this reading as the baseline for future comparisons (delete ${GOLDEN_PCR10} to re-capture, e.g. after a fresh reboot)"
fi

banner "Result"
pass "Remote attestation SUCCEEDED — device identity + PCR state cryptographically verified"
