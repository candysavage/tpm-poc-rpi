FILESEXTRAPATHS:prepend := "${THISDIR}/linux:"

SRC_URI += "file://tpm-spi-builtin.cfg"
SRC_URI += "file://ima.cfg"

# linux-raspberrypi.inc hardcodes UBOOT_ENTRYPOINT/UBOOT_LOADADDRESS to
# 0x00008000 (correct for 32-bit raspberrypi4, wrong for aarch64
# raspberrypi4-64's FIT+bootm path — see local.conf's KERNEL_CLASSES comment
# for the full "Error: inflate() returned -3" diagnosis, 2026-08-29). A
# local.conf override lost the precedence fight since recipe .inc files are
# parsed after configuration files — has to live in a .bbappend for this
# specific recipe to actually stick.
#
# 0x80000 got the boot chain working end-to-end (confirmed on real hardware
# 2026-08-29) but isn't 2MB-aligned, which the ARM64 boot protocol requires —
# the kernel printed "[Firmware Bug]: Kernel image misaligned at boot,
# please fix your bootloader!" and silently relocated itself to cope. Fixed
# properly: 0x200000 is the next 2MB boundary, still well clear of the FIT's
# own staging address (0x04000000, see rpi-u-boot-scr.bbappend).
UBOOT_ENTRYPOINT = "0x200000"
UBOOT_LOADADDRESS = "0x200000"
