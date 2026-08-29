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
├── phase2/
│   ├── README.md               ← Yocto image, TPM overlay, what's verified working
│   ├── local.conf.snippet      ← TPM-relevant local.conf additions
│   ├── bblayers.conf.snippet   ← required layer list
│   └── meta-custom/            ← custom layer: TPM device tree overlay recipe
├── certs/
│   ├── ek_cert_rsa.der         ← Infineon-issued RSA EK certificate
│   └── ek_cert_ecc.der         ← Infineon-issued ECC EK certificate
└── scripts/
    └── attest.sh               ← full attestation flow (local + PCR)
```

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
- [x] EK certificates extracted (RSA + ECC, Infineon CA chain)
- [x] tpm2-abrmd verified running and enabled
- [x] Key wrapping demo (child key created, stored on disk, loaded on demand)

### Phase 2 — Yocto 🔲
- [x] Custom Yocto image with `meta-raspberrypi` + `meta-security`, builds and boots on RPi4
- [x] Custom device tree overlays for both TPM chips — SLB9673 over I2C, SLB9670 over bit-banged SPI (`spi-gpio`, required since mainline U-Boot has no BCM2711 hardware SPI0 driver)
- [x] `tpm2-tss`, `tpm2-tools`, `tpm2-abrmd` baked into image, `abrmd` running at boot under busybox init
- [x] Key hierarchy (EK/SRK/AK) provisioned and persisted on the Yocto image, on both TPM chips
- [x] **Measured boot: U-Boot → FIT → Linux chain fully working and verified.** U-Boot measures bootargs (PCR 1) and the kernel image (PCR 8) into the TPM before Linux starts; a deterministic golden PCR baseline is confirmed across genuine power cycles. Ten distinct bugs found and fixed across the firmware/bootloader/kernel/build-system stack to get there — see `phase2/README.md`'s [Measured Boot](phase2/README.md#measured-boot) section for the full technical writeup.
- [ ] IMA (PCR 10) — continues the chain from U-Boot into kernel-side userspace measurement, not yet started
- [ ] Remote attestation demo — networked extension of Phase 1's local quote/verify flow
- [ ] Reference: [embetrix/meta-raspberrypi-secure](https://github.com/embetrix/meta-raspberrypi-secure)

See [phase2/README.md](phase2/README.md) for the full writeup.

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