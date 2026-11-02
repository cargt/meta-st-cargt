SUMMARY = "Drag-and-drop web page for installing a single RAUC bundle onto this board"
DESCRIPTION = "Dev/lab convenience, not a fleet-management tool - for pushing \
    one .raucb bundle to one bench-top board without hawkBit. Unauthenticated \
    by design: see the script's own docstring for why that's fine here."
LICENSE = "CLOSED & OFL-1.1"
# The page ships the Manrope font (SIL OFL 1.1)
LIC_FILES_CHKSUM = "file://Manrope-OFL.txt;md5=2fcaec0e88aa2184f928d27ff72284ed"

SRC_URI = "file://rauc-web-updater.py \
           file://rauc-web-updater.service \
           file://cargt.css \
           file://cargt-theme.js \
           file://cargt-logo-reversed.svg \
           file://cargt-favicon.png \
           file://Manrope-Variable.woff2 \
           file://Manrope-OFL.txt \
           "

S = "${WORKDIR}"

RDEPENDS:${PN} = "python3-core rauc"

inherit systemd

SYSTEMD_SERVICE:${PN} = "rauc-web-updater.service"

do_install() {
    install -Dm 0755 ${WORKDIR}/rauc-web-updater.py ${D}${bindir}/rauc-web-updater.py
    install -Dm 0644 ${WORKDIR}/rauc-web-updater.service ${D}${systemd_system_unitdir}/rauc-web-updater.service

    # Cargt branding (Brand Guidelines RD03), as on the i.MX SWUpdate web UI:
    # colours, Manrope, reversed logo, dark theme by default with a
    # light/dark toggle. rauc-web-updater.py serves these under /static/.
    install -d ${D}${datadir}/rauc-web-updater
    install -m 0644 ${WORKDIR}/cargt.css ${WORKDIR}/cargt-theme.js \
        ${WORKDIR}/Manrope-Variable.woff2 ${WORKDIR}/Manrope-OFL.txt \
        ${D}${datadir}/rauc-web-updater/
    install -m 0644 ${WORKDIR}/cargt-logo-reversed.svg ${D}${datadir}/rauc-web-updater/cargt-logo.svg
    install -m 0644 ${WORKDIR}/cargt-favicon.png ${D}${datadir}/rauc-web-updater/favicon.png
}

FILES:${PN} += "${systemd_system_unitdir}/rauc-web-updater.service ${datadir}/rauc-web-updater"
