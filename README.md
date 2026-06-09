# Secure Embedded Platform — Hardware Root of Trust PoC

A proof-of-concept secure embedded platform demonstrating hardware root of trust using a Raspberry Pi 4 Model B and an Infineon OPTIGA TPM SLB9673.

Built as part of an ICS/OT security portfolio. The goal is to demonstrate practical TPM 2.0 integration — key provisioning, local attestation, and PCR-based boot integrity — on real hardware, not a software emulator.

---

## Hardware

| Component | Details |
|-----------|---------|
| SBC | Raspberry Pi 4 Model B |
| TPM | Infineon OPTIGA TPM SLB9673 (Raspberry Pi HAT) |
| Interface | I2C via jumper wires |
| OS (Phase 1) | Raspberry Pi OS Lite 64-bit |
| OS (Phase 2) | Custom Yocto image |

---

## What This Demonstrates

| Capability | Description |
|-----------|-------------|
| Hardware identity | EK provisioned from TPM hardware — non-exportable |
| Key hierarchy | EK → SRK → AK, following TCG standard handle conventions |
| Local attestation | AK signs a nonce, verified externally with OpenSSL |
| PCR attestation | TPM quotes PCR state, verifier checks integrity and freshness |
| Persistence | Keys survive reboot via TPM NV storage |
| FIPS 140-2 | Confirmed active on SLB9673 |

---

## Repository Structure

```
secure-embedded-platform/
├── README.md                   ← this file
├── phase1/
│   └── README.md               ← Raspberry Pi OS setup, wiring, provisioning, attestation
└── scripts/
    └── attest.sh               ← full attestation flow (local + PCR)
```

Phase 2 (Yocto) documentation will be added as that work progresses.

---

## Quick Start

### Prerequisites

- Raspberry Pi 4 Model B
- Infineon OPTIGA TPM SLB9673 HAT
- Raspberry Pi OS Lite 64-bit
- I2C wiring connected (see [phase1/README.md](phase1/README.md))

### Setup

```bash
# Enable I2C and load TPM overlay
sudo raspi-config  # Interface Options → I2C → Enable
echo "dtoverlay=tpm-slb9673" | sudo tee -a /boot/firmware/config.txt
sudo reboot

# Verify TPM is detected
dmesg | grep -i tpm
ls /dev/tpm*

# Install tools
sudo apt install -y tpm2-tools tpm2-abrmd

# Provision key hierarchy
sudo tpm2_clear -c p
sudo tpm2_createek -c 0x81010001 -G rsa -u /tmp/ek.pub
sudo tpm2_createprimary -C o -G rsa -g sha256 -c /tmp/srk.ctx
sudo tpm2_evictcontrol -C o -c /tmp/srk.ctx 0x81000001
sudo tpm2_createak -C 0x81010001 -c /tmp/ak.ctx -G rsa -g sha256 -s rsassa -u /tmp/ak.pub -f pem
sudo tpm2_evictcontrol -C o -c /tmp/ak.ctx 0x81000002
```

### Run Attestation

```bash
chmod +x scripts/attest.sh

sudo ./scripts/attest.sh          # full flow
sudo ./scripts/attest.sh local    # nonce signing only
sudo ./scripts/attest.sh pcr      # PCR quote only
sudo ./scripts/attest.sh clean    # remove temp files
```

---

## Persistent Handle Map

| Handle | Key | Purpose |
|--------|-----|---------|
| `0x81000001` | SRK | Storage root — parent for all stored keys |
| `0x81000002` | AK | Attestation signing key |
| `0x81010001` | EK | Hardware identity root |

---

## Roadmap

### Phase 1 — Raspberry Pi OS ✅
- [x] TPM hardware wiring and detection
- [x] I2C interface via `tpm-slb9673` overlay
- [x] tpm2-tools installation and verification
- [x] Key hierarchy: EK, SRK, AK provisioned and persisted
- [x] Local attestation (nonce signing + OpenSSL verification)
- [x] PCR attestation (PCR 23 extend + quote + checkquote)

### Phase 2 — Yocto 🔲
- [ ] Custom Yocto image with `meta-raspberrypi` + `meta-security`
- [ ] Custom DTS for SLB9673 over SPI (remove I2C dependency)
- [ ] `tpm2-tss`, `tpm2-tools`, `tpm2-abrmd` baked into image
- [ ] Measured boot with PCR extension at boot time
- [ ] Reference: [embetrix/meta-raspberrypi-secure](https://github.com/embetrix/meta-raspberrypi-secure)

---

## Why TPM for ICS/OT

Industrial control systems increasingly require hardware-backed identity and integrity verification. A TPM provides:

- **Device identity** — the EK certificate chain proves the device is genuine hardware, not a clone or VM
- **Boot integrity** — PCR measurements detect unauthorized firmware or OS changes
- **Key protection** — private keys never leave the TPM, eliminating a major attack surface
- **Attestation** — a remote verifier can cryptographically confirm the device's state before trusting it

This PoC establishes the foundation for those capabilities on a low-cost embedded platform.

---

## References

- [TCG TPM 2.0 Specification](https://trustedcomputinggroup.org/resource/tpm-library-specification/)
- [tpm2-tools Documentation](https://tpm2-tools.readthedocs.io/)
- [Infineon OPTIGA TPM SLB9673](https://www.infineon.com)
- [Raspberry Pi Device Tree Overlays](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README)
- [meta-raspberrypi-secure](https://github.com/embetrix/meta-raspberrypi-secure)
