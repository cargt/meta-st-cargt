FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# NetworkManager is this distro's chosen network stack (NETWORK_MANAGER =
# "networkmanager", see conf/distro/) - systemd-networkd is still present
# (pulled in transitively, unused) and enabled by systemd's own upstream
# default preset. Both run in parallel, and network-online.target waits on
# BOTH their wait-online units - NetworkManager-wait-online finishes in
# ~17s, but systemd-networkd-wait-online has nothing it actually manages to
# report "online" and just sits until its own ~2 minute internal timeout
# before failing. Every unit ordered After=network-online.target (e.g.
# rauc-hawkbit-updater.service) pays that full 2-minute tax on every boot,
# for a stack that isn't even in use. A "00-" prefixed preset is read
# before systemd's own bundled default preset (alphabetical, first match
# wins), so this reliably overrides it.
#
# Gated on networkmanager rather than applied unconditionally, in case a
# future build relies on systemd-networkd as the sole network stack instead.
SRC_URI:append = "${@bb.utils.contains('DISTRO_FEATURES', 'networkmanager', ' file://00-cargt-disable-networkd.preset', '', d)}"

do_install:append () {
    if ${@bb.utils.contains('DISTRO_FEATURES', 'networkmanager', 'true', 'false', d)}; then
        install -d ${D}${nonarch_libdir}/systemd/system-preset
        install -m 0644 ${WORKDIR}/00-cargt-disable-networkd.preset ${D}${nonarch_libdir}/systemd/system-preset/00-cargt-disable-networkd.preset
    fi
}

FILES:${PN} += "${@bb.utils.contains('DISTRO_FEATURES', 'networkmanager', '${nonarch_libdir}/systemd/system-preset/00-cargt-disable-networkd.preset', '', d)}"
