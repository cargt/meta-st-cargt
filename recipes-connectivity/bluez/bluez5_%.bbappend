FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://nxp-bluetooth.service \
            file://nxp-bluetooth-blacklist.conf \
            "

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/nxp-bluetooth.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/nxp-bluetooth-blacklist.conf ${D}${sysconfdir}/modprobe.d/
}

FILES:${PN} += "${sysconfdir}/modprobe.d/nxp-bluetooth-blacklist.conf"

SYSTEMD_AUTO_ENABLE = "enable"
SYSTEMD_SERVICE:${PN} += "nxp-bluetooth.service"
