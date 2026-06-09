#!/bin/bash
# attest.sh — TPM 2.0 Attestation Flow
# Secure Embedded Platform PoC
# Hardware: Raspberry Pi 4B + Infineon OPTIGA TPM SLB9673
#
# Performs:
#   1. Local attestation — sign a nonce with the AK, verify with OpenSSL
#   2. PCR attestation  — extend PCR 23, generate quote, verify quote
#
# Usage:
#   sudo ./attest.sh              # run full attestation
#   sudo ./attest.sh local        # local attestation only
#   sudo ./attest.sh pcr          # PCR attestation only
#   sudo ./attest.sh clean        # remove all temp files

set -euo pipefail

# --- Config ---
AK_HANDLE="0x81000002"
PCR_INDEX="23"
PCR_MEASUREMENT="boot-integrity-check"
WORK_DIR="/tmp/attest"
AK_PUB="${WORK_DIR}/ak_public.pem"
NONCE_FILE="${WORK_DIR}/nonce.txt"
NONCE_SIG="${WORK_DIR}/nonce.sig"
QUOTE_NONCE="${WORK_DIR}/quote_nonce.hex"
QUOTE_MSG="${WORK_DIR}/quote.msg"
QUOTE_SIG="${WORK_DIR}/quote.sig"
PCRS_OUT="${WORK_DIR}/pcrs.out"

# --- Colors ---
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

# --- Preflight checks ---
preflight() {
    banner "Preflight Checks"

    # Must run as root
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root (sudo)"
    fi

    # Check TPM device
    if [[ ! -e /dev/tpm0 ]]; then
        fail "/dev/tpm0 not found — is the TPM overlay loaded?"
    fi
    pass "/dev/tpm0 present"

    # Check tpm2-tools
    if ! command -v tpm2_getcap &>/dev/null; then
        fail "tpm2-tools not installed — run: apt install tpm2-tools"
    fi
    pass "tpm2-tools available"

    # Check openssl
    if ! command -v openssl &>/dev/null; then
        fail "openssl not installed"
    fi
    pass "openssl available"

    # Check AK handle exists
    HANDLES=$(tpm2_getcap handles-persistent 2>/dev/null)
    if ! echo "$HANDLES" | grep -q "$AK_HANDLE"; then
        fail "AK not found at ${AK_HANDLE} — run key provisioning first"
    fi
    pass "AK found at ${AK_HANDLE}"

    # Create work dir
    mkdir -p "$WORK_DIR"
    info "Working directory: ${WORK_DIR}"
}

# --- Extract AK public key ---
extract_ak_pub() {
    info "Extracting AK public key..."
    tpm2_readpublic -c "$AK_HANDLE" -f pem -o "$AK_PUB" > /dev/null 2>&1
    chmod 644 "$AK_PUB"
    pass "AK public key extracted to ${AK_PUB}"
}

# --- Local attestation ---
local_attestation() {
    banner "Local Attestation — Nonce Signing"

    extract_ak_pub

    # Generate nonce
    NONCE="tpm-poc-$(date +%s)"
    echo "$NONCE" > "$NONCE_FILE"
    info "Nonce: ${NONCE}"

    # Sign nonce with AK
    info "Signing nonce with AK (handle ${AK_HANDLE})..."
    tpm2_sign \
        -c "$AK_HANDLE" \
        -g sha256 \
        -s rsassa \
        -f plain \
        -o "$NONCE_SIG" \
        "$NONCE_FILE"
    chmod 644 "$NONCE_SIG"
    pass "Nonce signed"

    # Verify with OpenSSL
    info "Verifying signature with OpenSSL..."
    RESULT=$(openssl dgst -sha256 \
        -verify "$AK_PUB" \
        -signature "$NONCE_SIG" \
        "$NONCE_FILE" 2>&1)

    if echo "$RESULT" | grep -q "Verified OK"; then
        pass "Signature verified — local attestation SUCCESS"
    else
        fail "Signature verification failed: ${RESULT}"
    fi
}

# --- PCR attestation ---
pcr_attestation() {
    banner "PCR Attestation — Boot Integrity Quote"

    extract_ak_pub

    # Show current PCR state
    info "Current PCR ${PCR_INDEX} state:"
    tpm2_pcrread "sha256:${PCR_INDEX}"

    # Extend PCR 23
    info "Extending PCR ${PCR_INDEX} with measurement: '${PCR_MEASUREMENT}'"
    MEASUREMENT_HASH=$(echo "$PCR_MEASUREMENT" | openssl dgst -sha256 -binary | xxd -p -c 32)
    echo "$PCR_MEASUREMENT" | tpm2_pcrextend "${PCR_INDEX}:sha256=${MEASUREMENT_HASH}"

    # Read extended PCR value
    info "PCR ${PCR_INDEX} after extension:"
    PCR_VALUE=$(tpm2_pcrread "sha256:${PCR_INDEX}" 2>/dev/null | grep "${PCR_INDEX}:" | awk '{print $2}')
    echo "  sha256:"
    echo "    ${PCR_INDEX}: ${PCR_VALUE}"
    pass "PCR ${PCR_INDEX} extended"

    # Generate fresh nonce
    openssl rand -hex 20 > "$QUOTE_NONCE"
    NONCE_HEX=$(cat "$QUOTE_NONCE")
    info "Quote nonce: ${NONCE_HEX}"

    # Generate quote
    info "Generating TPM quote for PCR ${PCR_INDEX}..."
    tpm2_quote \
        -c "$AK_HANDLE" \
        -l "sha256:${PCR_INDEX}" \
        -q "$NONCE_HEX" \
        -m "$QUOTE_MSG" \
        -s "$QUOTE_SIG" \
        -o "$PCRS_OUT" \
        -g sha256
    chmod 644 "$QUOTE_MSG" "$QUOTE_SIG" "$PCRS_OUT"
    pass "Quote generated"

    # Verify quote
    info "Verifying quote..."
    VERIFY_OUT=$(tpm2_checkquote \
        -u "$AK_PUB" \
        -m "$QUOTE_MSG" \
        -s "$QUOTE_SIG" \
        -f "$PCRS_OUT" \
        -g sha256 \
        -q "$NONCE_HEX" 2>&1)

    if echo "$VERIFY_OUT" | grep -q "$PCR_INDEX"; then
        pass "Quote verified — PCR attestation SUCCESS"
        echo ""
        echo "$VERIFY_OUT"
    else
        fail "Quote verification failed:\n${VERIFY_OUT}"
    fi
}

# --- Cleanup ---
cleanup() {
    banner "Cleanup"
    if [[ -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
        pass "Removed ${WORK_DIR}"
    else
        info "Nothing to clean"
    fi
}

# --- Summary ---
summary() {
    banner "Attestation Summary"
    echo -e "  TPM Device   : /dev/tpm0"
    echo -e "  AK Handle    : ${AK_HANDLE}"
    echo -e "  PCR Index    : ${PCR_INDEX}"
    echo -e "  Work Dir     : ${WORK_DIR}"
    echo ""
    pass "All attestation checks passed"
    echo ""
}

# --- Main ---
MODE="${1:-all}"

case "$MODE" in
    local)
        preflight
        local_attestation
        summary
        ;;
    pcr)
        preflight
        pcr_attestation
        summary
        ;;
    clean)
        cleanup
        ;;
    all)
        preflight
        local_attestation
        pcr_attestation
        summary
        ;;
    *)
        echo "Usage: sudo $0 [all|local|pcr|clean]"
        exit 1
        ;;
esac
