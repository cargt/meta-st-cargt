SUMMARY = "TI CC33xx WiFi firmware files"
DESCRIPTION = "${SUMMARY}"
LICENSE="CLOSED"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://cc33xx-conf.bin \
    file://cc33xx_2nd_loader.bin \
    file://cc33xx_fw.bin \
"

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/ti-connectivity
	install -m 0644 ${WORKDIR}/cc33xx-conf.bin ${D}${nonarch_base_libdir}/firmware/ti-connectivity/cc33xx-conf.bin
	install -m 0644 ${WORKDIR}/cc33xx_2nd_loader.bin ${D}${nonarch_base_libdir}/firmware/ti-connectivity/cc33xx_2nd_loader.bin
	install -m 0644 ${WORKDIR}/cc33xx_fw.bin ${D}${nonarch_base_libdir}/firmware/ti-connectivity/cc33xx_fw.bin
}

FILES:${PN} = " \
    ${nonarch_base_libdir}/firmware/ti-connectivity/* \
"

# Firmware files are generally not ran on the CPU, so they can be
# allarch despite being architecture specific
INSANE_SKIP = "arch"