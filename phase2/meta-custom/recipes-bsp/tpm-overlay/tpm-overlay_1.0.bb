SUMMARY = "TPM device tree overlays (SLB9673 I2C, SLB9670 SPI-GPIO)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://tpm-slb9673-i2c.dts \
           file://tpm-slb9670-spi-gpio.dts \
"

DEPENDS = "dtc-native"

S = "${WORKDIR}"

inherit deploy nopackages

do_compile() {
    dtc -@ -I dts -O dtb -o tpm-slb9673-i2c.dtbo tpm-slb9673-i2c.dts
    dtc -@ -I dts -O dtb -o tpm-slb9670-spi-gpio.dtbo tpm-slb9670-spi-gpio.dts
}

do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 tpm-slb9673-i2c.dtbo ${DEPLOYDIR}/
    install -m 0644 tpm-slb9670-spi-gpio.dtbo ${DEPLOYDIR}/
}

addtask deploy before do_build after do_compile

COMPATIBLE_MACHINE = "raspberrypi4-64"
