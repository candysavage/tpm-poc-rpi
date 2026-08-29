# Secure Embedded Platform — Hardware Root of Trust PoC

A proof-of-concept secure embedded platform demonstrating hardware root of trust on a Raspberry Pi 4, built up in two phases: manual TPM 2.0 integration on Raspberry Pi OS, then a full measured-boot chain — bootloader through kernel through remote attestation over the network — on a custom Yocto image.

Built as part of an ICS/OT security portfolio. The goal is to demonstrate practical TPM 2.0 integration on real hardware, not a software emulator: key provisioning, local attestation, PCR-based boot integrity, and eventually a genuine pre-boot-to-verified-remote-report chain.

**Status:** Phase 1 complete. Phase 2's core engineering is complete and verified on real hardware — measured boot (U-Boot → PCR 1/8), IMA (kernel → PCR 10), remote attestation over the network (AK-signed quotes), and EK-to-manufacturer-CA provenance validation are all working. See [What This Demonstrates](#what-this-demonstrates) below for the full picture, and [phase2/README.md](phase2/README.md) for the complete technical writeup — the debugging journey, every verified command output, and the full [Threat Model & Limitations](phase2/README.md#threat-model--limitations) section.

---

## Hardware

| Component | Details |
|-----------|---------|
| SBC | Raspberry Pi 4 Model B |
| TPM (Phase 1) | Infineon OPTIGA TPM SLB9673 (Raspberry Pi HAT), I2C |
| TPM (Phase 2) | Infineon OPTIGA TPM SLB9670 (Xenon SPI board, hand-wired), bit-banged SPI via `spi-gpio` — I2C access from U-Boot is broken upstream on RPi4, so a second, SPI-only chip was used for the pre-boot half of the chain |
| OS (Phase 1) | Raspberry Pi OS Lite 64-bit |
| OS (Phase 2) | Custom Yocto image (`scarthgap`), U-Boot 2024.01, busybox init |

