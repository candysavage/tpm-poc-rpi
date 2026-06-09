# Secure Embedded Platform — Phase 1: Raspberry Pi OS Setup

> **Project Goal:** Build a PoC secure embedded platform demonstrating hardware root of trust using a Raspberry Pi 4 Model B and an Infineon OPTIGA TPM SLB9673.  
> **Audience:** ICS/OT security engineers, embedded security practitioners, portfolio reviewers.

---

## Hardware

| Component | Details |
|-----------|---------|
| SBC | Raspberry Pi 4 Model B |
| TPM | Infineon OPTIGA TPM SLB9673 (on Raspberry Pi HAT) |
| Interface | I2C (SDA/SCL) via jumper wires |
| OS | Raspberry Pi OS Lite 64-bit |

---

## Wiring — TPM HAT to Pi GPIO (via jumper wires)

> The HAT cannot sit flush due to a large cooler on the Pi. Jumper wires connect the HAT to the GPIO header directly.

| Signal | Pi Physical Pin | BCM |
|--------|----------------|-----|
| 3.3V | Pin 1 | — |
| GND | Pin 9 | — |
| SDA | Pin 3 | GPIO2 |
| SCL | Pin 5 | GPIO3 |

> **Notes:**
> - Pin 6 (GND) is occupied by the cooler fan. Pin 9 is an equivalent GND.
> - RST and PIRQ pins are not connected for this PoC.
> - The kernel's `tpm-slb9673` overlay uses I2C. The SPI path requires a custom DTS and is deferred to Phase 2 (Yocto).

---

## Step 1 — Base OS Setup

Flash Raspberry Pi OS Lite (64-bit) using Raspberry Pi Imager. Before writing, configure:
- Hostname: `tpm-poc`
- Enable SSH
- Set username/password
- WiFi if needed

After first boot:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

---

## Step 2 — Enable I2C

```bash
sudo raspi-config
# Interface Options → I2C → Enable
sudo reboot
```

---

## Step 3 — Load TPM Device Tree Overlay

```bash
sudo nano /boot/firmware/config.txt
```

Add at the bottom:

```
dtoverlay=tpm-slb9673
```

Reboot, then verify:

```bash
dmesg | grep -i tpm
```

**Expected output:**
```
tpm_tis_i2c 22-002e: 2.0 TPM (device-id 0x1C, rev-id 22)
```

```bash
ls /dev/tpm*
# /dev/tpm0  /dev/tpmrm0
```

> `/dev/tpm0` — raw TPM device  
> `/dev/tpmrm0` — TPM resource manager (use this for multi-process access)

---

## Step 4 — Install TPM Tools

```bash
sudo apt install -y tpm2-tools tpm2-abrmd
```

Verify communication:

```bash
sudo tpm2_getcap properties-fixed
```

**Key fields confirmed:**

| Property | Value |
|----------|-------|
| TPM Family | 2.0 |
| Revision | 1.59 |
| Manufacturer | IFX (Infineon) |
| Vendor String | SLB9673 |
| Firmware | 1A000D / 456A00 |
| FIPS 140-2 | Enabled |
| PCR Count | 24 |

---

## Step 5 — Key Hierarchy Provisioning

### Verify clean state

```bash
sudo tpm2_getcap properties-variable | grep -E "ownerAuth|endorsement|lockout|inLockout"
```

All values should be `0`. Then clear:

```bash
sudo tpm2_clear -c p
```

### Endorsement Key (EK)

The EK is the TPM's hardware identity. It is provisioned directly to a persistent handle:

```bash
sudo tpm2_createek -c 0x81010001 -G rsa -u /tmp/ek.pub
```

> Using `-c <handle>` persists the EK directly without a separate `tpm2_evictcontrol` step.

### Storage Root Key (SRK)

The SRK is the root of the key storage hierarchy:

```bash
sudo tpm2_createprimary -C o -G rsa -g sha256 -c /tmp/srk.ctx
sudo tpm2_evictcontrol -C o -c /tmp/srk.ctx 0x81000001
```

### Verify persistent handles

```bash
sudo tpm2_getcap handles-persistent
```

**Expected output:**
```
- 0x81000001   # SRK
- 0x81010001   # EK
```

### Verify handles survive reboot

```bash
sudo reboot
sudo tpm2_getcap handles-persistent
# Both handles must still be present
```

---

## Step 6 — Attestation Key (AK)

The AK is a signing key bound to this TPM via the EK. It cannot be exported or used outside this TPM.

```bash
sudo tpm2_createak \
  -C 0x81010001 \
  -c /tmp/ak.ctx \
  -G rsa \
  -g sha256 \
  -s rsassa \
  -u /tmp/ak.pub \
  -f pem

sudo tpm2_evictcontrol -C o -c /tmp/ak.ctx 0x81000002
```

Verify:

```bash
sudo tpm2_getcap handles-persistent
```

**Expected output:**
```
- 0x81000001   # SRK
- 0x81000002   # AK
- 0x81010001   # EK
```

Extract the AK public key for use in verification:

```bash
sudo tpm2_readpublic -c 0x81000002 -f pem -o /tmp/ak_public.pem
sudo chmod 644 /tmp/ak_public.pem
```

