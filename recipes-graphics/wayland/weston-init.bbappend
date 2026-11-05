# Cargt desktop background: the logo on Kaitoke Green (dark, default) or
# Light Gray, as in the boot splash. Both images are installed, so a device
# can switch by editing background-image/background-color in weston.ini.
# The images are the boot splash's 480 px logos, shared with psplash-drm.
# cargt-background-<theme>-small.png is the splash's 200 px logo padded to
# 200x48 with the theme color, for small panels such as the 320x240 00379
# SPI display (cargt-weston-spi-panel switches to it at runtime). An even
# height keeps "centered" on whole pixels; at 47 px the logo sat half a
# pixel off and its top and bottom rows blended into dark lines.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../recipes-core/psplash/files:"
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# "dark" or "light". Dark by default, after the light boot splash
# (CARGT_SPLASH_THEME in psplash-drm.bbappend).
CARGT_WESTON_THEME ?= "dark"
CARGT_WESTON_COLOR[dark] = "0xff004437"
CARGT_WESTON_COLOR[light] = "0xfff7f9fa"
# The panel (taskbar) in Cargt green instead of ST yellow: the web
# updater's navbar colours, Kaitoke Green on light and its darker shade on
# dark so the bar still shows against the Kaitoke Green desktop. Weston
# draws the clock in white, so the panel stays dark in both themes.
CARGT_WESTON_PANEL_COLOR[dark] = "0xff002a22"
CARGT_WESTON_PANEL_COLOR[light] = "0xff004437"

SRC_URI += " \
    file://cargt-logo-dark-480.png \
    file://cargt-logo-light-480.png \
    file://cargt-background-dark-small.png \
    file://cargt-background-light-small.png \
    file://cargt-weston-spi-panel \
    file://cargt-weston-spi-panel.service \
    file://cargt-spi-panel.conf \
"

# The ST weston.ini already has a [shell] background (ST's picture, scaled
# to fill) and panel colour, so replace those lines rather than add to
# them. Fail if the edit stops matching, so an ST update can't drop the
# Cargt look.
do_install:append() {
    for t in dark light; do
        install -Dm 0644 ${WORKDIR}/cargt-logo-$t-480.png ${D}${datadir}/weston/backgrounds/cargt-background-$t.png
        install -Dm 0644 ${WORKDIR}/cargt-background-$t-small.png ${D}${datadir}/weston/backgrounds/cargt-background-$t-small.png
    done
    ini=${D}${sysconfdir}/xdg/weston/weston.ini
    sed -i -e 's|^background-image=.*|background-image=${datadir}/weston/backgrounds/cargt-background-${CARGT_WESTON_THEME}.png|' \
        -e 's|^background-color=.*|background-color=${@d.getVarFlag("CARGT_WESTON_COLOR", d.getVar("CARGT_WESTON_THEME"))}|' \
        -e 's|^background-type=.*|background-type=centered|' \
        -e 's|^panel-color=.*|panel-color=${@d.getVarFlag("CARGT_WESTON_PANEL_COLOR", d.getVar("CARGT_WESTON_THEME"))}|' $ini
    grep -q '^background-image=.*cargt-background' $ini && grep -q '^background-type=centered' $ini && \
        grep -q '^panel-color=${@d.getVarFlag("CARGT_WESTON_PANEL_COLOR", d.getVar("CARGT_WESTON_THEME"))}$' $ini || \
        bbfatal "weston.ini from meta-st-openstlinux changed; update the edit in ${FILE}"
}

# Boot to the plain Weston desktop: weston-start runs every script in
# /usr/local/weston-start-at-startup with Weston, and ST's
# start_up_demo_launcher.sh there opens the full-screen demo launcher over
# it. Skip that one; the panel's Launcher button still opens it. This is
# done here because /usr/local is the userfs partition, which RAUC bundles
# don't update, so changing demo-launcher wouldn't reach updated boards.
do_install:append() {
    start=${D}${bindir}/weston-start
    sed -i -e '/for m in "$start_local_application_dir"\/\*; do/a\            [ "${m##*/}" = start_up_demo_launcher.sh ] \&\& continue' $start
    grep -q 'start_up_demo_launcher.sh ] && continue' $start || \
        bbfatal "weston-start from meta-st-openstlinux changed; update the edit in ${FILE}"
}

# The 00379 SPI display can't use the GPU (GL renderer) and needs the small
# logo: at boot, cargt-weston-spi-panel writes a pixman weston.ini to
# /run/cargt-weston when it finds the display, with an env file that the
# user weston.service drop-in reads to point XDG_CONFIG_HOME there.
do_install:append() {
    install -Dm 0755 ${WORKDIR}/cargt-weston-spi-panel ${D}${libexecdir}/cargt-weston-spi-panel
    install -Dm 0644 ${WORKDIR}/cargt-weston-spi-panel.service ${D}${systemd_system_unitdir}/cargt-weston-spi-panel.service
    install -Dm 0644 ${WORKDIR}/cargt-spi-panel.conf ${D}${systemd_user_unitdir}/weston.service.d/cargt-spi-panel.conf
}
SYSTEMD_SERVICE:${PN} += "cargt-weston-spi-panel.service"
FILES:${PN} += " \
    ${libexecdir}/cargt-weston-spi-panel \
    ${systemd_user_unitdir}/weston.service.d/cargt-spi-panel.conf \
"
