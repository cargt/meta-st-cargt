SUMMARY = "Device-scoped (eMMC vs SD card) partition symlinks for RAUC A/B"
DESCRIPTION = "Creates /run/cargt-part/<name> symlinks resolved against \
whichever physical MMC device root is actually mounted from, so RAUC and \
related tooling never fall back to the ambiguous system-wide \
/dev/disk/by-partlabel/<name> symlink when eMMC and SD card carry \
partitions with the same names."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://cargt-device-symlinks.sh \
           file://cargt-device-symlinks.service \
          "

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "cargt-device-symlinks.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -Dm 0755 ${WORKDIR}/cargt-device-symlinks.sh ${D}${libdir}/cargt/cargt-device-symlinks.sh
    install -Dm 0644 ${WORKDIR}/cargt-device-symlinks.service ${D}${systemd_system_unitdir}/cargt-device-symlinks.service
}

FILES:${PN} += "${libdir}/cargt ${systemd_system_unitdir}/cargt-device-symlinks.service"

RDEPENDS:${PN} += "util-linux-findmnt"
