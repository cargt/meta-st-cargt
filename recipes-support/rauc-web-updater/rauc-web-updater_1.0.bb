SUMMARY = "Drag-and-drop web page for installing a single RAUC bundle onto this board"
DESCRIPTION = "Dev/lab convenience, not a fleet-management tool - for pushing \
    one .raucb bundle to one bench-top board without hawkBit. Unauthenticated \
    by design: see the script's own docstring for why that's fine here."
LICENSE = "CLOSED"

SRC_URI = "file://rauc-web-updater.py \
           file://rauc-web-updater.service \
           "

S = "${WORKDIR}"

RDEPENDS:${PN} = "python3-core rauc"

inherit systemd

SYSTEMD_SERVICE:${PN} = "rauc-web-updater.service"

do_install() {
    install -Dm 0755 ${WORKDIR}/rauc-web-updater.py ${D}${bindir}/rauc-web-updater.py
    install -Dm 0644 ${WORKDIR}/rauc-web-updater.service ${D}${systemd_system_unitdir}/rauc-web-updater.service
}

FILES:${PN} += "${systemd_system_unitdir}/rauc-web-updater.service"
