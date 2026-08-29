FILESEXTRAPATHS:prepend := "${THISDIR}/u-boot:"

SRC_URI += "file://tpm-measured-boot.cfg"

# meta-raspberrypi's own maxsize.cfg fragment (0x1000000, too small for our
# ~26.3MB kernel) reliably merges after our own CONFIG_SYS_BOOTM_LEN
# fragment content and silently wins, regardless of layer priority — tried
# and failed 2026-08-29 (see tpm-measured-boot.cfg's comment). Forcing it
# directly after do_configure (fragment merge + oldconfig already done) is
# the only thing that reliably sticks.
do_configure:append() {
    ${S}/scripts/config --file ${B}/.config --set-val SYS_BOOTM_LEN 0x4000000
}
