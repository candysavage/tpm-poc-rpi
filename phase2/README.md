# Secure Embedded Platform — Phase 2: Yocto Image

> **Goal:** Replace Raspberry Pi OS (Phase 1) with a custom Yocto image that reproduces the same TPM stack — detection, key hierarchy, attestation — as a minimal, purpose-built image, then extend it with measured boot.
> **Status:** TPM stack fully working on I2C. Measured boot is in progress — software/build-tree changes are staged and validated, physical work is blocked on a hardware adapter (see [Measured Boot](#measured-boot--in-progress) below).

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
| 7 | Measured boot — hardware/software plan finalized, SPI overlay + kernel config + U-Boot enablement staged in build tree | 🟡 |
| 8 | Measured boot — hardware wired, U-Boot PCR 0 extend, IMA PCR 10, combined attestation | 🔲 |

---

## Measured Boot — In Progress

The goal: U-Boot measures the kernel image into a PCR before Linux starts, and the kernel's IMA subsystem continues measuring userspace into a second PCR after boot — a real pre-boot-to-userspace measurement chain, not just the manual PCR-extend demo from Phase 1.

### Why SPI, not I2C

Two independent findings ruled out reusing the existing I2C-connected SLB9673 HAT for this:

1. **I2C access from U-Boot on Raspberry Pi is broken upstream.** [`agherzan/meta-raspberrypi#1358`](https://github.com/agherzan/meta-raspberrypi/issues/1358) documents someone hitting this exact wall — I2C TPM access from U-Boot on an RPi CM4, same `scarthgap` release we're on. The I2C bus never probes in U-Boot (`dm tree` shows the driver never binds, error -19) despite correct config — a platform-level limitation, not specific to our TPM chip. Still open/unresolved upstream.
2. Unlike the I2C case, **the SPI overlay for the Infineon SLB9670 already ships in the RPi kernel source** (`arch/arm/boot/dts/overlays/tpm-slb9670-overlay.dts`) — no hand-written DTS needed this time, just reference the stock overlay name.

So: SPI is required for the pre-boot (U-Boot) half of the chain. IMA (post-boot, kernel-side) would technically still work over I2C, but a chain that only covers the OS side isn't the real measured-boot story this is meant to demonstrate.

### Hardware

Measured boot uses a **second TPM board**, not the Phase 1/2 HAT: an Infineon **Xenon SPI TPM** (`TPM7020XENONBOARDTOBO1`), chip **SLB9670** (SPI-only). This is the same chip family used by the [`wxleong/tpm2-uboot-rpi4`](https://github.com/wxleong/tpm2-uboot-rpi4) reference build. The original Phase 1/2 HAT is I2C-only/hardwired with no SPI option, hence the second board.

**Connector gotcha:** the Xenon board's SPI header is a 1.27mm-pitch (50 mil) female receptacle — half the pitch of the RPi's 2.54mm GPIO header, and physically the wrong gender/pitch for standard jumper wires. This board is actually designed to plug into a *PC motherboard's* onboard TPM header via a ribbon cable, not to be dev-board-wired — Infineon separately sells a purpose-built RPi HAT version of this TPM (the "Iridium" board, with a real 2.54mm 26-pin header and an on-board auto-reset circuit), but we're reusing hardware already on hand instead of buying it. Fix: a generic **1.27mm-to-2.54mm pitch adapter board** (the same category used for ARM SWD/JTAG debug probes, which use the same 1.27mm pitch).

Wiring plan (RPi4 SPI0, via the adapter):

| Xenon pin | Signal | RPi4 physical pin | GPIO |
|---|---|---|---|
| 6 | VDD | 1 | 3.3V |
| 5 | GND | 6 or 9 | — |
| 7 | SCLK | 23 | GPIO11 |
| 10 | MISO | 21 | GPIO9 |
| 12 | MOSI | 19 | GPIO10 |
| 13 | TPM_CS | 26 | GPIO7 (**CE1**, matches the stock overlay's `reg=<1>`) |
| 19 | PLT_RST | TBD | unlike the Iridium HAT, the Xenon board has no on-board auto-reset — needs a continuity check against VDD before deciding whether to leave it floating (if pulled up internally) or tie it to 3.3V |

### PCR allocation

| PCR | Source | Notes |
|---|---|---|
| 0 | U-Boot, kernel image hash | Doesn't collide with the below. Framed as a *logical* SRTM-style demonstration — RPi4 has no publicly rooted hardware CRTM, and U-Boot's TPM support alone doesn't defend against replay of earlier stages |
| 10 | Kernel IMA, userspace measurements | Standard TCG PC Client convention for OS-controlled PCRs |
| 23 | Existing Phase 1/2 manual demo | Unchanged, kept as-is |

### Software changes staged so far (build tree, not yet flashed/tested on hardware)

- `local.conf`: added the stock `tpm-slb9670` overlay (`RPI_KERNEL_DEVICETREE_OVERLAYS`, `dtparam=spi=on`), alongside the existing I2C config for side-by-side comparison
- New `meta-custom/recipes-kernel/linux/linux-raspberrypi_%.bbappend` + `.cfg` fragment forcing `CONFIG_TCG_TPM`/`CONFIG_TCG_TIS_SPI`/`CONFIG_SPI_BCM2835`/`CONFIG_TCG_TIS_I2C` builtin (not modules) — needed so the TPM is registered before IMA's pre-init measurements would need it
- `RPI_USE_U_BOOT = "1"` + `ENABLE_UART = "1"` (the latter is hard-required by `meta-raspberrypi` whenever U-Boot is enabled)
- Deleted a dead leftover duplicate DTS file found during cleanup
- Validated: full `bitbake -p` recipe parse succeeds with 0 errors

### Remaining work

- [ ] Wire the Xenon board once the pitch adapter arrives; resolve the PLT_RST question
- [ ] Fetch/build U-Boot 2024.01 and confirm its actual SPI/TPM Kconfig symbol names (not yet verified against this specific version)
- [ ] Add the U-Boot TPM SPI config + a boot-script `tpm pcr_extend` step, validate manually at the U-Boot prompt first
- [ ] Add `meta-security/meta-integrity` to `bblayers.conf`, configure an IMA policy, validate PCR 10
- [ ] Extend `scripts/attest.sh` with a combined PCR 0/10/23 quote
- [ ] TPM event log (`linux,sml-base`/`linux,sml-size`) — stretch goal, reported fragile/RAM-size-dependent in the closest reference build even when it matches our exact RAM size

Reference: [embetrix/meta-raspberrypi-secure](https://github.com/embetrix/meta-raspberrypi-secure), [wxleong/tpm2-uboot-rpi4](https://github.com/wxleong/tpm2-uboot-rpi4), [ejaaskel/meta-slb9670-rpi](https://github.com/ejaaskel/meta-slb9670-rpi) (branch `scarthgap-measured-boot-raspberrypi4-4gb`) — study and adapt, don't blindly copy.
