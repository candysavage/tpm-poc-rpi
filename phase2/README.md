# Secure Embedded Platform — Phase 2: Yocto Image

> **Goal:** Replace Raspberry Pi OS (Phase 1) with a custom Yocto image that reproduces the same TPM stack — detection, key hierarchy, attestation — as a minimal, purpose-built image, then extend it with measured boot.
> **Status:** TPM stack is fully working on the built image. Measured boot is the only item not yet started.

---

## Distro / Layers

| Setting | Value |
|---|---|
| Yocto release | scarthgap |
| `MACHINE` | `raspberrypi4-64` |
| `DISTRO` | `poky` |

Layers used (see [`bblayers.conf.snippet`](bblayers.conf.snippet)):

| Layer | Purpose |
|---|---|
| `poky/meta`, `meta-poky`, `meta-yocto-bsp` | Base Yocto/Poky |
| `meta-openembedded/meta-oe`, `meta-python` | Dependencies of `meta-security`/`meta-tpm` |
| `meta-raspberrypi` | RPi4 BSP |
| `meta-security` + `meta-security/meta-tpm` | TPM2 stack recipes (`tpm2-tss`, `tpm2-tools`, `tpm2-abrmd`) |
| [`meta-custom`](meta-custom/) | This project's own layer — TPM device tree overlay |

This repo's [`meta-custom`](meta-custom/) contains only the TPM-relevant recipe from the working build tree. WiFi provisioning (wpa_supplicant config, Broadcom firmware) was set up in this specific environment too but is unrelated to the TPM work and is omitted here.

---

## The TPM Device Tree Overlay

**There is no stock device-tree overlay for the Infineon SLB9673 in `meta-raspberrypi`.** A naive `dtoverlay=tpm-slb9673` (guessing at a built-in name, by analogy with Phase 1's `apt`-installed overlay) does not exist in this layer and will not bind the driver.

The fix, in [`meta-custom/recipes-bsp/tpm-overlay/`](meta-custom/recipes-bsp/tpm-overlay/):

1. [`files/tpm-slb9673-i2c.dts`](meta-custom/recipes-bsp/tpm-overlay/files/tpm-slb9673-i2c.dts) — a hand-written plugin overlay targeting `bcm2711`. It adds a `tpm@2e` node to `&i2c1`, compatible with `"infineon,slb9673", "tcg,tpm-tis-i2c"`, which lets the kernel's generic `tpm_tis_i2c` driver bind to the chip.
2. [`tpm-overlay_1.0.bb`](meta-custom/recipes-bsp/tpm-overlay/tpm-overlay_1.0.bb) — compiles the DTS into `tpm-slb9673-i2c.dtbo` via `dtc-native` and deploys it, following the standard Yocto `deploy` class pattern for a boot overlay not tied to a specific kernel recipe.
3. Wired into the image via `local.conf` (see [`local.conf.snippet`](local.conf.snippet)):
   - `RPI_EXTRA_CONFIG = 'dtoverlay=tpm-slb9673-i2c\ndtparam=i2c_arm=on'` — loads the *custom* overlay by name and explicitly enables the I2C bus (not on by default)
   - `RPI_EXTRA_IMAGE_BOOT_FILES:append` — copies the compiled `.dtbo` into `/boot/overlays/`
   - `EXTRA_IMAGEDEPENDS:append = " tpm-overlay"` — forces the overlay to build before the image is assembled

Everything else in `local.conf` is standard feature-flag/package plumbing: `DISTRO_FEATURES`/`MACHINE_FEATURES` add `security`/`tpm2`/`ima` to pull in TCG-aware recipe logic from `meta-security`, and `IMAGE_INSTALL` adds the userspace TPM stack.

---

## Build

```bash
# from the Yocto build tree, with the layers above in bblayers.conf
# and the settings from local.conf.snippet merged into build/conf/local.conf

source poky/oe-init-build-env build
bitbake core-image-minimal
```

Flash `tmp/deploy/images/raspberrypi4-64/core-image-minimal-raspberrypi4-64.rootfs.wic.bz2` to an SD card as usual.

---

## Verified Working (on-device, over SSH)

```bash
dmesg | grep -i tpm
```
```
tpm_tis_i2c 1-002e: 2.0 TPM (device-id 0x1C, rev-id 22)
```
> The `A TPM error (256) occurred attempting the self test` line that follows is expected — the kernel starts the TPM manually and continues.

```bash
tpm2_getcap handles-persistent
```
```
- 0x81000001   # SRK
- 0x81000002   # AK
- 0x81010001   # EK
```

Key hierarchy is provisioned the same way as [Phase 1](../phase1/README.md) — same handle map, same `tpm2_createek` / `tpm2_createprimary` / `tpm2_createak` flow — and persists across reboots.

```bash
ps | grep abrmd
```
```
417 tss  585m S  /usr/sbin/tpm2-abrmd --tcti=device --logger=syslog
```

`tpm2-abrmd` runs at boot as the `tss` user without any extra work — the image's init system is **busybox init**, not systemd, so there's no `systemctl`; the daemon starts via a busybox-init script instead.

```bash
tpm2_readpublic -c 0x81000002 -f pem
```
Reads the AK cleanly through `abrmd`, confirming the resource manager path works end-to-end (not just direct `/dev/tpm0` access).

> Note: this image's `head`/`tail`/etc. are BusyBox applets — they don't accept GNU long-form flags. Use `head -n 5`, not `head -5`.

---

## Checkpoint Summary

| # | Checkpoint | Status |
|---|-----------|--------|
| 1 | Custom Yocto image builds and boots on RPi4 | ✅ |
| 2 | TPM detected via custom I2C overlay (`tpm-slb9673-i2c`) | ✅ |
| 3 | `tpm2-tss`, `tpm2-tools`, `tpm2-abrmd` baked into image | ✅ |
| 4 | `tpm2-abrmd` running at boot under busybox init | ✅ |
| 5 | Key hierarchy (EK/SRK/AK) provisioned and persisted | ✅ |
| 6 | AK reachable through `abrmd` (`tpm2_readpublic`) | ✅ |
| 7 | Measured boot with PCR extension at boot time | 🔲 |

---

## Next Steps

- [ ] Measured boot / IMA. `ima` is already set in `DISTRO_FEATURES` but has no policy or recipe behind it yet — this is greenfield. Options:
  - IMA-based: kernel LSM measures files into a PCR automatically per a configured policy
  - Simpler PoC-grade: a boot-time init script extends a PCR with hashes of key boot files, mirroring Phase 1's manual PCR 23 demo but automated
- [ ] Consider whether to keep the SLB9673 on I2C (as now) or move to SPI — deprioritized so far, I2C works fine for this PoC
- Reference: [embetrix/meta-raspberrypi-secure](https://github.com/embetrix/meta-raspberrypi-secure) — study, don't blindly use
