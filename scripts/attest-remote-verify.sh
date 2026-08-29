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
# Deliberately NOT implemented (documented scope limitation, not an
# oversight): validating the AK itself chains back to the EK/manufacturer
# CA (already extracted in Phase 1 — ek_cert_rsa.der/ek_cert_ecc.der — but
# not wired into this script's trust-on-first-use AK fetch below). A real
# deployment would enroll a device's AK once via a secure, out-of-band
# provisioning step that validates that chain, not blindly trust whatever
# AK a host answers with on first contact.
#
# Usage:
#   ./attest-remote-verify.sh <pi-host-or-ip> [ak-pub-file]
#
# Requires: tpm2-tools, openssl, ssh/scp, xxd — on THIS machine (the
# verifier), not the Pi. Verification must never run on the device being
# verified — a compromised device could just lie about its own
# verification result.

set -euo pipefail

PI_HOST="${1:?Usage: $0 <pi-host-or-ip> [ak-pub-file]}"
AK_PUB="${2:-./ak_public.pem}"
AK_HANDLE="0x81000002"
PCR_LIST="sha256:1,8,10"
WORK_DIR="$(mktemp -d)"
GOLDEN_DIR="${HOME}/.tpm-poc-rpi-attest"
GOLDEN_PCR10="${GOLDEN_DIR}/pcr10-golden.txt"

# Verified golden baseline for PCR 1/8 — see phase2/README.md, confirmed
# identical across two genuine power cycles, 2026-08-29. These change only
# if the boot chain itself changes (new kernel, new bootargs, new U-Boot
# build) — update here if that ever happens deliberately.
GOLDEN_PCR1="0x679A7CA3A0C4A650097ADD413232EEAD591FD499149FB3A4ECA996C8F50123D8"
GOLDEN_PCR8="0xA3156994D6D346537DA65D7C8DACD8FFBAD11505B10F7B13396B8660BFF05AAF"

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

# --- One-time: fetch the AK public key if we don't have it locally yet ---
# The AK never changes across boots (it's a persistent handle), so this is
# a genuine "enroll once, trust thereafter" step — see the scope note
# above about what a hardened version of this step would also check.
if [[ ! -f "$AK_PUB" ]]; then
    info "No local AK public key at ${AK_PUB} — fetching once from ${PI_HOST}"
    ssh "root@${PI_HOST}" "tpm2_readpublic -c ${AK_HANDLE} -f pem -o /tmp/ak_public.pem" > /dev/null
    scp -q "root@${PI_HOST}:/tmp/ak_public.pem" "$AK_PUB"
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
ssh "root@${PI_HOST}" "
    tpm2_quote -c ${AK_HANDLE} -l ${PCR_LIST} -q ${NONCE} \
        -m /tmp/quote.msg -s /tmp/quote.sig -o /tmp/quote.pcrs -F values -g sha256 >/dev/null
"
pass "Quote generated on device"

scp -q "root@${PI_HOST}:/tmp/quote.msg" "root@${PI_HOST}:/tmp/quote.sig" "root@${PI_HOST}:/tmp/quote.pcrs" "$WORK_DIR/"
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
