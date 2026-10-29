# Cargt boot splash: the Cargt logo, centred, in a light (default) or dark
# theme, turned with the panel like the Weston desktop. The same logos and
# colours as the psplash splash in meta-imx-cargt. ST's display has no fbdev
# emulation, so this stays on ST's DRM/KMS psplash-drm rather than oe-core
# psplash; there's no progress bar.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# "light" or "dark"; written to /etc/default/psplash, which can be edited
# on the device. Light by default, going into the dark Weston desktop
# (CARGT_WESTON_THEME in weston-init.bbappend).
CARGT_SPLASH_THEME ?= "light"

SRC_URI += " \
    file://0001-psplash-drm-add-angle-to-turn-the-image-with-the-pan.patch \
    file://cargt-logo-light-480.png \
    file://cargt-logo-light-200.png \
    file://cargt-logo-dark-480.png \
    file://cargt-logo-dark-200.png \
    file://cargt-psplash-drm-start \
    file://zz-cargt.conf \
"

# The theme can differ per machine and lands in /etc/default/psplash
PACKAGE_ARCH = "${MACHINE_ARCH}"
# Changes feed (cortexa35 -> board); see the PR note in conf/layer.conf.
PR = "r1"

do_install:append() {
    for t in light dark; do
        for s in 480 200; do
            install -m 0644 ${WORKDIR}/cargt-logo-$t-$s.png ${D}${datadir}/splashscreen/
        done
    done
    install -Dm 0755 ${WORKDIR}/cargt-psplash-drm-start ${D}${libexecdir}/psplash/cargt-psplash-drm-start

    install -d ${D}${sysconfdir}/default
    echo "CARGT_SPLASH_THEME=${CARGT_SPLASH_THEME}" > ${D}${sysconfdir}/default/psplash

    if ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'true', 'false', d)}; then
        install -Dm 0644 ${WORKDIR}/zz-cargt.conf \
            ${D}${systemd_system_unitdir}/psplash-drm-start.service.d/zz-cargt.conf
    fi
}

FILES:${PN} += " \
    ${libexecdir}/psplash \
    ${sysconfdir}/default/psplash \
    ${systemd_system_unitdir}/psplash-drm-start.service.d \
"
CONFFILES:${PN} += "${sysconfdir}/default/psplash"