---

## Step 7 — Local Attestation (Nonce Signing)

This proves the TPM can perform hardware-backed signing. A nonce is signed by the AK and verified externally using OpenSSL — no TPM required for verification.

```bash
# Generate nonce
echo "tpm-poc-$(date +%s)" > /tmp/nonce.txt
cat /tmp/nonce.txt

# Sign with AK
sudo tpm2_sign \
  -c 0x81000002 \
  -g sha256 \
  -s rsassa \
  -f plain \
  -o /tmp/nonce.sig \
  /tmp/nonce.txt

sudo chmod 644 /tmp/nonce.sig

# Verify with OpenSSL
openssl dgst -sha256 \
  -verify /tmp/ak_public.pem \
  -signature /tmp/nonce.sig \
  /tmp/nonce.txt
```

**Expected output:**
```
Verified OK
```

---

## Step 8 — PCR-Based Attestation (Boot Integrity Quote)

PCR (Platform Configuration Register) attestation proves the state of the platform at a point in time. The TPM signs a quote of PCR values using the AK, bound to a fresh nonce to prevent replay.

### PCR state

PCRs 0–16 are zero — no measured boot (no UEFI/secure boot extending them).  
PCRs 17–22 are `0xFF` — locality-restricted, not software-accessible.  
PCR 23 is the software-extensible PCR used for this PoC.

### Extend PCR 23

Simulates a boot integrity measurement being recorded:

```bash
echo "boot-integrity-check" | sudo tpm2_pcrextend \
  23:sha256=$(echo "boot-integrity-check" | openssl dgst -sha256 -binary | xxd -p -c 32)

sudo tpm2_pcrread sha256:23
```

**Expected output:**
```
sha256:
  23: 0xEF3D337F18F94BFEEB207002BF388DF403144533809A3C76DDE094BEC4BA96E3
```

### Generate quote

```bash
# Fresh nonce — prevents replay attacks
openssl rand -hex 20 > /tmp/quote_nonce.hex

# Quote PCR 23 signed by AK
sudo tpm2_quote \
  -c 0x81000002 \
  -l sha256:23 \
  -q $(cat /tmp/quote_nonce.hex) \
  -m /tmp/quote.msg \
  -s /tmp/quote.sig \
  -o /tmp/pcrs.out \
  -g sha256

sudo chmod 644 /tmp/quote.msg /tmp/quote.sig /tmp/pcrs.out
```

### Verify quote

```bash
tpm2_checkquote \
  -u /tmp/ak_public.pem \
  -m /tmp/quote.msg \
  -s /tmp/quote.sig \
  -f /tmp/pcrs.out \
  -g sha256 \
  -q $(cat /tmp/quote_nonce.hex)
```

**Expected output:**
```
pcrs:
  sha256:
    23: 0xEF3D337F18F94BFEEB207002BF388DF403144533809A3C76DDE094BEC4BA96E3
sig: <RSA signature bytes>
```

### What this proves

| Property | Proof |
|----------|-------|
| PCR 23 value is `0xEF3D33...` | Confirmed by quote |
| Quote was signed by AK bound to this TPM | Signature verified against AK public key |
| Quote is fresh, not replayed | Nonce verified |

---

## Persistent Handle Map

| Handle | Key | Purpose |
|--------|-----|---------|
| `0x81000001` | SRK | Storage root — parent for all stored keys |
| `0x81000002` | AK | Attestation signing key |
| `0x81010001` | EK | Hardware identity, EK certificate chain root |

---

## Phase 1 Checkpoint Summary

| # | Checkpoint | Status |
|---|-----------|--------|
| 1 | I2C enabled, TPM overlay loaded | ✅ |
| 2 | TPM detected: SLB9673, TPM 2.0, FIPS 140-2 | ✅ |
| 3 | tpm2-tools communicating with TPM | ✅ |
| 4 | EK provisioned and persisted at `0x81010001` | ✅ |
| 5 | SRK provisioned and persisted at `0x81000001` | ✅ |
| 6 | AK provisioned and persisted at `0x81000002` | ✅ |
| 7 | All keys survive reboot | ✅ |
| 8 | Local attestation — nonce signed and verified | ✅ |
| 9 | PCR attestation — quote generated and verified | ✅ |

---

## Next Steps — Phase 2 (Yocto)

- [ ] Port to custom Yocto image using `meta-raspberrypi` + `meta-security`
- [ ] Write custom DTS for SLB9673 over SPI (remove I2C dependency)
- [ ] Integrate `tpm2-tss`, `tpm2-tools`, `tpm2-abrmd` into image
- [ ] Implement measured boot with PCR extension at boot time
- [ ] Reference: [embetrix/meta-raspberrypi-secure](https://github.com/embetrix/meta-raspberrypi-secure) — fork and study, don't blindly use

---

## References

- [TCG TPM 2.0 Specification](https://trustedcomputinggroup.org/resource/tpm-library-specification/)
- [tpm2-tools documentation](https://tpm2-tools.readthedocs.io/)
- [Infineon OPTIGA TPM SLB9673 Product Page](https://www.infineon.com)
- [Raspberry Pi Device Tree Overlays README](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README)
