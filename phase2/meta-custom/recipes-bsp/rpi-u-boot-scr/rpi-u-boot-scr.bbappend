FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# meta-raspberrypi's stock boot.cmd.in stages the whole file AND boots from
# the exact same address (${kernel_addr_r} for both fatload destination and
# the bootm/booti argument) — correct for the default booti path (raw,
# uncompressed, no separate decompression step), but wrong for bootm+FIT+gzip
# (our measured-boot switch, see local.conf's KERNEL_CLASSES comment): the
# compressed FIT and the decompressed kernel's load/entry (0x80000, the
# correct standard aarch64 address — see linux-raspberrypi bbappend) can't
# be the same address, or decompression corrupts its own still-unread
# source partway through ("Error: inflate() returned -3", confirmed on real
# hardware 2026-08-29 with two different load/entry values that both
# collided with kernel_addr_r=0x80000, just at different points). This
# override stages the FIT at a separate scratch address (0x04000000)
# instead, leaving the kernel's actual decompression target untouched.