Two physically different TPM chips are involved on purpose, not by accident — see [phase2/README.md](phase2/README.md#why-spi-not-i2c) for why I2C had to be abandoned for the measured-boot work, and [phase2/README.md](phase2/README.md#ek-provenance-validation) for a real consequence of that: the two chips are certified by *different* Infineon CA generations, discovered by actually extracting and checking both.

---

## What This Demonstrates

| Capability | Phase | Description |
|-----------|-------|-------------|
| Hardware identity | 1 | EK provisioned from TPM hardware — non-exportable |
| Key hierarchy | 1 | EK → SRK → AK, following TCG standard handle conventions |
| Local attestation | 1 | AK signs a nonce, verified externally with OpenSSL |
| PCR attestation | 1 | TPM quotes PCR state, verifier checks integrity and freshness |
| Persistence | 1 | Keys survive reboot via TPM NV storage |
| **Measured boot** | 2 | U-Boot measures bootargs (PCR 1) and the kernel image (PCR 8) into the TPM *before Linux starts* — a real pre-boot SRTM-style chain, not a post-boot demo. Deterministic across genuine power cycles. |
| **IMA (runtime measurement)** | 2 | The kernel's IMA subsystem continues the chain past boot, measuring every executed program into PCR 10 for as long as the system runs |
| **Remote attestation** | 2 | A separate verifier machine challenges the device over SSH for an AK-signed TPM quote, and cryptographically checks the signature, nonce freshness, and PCR 1/8/10 against a known-good baseline — without trusting the device's own OS to self-report honestly |
| **EK provenance validation** | 2 | Every attestation run verifies the device's real EK certificate chains to Infineon's manufacturer CA and matches the live EK on the chip — proving it's a genuine Infineon TPM, not a clone or software TPM |
| **Threat model, stated explicitly** | 2 | What this chain does and doesn't prove is written down, not implied — no hardware CRTM on RPi4, PCR-reset semantics, measured-vs-enforced boot, attestation freshness vs. continuous trust, and what's still trust-on-first-use. See [Threat Model & Limitations](phase2/README.md#threat-model--limitations). |
| FIPS 140-2 | 1 | Confirmed active on the SLB9673 |

---

## Repository Structure

This repo is the **documentation and verification side** — narrative writeups, certs, and the attestation scripts. The actual Yocto build tree (all layers, recipes, and build config) lives in a separate repo, [`tpm-poc-rpi-yocto`](https://github.com/candysavage/tpm-poc-rpi-yocto), tracked with the upstream Yocto layers as git submodules so it's independently reproducible.

```
tpm-poc-rpi/
├── README.md                          ← this file
├── phase1/
│   └── README.md                      ← Raspberry Pi OS setup, wiring, provisioning, local attestation
├── phase2/
│   ├── README.md                      ← Yocto image, measured boot, IMA, remote attestation,
│   │                                     EK provenance validation, threat model — the full writeup
│   ├── local.conf.snippet             ← TPM/measured-boot/IMA-relevant local.conf additions
│   ├── bblayers.conf.snippet          ← required layer list
│   └── meta-custom/                   ← this project's own Yocto layer: TPM device tree overlays
│                                         (I2C + SPI-GPIO), U-Boot measured-boot config, kernel
│                                         TPM/IMA config, boot script, static-IP networking
├── certs/
│   ├── ek_cert_rsa.der,                ← Phase 1 chip (SLB9673, I2C) EK certs + its CA chain
│   │   ek_cert_ecc.der,
│   │   infineon_rsa_chain.pem,
│   │   infineon_ecc_chain.pem
│   ├── ek_cert_rsa_spi.der,             ← Phase 2 chip (SLB9670, SPI) EK certs + its CA chain —
│   │   ek_cert_ecc_spi.der,               a genuinely different Infineon CA generation, see above
│   │   infineon_rsa_chain_ca042.pem,
│   │   infineon_ecc_chain_ca042.pem
│   └── ak_public.pem                   ← Phase 2 device's cached AK public key
└── scripts/
    ├── attest.sh                       ← Phase 1: local attestation flow (nonce sign + PCR quote)
    └── attest-remote-verify.sh         ← Phase 2: full remote attestation over the network —
                                            EK chain validation, AK-signed quote, PCR comparison
```

---

## Quick Start

### Phase 1 — local attestation on Raspberry Pi OS

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

# Run attestation
chmod +x scripts/attest.sh
sudo ./scripts/attest.sh          # full flow
sudo ./scripts/attest.sh local    # nonce signing only
sudo ./scripts/attest.sh pcr      # PCR quote only
```

Full walkthrough: [phase1/README.md](phase1/README.md).

### Phase 2 — measured boot + remote attestation on Yocto

Building the image itself requires the separate [`tpm-poc-rpi-yocto`](https://github.com/candysavage/tpm-poc-rpi-yocto) build tree (`git clone --recurse-submodules`, then `bitbake core-image-minimal` — see that repo, or [phase2/README.md](phase2/README.md#build) for the exact steps and a real build-system gotcha to know about first).

Once the device is flashed and booted, remote attestation runs from a separate verifier machine on the same network:

```bash
./scripts/attest-remote-verify.sh <pi-ip>
```

This validates the device's EK certificate chain, requests an AK-signed TPM quote over SSH, and checks the signature, nonce freshness, and PCR 1/8/10 against the known-good baseline — see [phase2/README.md](phase2/README.md#remote-attestation) for a real annotated run and exactly what each check proves.

---

## Persistent Handle Map

| Handle | Key | Purpose |
|--------|-----|---------|
| `0x81000001` | SRK | Storage root — parent for all stored keys |
| `0x81000002` | AK | Attestation signing key |
| `0x81010001` | EK | Hardware identity root |

Same handle map on both TPM chips, both phases.

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

### Phase 2 — Yocto ✅ (core engineering complete)
- [x] Custom Yocto image with `meta-raspberrypi` + `meta-security`, builds and boots on RPi4
- [x] Custom device tree overlays for both TPM chips — SLB9673 over I2C, SLB9670 over bit-banged SPI (`spi-gpio`, required since mainline U-Boot has no BCM2711 hardware SPI0 driver)
- [x] `tpm2-tss`, `tpm2-tools`, `tpm2-abrmd` baked into image, `abrmd` running at boot under busybox init
- [x] Key hierarchy (EK/SRK/AK) provisioned and persisted on the Yocto image, on both TPM chips
- [x] **Measured boot: U-Boot → FIT → Linux chain fully working and verified.** U-Boot measures bootargs (PCR 1) and the kernel image (PCR 8) into the TPM before Linux starts; a deterministic golden PCR baseline is confirmed across genuine power cycles. Ten distinct bugs found and fixed across the firmware/bootloader/kernel/build-system stack to get there — see [phase2/README.md](phase2/README.md#measured-boot).
- [x] **IMA (PCR 10) — kernel-side userspace measurement, working and verified.** Completes the pre-boot-to-userspace measured-boot chain: U-Boot (PCR 1/8) → kernel IMA (PCR 10). Configured by hand rather than via `meta-security/meta-integrity`'s own automation, which targets `linux-yocto`/systemd — neither used by this project.
- [x] **Remote attestation — working and verified against real hardware over a live network link.** A separate verifier machine challenges the Pi over SSH for an AK-signed TPM quote, confirms the signature and nonce freshness, and checks PCR 1/8/10 against the golden baseline. The Pi is reachable over a static IP baked into the image — no manual networking setup after a reflash or power cycle. See [phase2/README.md](phase2/README.md#remote-attestation).
- [x] **EK provenance validation — the device's EK certificate is verified to chain to Infineon's manufacturer CA**, and cross-checked against the live EK on the chip, before any AK/quote exchange happens. Proves the device is a genuine Infineon-manufactured TPM, not a clone or software TPM. Full `TPM2_ActivateCredential` binding of the AK to that verified EK was attempted and hit a reproducible tpm2-tools defect — documented as a real, cited tool limitation rather than a scope cut. See [phase2/README.md](phase2/README.md#ek-provenance-validation).
- [x] **Threat Model & Limitations documented explicitly** — no hardware CRTM on RPi4, PCR-reset semantics (`PLT_RST` floating), devicetree deliberately left unmeasured, measured-vs-enforced boot, attestation freshness vs. continuous trust, and what's still trust-on-first-use. See [phase2/README.md](phase2/README.md#threat-model--limitations).
- [ ] TPM event log readable from Linux — currently U-Boot-side scratch RAM only, not backed by a `/reserved-memory` region; scoped as a known, documented limitation rather than blocking
- [ ] The thesis document itself

See [phase2/README.md](phase2/README.md) for the full writeup, including a ten-bug debugging journey documented as real, citable findings rather than a fix log.

---

## Why TPM for ICS/OT

Industrial control systems increasingly require hardware-backed identity and integrity verification. A TPM provides:

- **Device identity** — a validated EK certificate chain proves the device is genuine hardware, not a clone or VM (implemented and verified in Phase 2 — see [EK Provenance Validation](phase2/README.md#ek-provenance-validation))
- **Boot integrity** — PCR measurements detect unauthorized firmware or OS changes (Phase 2's measured boot + IMA)
- **Key protection** — private keys never leave the TPM, eliminating a major attack surface
- **Attestation** — a remote verifier can cryptographically confirm the device's state before trusting it (Phase 2's remote attestation)

This PoC establishes those capabilities on a low-cost embedded platform, and is explicit — in [phase2/README.md](phase2/README.md#threat-model--limitations) — about exactly where the guarantees stop.

---

## References

- [TCG TPM 2.0 Specification](https://trustedcomputinggroup.org/resource/tpm-library-specification/)
- [tpm2-tools Documentation](https://tpm2-tools.readthedocs.io/)
- [Infineon OPTIGA TPM SLB9673](https://www.infineon.com)
- [Raspberry Pi Device Tree Overlays](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README)
- [meta-raspberrypi-secure](https://github.com/embetrix/meta-raspberrypi-secure)
- [wxleong/tpm2-uboot-rpi4](https://github.com/wxleong/tpm2-uboot-rpi4), [ejaaskel/meta-slb9670-rpi](https://github.com/ejaaskel/meta-slb9670-rpi) — measured-boot references studied and adapted for Phase 2, see [phase2/README.md](phase2/README.md#measured-boot) for how
- [`agherzan/meta-raspberrypi#1358`](https://github.com/agherzan/meta-raspberrypi/issues/1358) — the upstream issue confirming I2C TPM access from U-Boot is broken on RPi4, which is why Phase 2 uses a second, SPI-only chip
