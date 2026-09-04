SUMMARY = "NetworkManager connection profile for the KORE/Twilio Super SIM used by the onboard Telit CMB100 modem"
LICENSE = "CLOSED"

SRC_URI = "file://supersim.nmconnection"

S = "${WORKDIR}"

RDEPENDS:${PN} = "networkmanager"

do_install() {
    install -d ${D}${sysconfdir}/NetworkManager/system-connections
    install -m 0600 ${WORKDIR}/supersim.nmconnection ${D}${sysconfdir}/NetworkManager/system-connections/supersim.nmconnection
}

FILES:${PN} += "${sysconfdir}/NetworkManager/system-connections/supersim.nmconnection"

# NetworkManager requires connection files to be owner-only readable,
# and refuses to load ones that aren't.
CONFFILES:${PN} += "${sysconfdir}/NetworkManager/system-connections/supersim.nmconnection"
