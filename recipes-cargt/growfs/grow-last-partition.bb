SUMMARY = "Grow the last GPT partition to fill available disk space on first boot"
SECTION = "devel"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

RDEPENDS:${PN} += "util-linux-sfdisk util-linux-partx"

SRC_URI = "file://grow-last-partition.service file://grow-last-partition"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_PACKAGES += " ${PN} "
SYSTEMD_SERVICE:${PN} = "grow-last-partition.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${systemd_unitdir}/system ${D}${base_sbindir}
    install -m 0644 ${WORKDIR}/grow-last-partition.service ${D}${systemd_unitdir}/system
    install -m 0755 ${WORKDIR}/grow-last-partition ${D}${base_sbindir}
}

FILES:${PN} += "${systemd_unitdir}/system/grow-last-partition.service"
