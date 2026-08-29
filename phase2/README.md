# Secure Embedded Platform — Phase 2: Yocto Image

> **Goal:** Replace Raspberry Pi OS (Phase 1) with a custom Yocto image that reproduces the same TPM stack — detection, key hierarchy, attestation — as a minimal, purpose-built image, then extend it with measured boot.
> **Status:** Full pre-boot-to-userspace measured-boot chain working and verified on real hardware — U-Boot measures bootargs and the kernel image into the TPM before Linux starts (PCR 1/8, deterministic across genuine power cycles), the kernel's IMA subsystem continues measuring userspace into PCR 10 after boot, and a remote verifier can cryptographically challenge the device over the network and confirm its state matches the known-good baseline. See [Measured Boot](#measured-boot), [IMA](#ima--pcr-10), and [Remote Attestation](#remote-attestation) below.

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
| `meta-openembedded/meta-oe`, `meta-python`, `meta-networking` | Dependencies of `meta-security`/`meta-tpm` |
| `meta-raspberrypi` | RPi4 BSP |
| `meta-security` + `meta-security/meta-tpm` | TPM2 stack recipes (`tpm2-tss`, `tpm2-tools`, `tpm2-abrmd`) |
| `meta-security/meta-integrity` | Only for its `ima-evm-utils` recipe (`evmctl`) — its own kernel-config/policy-loading automation doesn't apply here, see [IMA](#ima--pcr-10) |
| [`meta-custom`](meta-custom/) | This project's own layer — TPM overlays, U-Boot/kernel measured-boot config, IMA config |

This repo's [`meta-custom`](meta-custom/) contains only the TPM/measured-boot-relevant recipes from the working build tree. WiFi provisioning (wpa_supplicant config, Broadcom firmware) was set up in this specific environment too but is unrelated to the TPM work and is omitted here. The full, live build tree (including the upstream layers themselves, as git submodules) is tracked separately at `~/yocto/tpm-poc-rpi/` — this repo is the documentation/narrative side, not the build source of truth.

---

## The TPM Device Tree Overlays

**There is no stock device-tree overlay for the Infineon SLB9673 (I2C) in `meta-raspberrypi`.** A naive `dtoverlay=tpm-slb9673` (guessing at a built-in name) does not exist and will not bind the driver. Fixed with a hand-written overlay, [`tpm-slb9673-i2c.dts`](meta-custom/recipes-bsp/tpm-overlay/files/tpm-slb9673-i2c.dts) — a plugin overlay targeting `bcm2711`, adding a `tpm@2e` node to `&i2c1`, compatible `"infineon,slb9673", "tcg,tpm-tis-i2c"`.

**The SLB9670 (SPI) is different — a stock overlay *does* ship in the RPi kernel source** (`arch/arm/boot/dts/overlays/tpm-slb9670-overlay.dts`, using the real hardware SPI0 controller). It was used and confirmed working for plain Linux-side detection early on. It does **not** work for the measured-boot goal, though: **mainline U-Boot has no BCM2711 hardware SPI0 controller driver at all — only a software `spi-gpio` bit-bang driver.** For U-Boot to reach the TPM before Linux ever starts (the entire point of this phase), the chip has to be wired up via `spi-gpio` instead. So [`tpm-slb9670-spi-gpio.dts`](meta-custom/recipes-bsp/tpm-overlay/files/tpm-slb9670-spi-gpio.dts) is a second hand-written overlay: bit-bangs SPI over GPIO7/9/10/11 (matching the physical wiring below), disables the stock hardware `spidev0`/`spidev1` nodes, and carries two extra properties (`tpm_event_log_addr`/`tpm_event_log_size`) that U-Boot's measured-boot code reads directly off this same TPM node — see [Measured Boot](#measured-boot) for why. The same overlay/FDT is applied once at the RPi firmware stage and handed to both U-Boot and Linux, so Linux uses the bit-banged path too, not the faster hardware one.

Both compiled via [`tpm-overlay_1.0.bb`](meta-custom/recipes-bsp/tpm-overlay/tpm-overlay_1.0.bb) (`dtc-native`, standard Yocto `deploy` class pattern) and wired into the image via `local.conf` (see [`local.conf.snippet`](local.conf.snippet)) — `RPI_EXTRA_CONFIG` loads both overlays by name plus `dtparam=i2c_arm=on`/`dtoverlay=disable-bt`, `RPI_EXTRA_IMAGE_BOOT_FILES:append` copies the compiled `.dtbo`s into `/boot/overlays/`, `EXTRA_IMAGEDEPENDS:append = " tpm-overlay"` forces the build order.

Everything else in `local.conf` is standard feature-flag/package plumbing: `DISTRO_FEATURES`/`MACHINE_FEATURES` add `security`/`tpm2`/`ima` to pull in TCG-aware recipe logic from `meta-security`, and `IMAGE_INSTALL` adds the userspace TPM stack.

---

## Build

```bash
# from the Yocto build tree, with the layers above in bblayers.conf
# and the settings from local.conf.snippet merged into build/conf/local.conf

source poky/oe-init-build-env build
bitbake core-image-minimal
```

Flash `tmp/deploy/images/raspberrypi4-64/core-image-minimal-raspberrypi4-64.rootfs.wic.bz2` with `bmaptool copy` for a fast, checksum-verified sparse write.

> **Gotcha:** after changing anything under `meta-custom/recipes-bsp/tpm-overlay/`, run `bitbake -c cleansstate core-image-minimal` before rebuilding. `do_image_wic`'s task signature doesn't correctly depend on the `tpm-overlay` recipe's deployed output — a plain incremental build can silently keep flashing a stale overlay even though the recipe itself rebuilt correctly. Confirmed the hard way; cost real debugging time before the cause was found.

---

## Verified Working (on-device, over serial console)

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

> Note: this image's `head`/`tail`/etc. are BusyBox applets — they don't accept GNU long-form flags. Use `head -n 5`, not `head -5`. Serial console access is via a Bus Pirate configured as a transparent UART bridge (`m` → UART → 115200 8N1 → output type **Normal**, not Open Drain — Bus Pirate pins are open-drain by default and can't reach a valid logic-high without it — then `(1)` to start the bridge), wired to RPi physical pins 8 (TXD)/10 (RXD)/14 (GND).

---

## Verified Working — SPI TPM (SLB9670)

Same checks as above, repeated against the Xenon SLB9670 board over the bit-banged `spi-gpio` path:

```bash
dmesg | grep -i -E "spi|tpm"
```
```
tpm_tis_spi spi0.0: 2.0 TPM (device-id 0x1B, rev-id 22)
tpm_tis_i2c: probe of 1-002e failed with error -5
```
> The I2C probe failure is expected — that HAT is physically unwired now, both overlays are just kept active in `local.conf` for comparison.

```bash
ls /dev/tpm* /dev/spidev*
```
```
/dev/spidev0.0  /dev/tpm0  /dev/tpmrm0
```

Key hierarchy provisioned exactly as in Phase 1/the I2C chip (same handle map, fresh chip so no collision) and reads back cleanly through `abrmd`:
```bash
tpm2_getcap handles-persistent
```
```
- 0x81000001   # SRK
- 0x81000002   # AK
- 0x81010001   # EK
```

**Known intermittency:** the bit-banged, hand-soldered SPI connection occasionally fails to detect on a given boot (`tpm_tis_spi: probe of spi0.0 failed with error -110`, a timeout — or at the U-Boot stage, `tpm_tis_spi_probe: no device found`). A retry (power-cycle again) has always resolved it in testing. Root cause not pinned down further — plausibly signal-integrity marginality inherent to bit-banged SPI over hand-soldered wiring, worth stating as a known limitation rather than a solved problem.

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
| 7 | Xenon SLB9670 board wired via bit-banged SPI, detected, key hierarchy provisioned | ✅ |
| 8 | U-Boot boots via `bootm`+FIT, measures bootargs → PCR 1 and kernel image → PCR 8 | ✅ |
| 9 | Deterministic PCR baseline confirmed across genuine power cycles | ✅ |
| 10 | IMA — kernel-side userspace measurement into PCR 10, continuing the chain past U-Boot | ✅ |
| 11 | Networked remote attestation (verifier ↔ device, nonce-anchored AK-signed quote) | ✅ |

---

## Measured Boot

The goal: U-Boot measures boot-time state into PCRs before Linux starts, and (once IMA is wired up) the kernel's IMA subsystem continues measuring userspace into a further PCR after boot — a real pre-boot-to-userspace measurement chain, not just the manual PCR-extend demo from Phase 1.

### Why SPI, not I2C

**I2C access from U-Boot on Raspberry Pi is broken upstream.** [`agherzan/meta-raspberrypi#1358`](https://github.com/agherzan/meta-raspberrypi/issues/1358) documents someone hitting this exact wall — I2C TPM access from U-Boot on an RPi CM4, same `scarthgap` release used here. The I2C bus never probes in U-Boot (`dm tree` shows the driver never binds, error -19) despite correct config — a platform-level limitation, not specific to this TPM chip. Still open/unresolved upstream. SPI is the only viable path for the pre-boot half of the chain.

### Hardware

Measured boot uses a **second TPM board**, not the Phase 1/2 HAT: an Infineon **Xenon SPI TPM** (`TPM7020XENONBOARDTOBO1`), chip **SLB9670** (SPI-only). Same chip family as the [`wxleong/tpm2-uboot-rpi4`](https://github.com/wxleong/tpm2-uboot-rpi4) reference build. The original Phase 1/2 HAT is I2C-only/hardwired with no SPI option, hence the second board.

**Connector gotcha:** the Xenon board's SPI header is a 1.27mm-pitch (50 mil) female receptacle — physically the wrong pitch for standard jumper wires (designed for a ribbon cable into a PC motherboard's onboard TPM header, not dev-board wiring). Resolved by hand-soldering wires to all 20 pins onto a standard 2.54mm header, then jumpering normally.

Wiring (RPi4, bit-banged SPI via `spi-gpio`):

| Xenon pin | Signal | RPi4 physical pin | GPIO |
|---|---|---|---|
| 6 | VDD | 1 | 3.3V |
| 5 | GND | 9 | — |
| 7 | SCLK | 23 | GPIO11 |
| 10 | MISO | 21 | GPIO9 |
| 12 | MOSI | 19 | GPIO10 |
| 13 | TPM_CS | 26 | GPIO7 |
| 19 | PLT_RST | left unconnected | works fine floating for detection/provisioning/measurement — see the PCR-determinism note below for the one place this actually matters |

**UART debug console** (separate from the TPM wiring, used throughout this bring-up): Bus Pirate as a transparent bridge, GND/RXD/TXD → RPi physical pins 14/10/8.

### PCR allocation

| PCR | Source | Notes |
|---|---|---|
| 1 | U-Boot, bootargs hash | Deterministic — confirmed identical across genuine power cycles |
| 8 | U-Boot, kernel image hash | Deterministic — confirmed identical across genuine power cycles |
| 10 | Kernel IMA, userspace measurements | Standard TCG PC Client convention for OS-controlled PCRs — see [IMA](#ima--pcr-10) |
| 23 | Existing Phase 1/2 manual demo | Unchanged, kept as-is |

**PCR 0 (devicetree) was in the original plan but is deliberately *not* measured.** See the debugging notes below for why — short version: the RPi firmware injects a fresh random `kaslr-seed` into the devicetree on every boot, which makes whole-devicetree measurement (`CONFIG_MEASURE_DEVICETREE`) non-deterministic by construction. U-Boot's own Kconfig help text explicitly warns about this exact scenario. Framed honestly in this project as a real hardware/firmware limitation, not a gap — the same class of problem is why RPi4 has no real hardware CRTM either: it's a platform without full TCG PC Client compliance, and this project is explicit about which parts of the chain that affects.

### Software confirmed working

- `RPI_USE_U_BOOT = "1"` + `ENABLE_UART = "1"`
- `KERNEL_CLASSES = "kernel-fitimage"` / `KERNEL_IMAGETYPE = "fitImage"` / `KERNEL_BOOTCMD = "bootm"` — required for `bootm_measure()`'s kernel-image measurement to populate at all (`booti`'s raw-Image loader never fills in the fields it reads)
- `SERIAL_CONSOLES = "115200;ttyAMA0"` — matches `disable-bt` moving the physical UART console from the mini-UART to the PL011
- U-Boot Kconfig fragment (`meta-custom/recipes-bsp/u-boot/`): `CONFIG_MEASURED_BOOT=y`, `CONFIG_FIT=y`, `CONFIG_MEASURE_IGNORE_LOG=y`, `# CONFIG_MEASURE_DEVICETREE is not set`, TPM/SPI driver support, `CONFIG_SYS_BOOTM_LEN` bumped to 64MB
- `meta-custom/recipes-bsp/rpi-u-boot-scr/` — custom boot script staging the FIT at a separate scratch address (`0x04000000`) from the kernel's own decompression target (`0x200000`)
- `meta-custom/recipes-kernel/linux/` — TPM/SPI drivers forced builtin, `UBOOT_ENTRYPOINT`/`UBOOT_LOADADDRESS` corrected to the proper 2MB-aligned aarch64 address

### Verified golden PCR baseline (2026-08-29, re-baselined same day after IMA landed)

Confirmed **identical across two genuine power cycles** of the same unchanged image:

```
PCR 1 (sha256): 1872401838DC0197D6499A2950DD20A9400067441ED311E37095A9725B1B2AC8
PCR 8 (sha256): 208261DF4C05E875E696FBEF1A4801FA9C13A3F9C6B3680967647196F3815708
```

This is the reference the remote-attestation verifier (below) checks a quote's PCR values against. Note these differ from the values first captured earlier the same day — expected: adding `ima_policy=tcb` to the kernel command line changed bootargs (PCR 1), and the kernel rebuild for `CONFIG_IMA=y` changed the kernel image itself (PCR 8). Both legitimate changes to the actual boot chain, first caught by the attestation script itself correctly flagging a mismatch against the stale baseline, then re-confirmed deterministic across two fresh power cycles before being trusted as the new reference — same rigor as the original baseline.

**Critical testing-methodology note, learned the hard way:** PLT_RST is deliberately left floating (see Hardware above). Per the TPM2 spec, the *static* PCRs (0–16) only reset on an actual hardware reset signal to the chip — not a warm Linux `reboot`, not U-Boot's software `reset` command. A large chunk of this section's debugging time went into what looked like non-deterministic PCR values across "reboots" that were actually just extends silently accumulating on top of un-reset state. **Always fully power-cycle (unplug, wait, replug) before comparing PCR readings on this hardware** — a warm reboot proves nothing about determinism here.

### The debugging journey

Getting from "U-Boot never even reaches a banner" to the verified baseline above took ten distinct, independently-diagnosed bugs across the firmware/bootloader/kernel/build-system stack. Documented here because each is a real, citable finding, not just a fix log entry:

1. **`KERNEL_DEVICETREE = ""`** (set to keep the FIT image lean) had an unintended side effect: `meta-raspberrypi` ties its *entire* stock overlay deployment list (150+ files) to that same variable via a weak Kconfig-style default, so blanking it silently killed deployment of every overlay, not just the FIT-embedded dtb. Fixed by not blanking it — harmless, since `boot.scr` always passes the external, firmware-applied FDT to `bootm` explicitly and never reads the FIT's own dtb section anyway.
2. **`CONFIG_FIT` was never enabled** in U-Boot, despite `KERNEL_IMAGETYPE=fitImage` requiring it — `bootm` failed immediately with `Wrong Image Format for bootm command`.
3. **`meta-raspberrypi` hardcodes the kernel's load/entry address to `0x00008000`** unconditionally — correct for the 32-bit `raspberrypi4` machine, wrong for aarch64 `raspberrypi4-64` (needs the ARM64-standard `0x80000`+ range). A `local.conf` override lost the precedence fight against the recipe's own `.inc` file (recipe files parse after configuration files) — had to live in a `.bbappend` targeting that specific recipe.
4. Even at the "correct" `0x80000`, decompression still failed (`Error: inflate() returned -3`) — because that's also where the *compressed* FIT gets staged (`kernel_addr_r`, `meta-raspberrypi`'s stock boot script assumes `booti`, where staging and final address can safely be identical since there's no separate decompression step). Fixed with a custom boot script staging the FIT at a separate scratch address.
5. **`CONFIG_SYS_BOOTM_LEN` (max decompressed image size) defaulted to 16MB**; the kernel is ~26MB uncompressed (`Error: inflate() returned -5`, ran out of buffer). `meta-raspberrypi` ships its own conflicting fragment that reliably wins regardless of layer priority or file-shadowing tricks — only forcing the value directly via `scripts/config` in a `do_configure:append` reliably stuck.
6. **The TPM event log buffer was unsized** (`log too large: 0 + N > 0`) — and this turned out not to be cosmetic: U-Boot's `bootm_measure()` checks each measurement call's return value, which is whatever the log-append check returns even though the real PCR extend already happened; on failure it jumps straight past the devicetree/bootargs/kernel-image measurements entirely. Fixed by adding `tpm_event_log_addr`/`tpm_event_log_size` properties directly to the TPM's own device-tree node.
7. **PCR 0/1 came back identical, PCR 8 stayed all-zero** even after fix #6 — traced to `tcg2_measurement_init()`'s own first measurement (U-Boot's CRTM version string, into PCR 0) *also* hitting the same log-append failure, short-circuiting before `bootm_measure()` ever attempted the real measurements; its error-cleanup path extends PCRs 0–7 with a generic "separator" placeholder event instead. Fully resolved once #6 landed.
8. **A real Yocto/BitBake dependency-tracking gap**: `do_image_wic`'s task signature doesn't depend on the `tpm-overlay` recipe's output, so a plain incremental rebuild can silently keep the *old* overlay in the flashed image even after the recipe itself correctly rebuilds. Confirmed via md5sum comparison of the deploy directory's standalone `.dtbo` against the one actually bundled inside the `.wic`. Workaround: `bitbake -c cleansstate core-image-minimal` after touching that recipe.
9. **PCR 0 non-determinism, even with the log fixed**: the RPi firmware injects a fresh random `kaslr-seed` into the devicetree every boot; `CONFIG_MEASURE_DEVICETREE` hashes the whole DT blob, so PCR 0 could never be stable. U-Boot's own Kconfig help text explicitly documents this exact failure mode and recommends disabling the measurement — done.
10. **PCR 1/8 still varying** even after #9 — `CONFIG_MEASURE_IGNORE_LOG` (whose help text matches this project's setup almost verbatim: "platforms that use an event log memory region that persists through system resets") fixed the remaining instability, combined with the realization (see the golden-baseline note above) that much of the apparent remaining non-determinism was actually a testing-methodology issue, not a bug — warm reboots don't reset the TPM's static PCRs on this hardware.

Two Kconfig gotchas worth remembering for any future work on this tree: (a) when a symbol's Kconfig default is `y`, disabling it requires an explicit `# CONFIG_FOO is not set` line — simply omitting a `=y` assignment isn't enough, Kconfig just falls back to its own default; (b) a `local.conf` variable assignment can lose a precedence fight against a recipe's own `.inc` file, since recipe files are parsed after configuration files — needs a `.bbappend` targeting that specific recipe instead.

### Remaining work

- [ ] TPM event log: currently U-Boot-side-only scratch RAM, not backed by a proper `/reserved-memory` device-tree region, so not readable from Linux (`tpm2_eventlog`) without further work — either wire that up properly or document it as a deliberate, honestly-scoped limitation
- [ ] Explicit threat-model/limitations section for the thesis document itself: no hardware CRTM on RPi4 (this is a *logical* SRTM demonstration, not a true TCG PC Client chain), PLT_RST floating (documented tradeoff, not an oversight), devicetree measurement deliberately disabled (documented above), measured boot alone doesn't stop replay of an old-but-valid state
- [ ] AK-to-EK-to-manufacturer-CA chain validation — the remote-attestation verifier currently trusts the AK on first contact rather than validating it chains back to the already-extracted Infineon CA (Phase 1); see [Remote Attestation](#remote-attestation) for the exact scope note

---

## Remote Attestation

Extends Phase 1's local nonce-sign/PCR-quote-and-verify demo into a real network round-trip: a separate verifier machine challenges the Pi over SSH for a TPM quote, and cryptographically confirms the device's identity, the freshness of the response, and its PCR state — without trusting anything the device's own OS says about itself.

### Why a TPM quote proves something a plain PCR read doesn't

Anyone can SSH in and run `tpm2_pcrread` — that just prints numbers a compromised OS could lie about. A **quote** is different: the TPM chip itself (not the OS) bundles the current PCR values with a caller-supplied nonce and signs the bundle with the AK's private key, which never leaves the chip. A compromised kernel can't forge that signature, because it never has access to the key used to produce it.

- **Authenticity** — the verifier already holds the AK's public key (fetched once, cached, reused thereafter — the AK is a persistent handle, unchanged across boots). If the signature checks out, the quote really was produced by the physical chip that AK was generated inside back in Phase 1.
- **Freshness (anti-replay)** — every run generates a fresh random nonce, baked into the signed bundle. A captured old quote can't be replayed later; the nonce won't match.
- **Integrity** — once authenticity and freshness are established, the PCR values inside the quote are trustworthy too, and get checked against the golden baseline above.

### Design decisions

- **Transport: SSH**, not a custom listener. `sshd` was already running and proven; this needed no image rebuild and no new services.
- **PCR 10 handling**: unlike PCR 1/8 (fixed at boot), PCR 10 changes continuously as IMA measures every executed program — there's no single fixed "golden" value. The verifier captures the first-observed PCR 10 as a per-session baseline and treats later drift as a warning, not a failure.
- **AK enrollment**: trust-on-first-contact — the verifier fetches and caches the AK public key the first time it talks to a given device. A hardened version would validate the AK chains back to the EK/manufacturer CA (already extracted in Phase 1 — `certs/ek_cert_rsa.der`/`ek_cert_ecc.der`) via a secure, out-of-band enrollment step first. Documented as a deliberate scope limitation, not an oversight — listed in [Remaining work](#remaining-work).
- **PCR value decoding**: an earlier version of the verifier script read PCR values via a second, independent `tpm2_pcrread` call instead of extracting them from the already-verified quote data — a real (if narrow) gap, since that second read isn't covered by the signature check. Fixed by generating the quote with `tpm2_quote -F values` (a flat, headerless concatenation of the selected PCR digests) and verifying with `tpm2_checkquote -l <pcr-list>`, which makes `checkquote` parse that same format — confirmed against tpm2-tools 5.7's actual source (`tools/misc/tpm2_checkquote.c`) that this is a genuine alternate parser feeding the identical cryptographic check, not a bypass. PCR values are then decoded directly from the file `checkquote` already validated, not a separate side channel.

### Verified working (2026-08-29)

Script: [`scripts/attest-remote-verify.sh`](../scripts/attest-remote-verify.sh). Run from a separate machine on the same network as the Pi:

```bash
./scripts/attest-remote-verify.sh <pi-ip>
```

```
[PASS] AK public key saved — reused on every future run
[INFO] Nonce: 228b32be0399b94d81765a6bd6d7505699fbeee7
[PASS] Quote generated on device
[PASS] Quote files retrieved
[PASS] Quote signature verified — genuinely signed by this device's AK, over this exact nonce
[PASS] PCR 1 (bootargs) matches golden baseline
[PASS] PCR 8 (kernel image) matches golden baseline
[INFO] No PCR 10 baseline captured yet — saved this reading as the baseline for future comparisons
[PASS] Remote attestation SUCCEEDED — device identity + PCR state cryptographically verified
```

A second run against the same boot session additionally shows `PCR 10 (IMA) matches this session's captured baseline` — confirming the per-session PCR 10 comparison path also works as designed.

**How the golden baseline got re-established, itself a good demonstration of the mechanism:** the first live run against real hardware correctly *failed* — PCR 1 and PCR 8 both differed from the values captured earlier the same day, because the intervening IMA work had changed both the kernel command line and the compiled kernel image. That's the attestation script doing exactly its job: detecting that the device's measured state no longer matches the last known-good reference. Since the change was a deliberate, understood update (not tampering), the new values were re-confirmed deterministic across two genuine power cycles and adopted as the new golden baseline — see the note above.

---

## IMA — PCR 10

Continues the measurement chain from U-Boot's pre-boot work into the kernel's own runtime: the IMA (Integrity Measurement Architecture) subsystem hashes every executed program, mmap'd-for-exec file, and root-read file, extending PCR 10 for each one and keeping a parallel human-readable log in `securityfs`.

**`meta-security/meta-integrity`'s own automation doesn't apply to this project.** Its kernel-config bbappend (`linux-yocto%.bbappend`) only matches `linux-yocto*` recipes — this project uses `linux-raspberrypi`. Its policy-loading mechanism is a systemd service — this image runs busybox init. Both silently inapplicable, not broken; confirmed by reading the actual files rather than assuming the layer would "just work" once added to `bblayers.conf`. IMA is configured by hand instead:

- `meta-custom/recipes-kernel/linux/linux/ima.cfg` — `CONFIG_IMA=y` plus sub-options, every one verified against this exact kernel's own `security/integrity/ima/Kconfig` before writing the fragment (same discipline the measured-boot debugging journey above eventually settled into — applied from the start here, and it paid off: **this kernel defaults IMA to SHA1**, which would have been a real, easy-to-miss inconsistency with every other SHA256 PCR/quote in this project. Caught by reading source, not assumed.
- `CONFIG_IMA_APPRAISE` deliberately left off — measurement only, consistent with the project's "detect, don't enforce" scope (matches the unsigned-FIT U-Boot decision).
- Policy: the kernel's builtin **`ima_policy=tcb`** boot parameter (`local.conf`'s `CMDLINE:append`) — measures programs run/mmap'd-for-exec and files read by `uid=0`/`euid=0`. Chosen specifically to need no userspace policy-loading step, sidestepping meta-integrity's systemd-based approach entirely.
- `meta-security/meta-integrity` is in `bblayers.conf` purely for its `ima-evm-utils` recipe (`evmctl`) — confirmed its `REQUIRED_DISTRO_FEATURES` is just `"ima"` (already present) before adding it, not `"integrity"`. `"integrity"` was added to `DISTRO_FEATURES` anyway, purely to silence the layer's own cosmetic sanity-check warning — zero functional effect.

### Verified working (2026-08-29, first boot after the build — no debugging needed)

```bash
dmesg | grep -i ima
```
```
ima: Allocated hash algorithm: sha256
ima: No architecture policies found
```
> The second line is expected/harmless — it's about `CONFIG_IMA_ARCH_POLICY`, not enabled here, unrelated to the builtin `tcb` policy actually in use.

```bash
cat /sys/kernel/security/ima/policy
```
```
measure func=MMAP_CHECK mask=MAY_EXEC
measure func=BPRM_CHECK mask=MAY_EXEC
measure func=FILE_CHECK mask=^MAY_READ euid=0
measure func=FILE_CHECK mask=^MAY_READ uid=0
measure func=MODULE_CHECK
measure func=FIRMWARE_CHECK
measure func=POLICY_CHECK
```
(plus a block of `dont_measure fsmagic=...` lines excluding pseudo-filesystems — proc, sysfs, cgroup, etc.)

```bash
cat /sys/kernel/security/ima/ascii_runtime_measurements | tail -5
```
```
10 8a07230eaa15a29758948e9ecc34319fab650c10 ima-ng sha256:d1992ff6ac5beb7ea77ae32841538b9b8b8e6c55190be257296741c88c0da203 /etc/securetty
10 879614a97374eeab1fb579765b52437d724a8f31 ima-ng sha256:498cd2a39fd254eeff87a627291a39db405635f43f406fd5f698331ca2176034 /etc/shadow
10 97c602a4d581c657fdef61b9e3515aede7a4a089 ima-ng sha256:516ff71e65a80125307cabd2e1d99179232f600a7938ebacd36b8b0c0af18d58 /etc/login.access
10 6011fe89219293e10e6fd5432ab5acc45b67bc0c ima-ng sha256:0ab9dc72eeefb8ca403b4a4efa6abce1af3619a018b2700ee606d5be365d39e5 /etc/motd
10 676a7127a3dcae136ec8cdb0fc2d1a2d07a9c73d ima-ng sha256:740350672efd79493381d45565c7a708044b51d2b2c00f4647a1f6e87662b2d1 /etc/profile
```

```bash
tpm2_pcrread sha256:10
```
```
10 : 0xB3F369CB826EA1379B57EFC8182E8F71E892DFB2206423E68F2EA548F4515C8D
```
Genuine, non-zero — confirms IMA is actually extending the TPM, not just keeping an internal-only measurement list.

### Important nuance for remote attestation

Unlike PCR 1/8 (fixed once at boot, stays constant), **PCR 10 keeps changing for as long as the system runs** — IMA measures every executed program, so interactive shell commands (`cat`, `dmesg`, the very commands used to check the above) are themselves measured into it. There's no single fixed "golden" PCR 10 value the way PCR 1/8 have one; a golden baseline here means "the expected value immediately after boot, before interactive use." The remote-attestation verifier needs to account for this — e.g. by quoting PCR 10 at a defined checkpoint (right after boot, before shell access) — rather than treating it like a fixed constant.

Reference: [embetrix/meta-raspberrypi-secure](https://github.com/embetrix/meta-raspberrypi-secure), [wxleong/tpm2-uboot-rpi4](https://github.com/wxleong/tpm2-uboot-rpi4), [ejaaskel/meta-slb9670-rpi](https://github.com/ejaaskel/meta-slb9670-rpi) (branch `scarthgap-measured-boot-raspberrypi4-4gb`) — studied and adapted, not blindly copied; none of them matched this exact combination of `scarthgap` + hand-wired Xenon board + bit-banged SPI + aarch64, which is why the debugging journey above was necessary rather than a known recipe.
