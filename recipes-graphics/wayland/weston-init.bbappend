# Cargt desktop background: the logo on Kaitoke Green (dark, default) or
# Light Gray, as in the boot splash. Both images are installed, so a device
# can switch by editing background-image/background-color in weston.ini.
# The images are the boot splash's 480 px logos, shared with psplash-drm.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../recipes-core/psplash/files:"

# "dark" or "light". Dark by default, after the light boot splash
# (CARGT_SPLASH_THEME in psplash-drm.bbappend).
CARGT_WESTON_THEME ?= "dark"
CARGT_WESTON_COLOR[dark] = "0xff004437"
CARGT_WESTON_COLOR[light] = "0xfff7f9fa"

SRC_URI += " \
    file://cargt-logo-dark-480.png \
    file://cargt-logo-light-480.png \
"

# The ST weston.ini already has a [shell] background (ST's picture, scaled
# to fill), so replace those lines rather than add to them. Fail if the
# edit stops matching, so an ST update can't drop the Cargt background.
do_install:append() {
    for t in dark light; do
        install -Dm 0644 ${WORKDIR}/cargt-logo-$t-480.png ${D}${datadir}/weston/backgrounds/cargt-background-$t.png
    done
    ini=${D}${sysconfdir}/xdg/weston/weston.ini
    sed -i -e 's|^background-image=.*|background-image=${datadir}/weston/backgrounds/cargt-background-${CARGT_WESTON_THEME}.png|' \
        -e 's|^background-color=.*|background-color=${@d.getVarFlag("CARGT_WESTON_COLOR", d.getVar("CARGT_WESTON_THEME"))}|' \
        -e 's|^background-type=.*|background-type=centered|' $ini
    grep -q '^background-image=.*cargt-background' $ini && grep -q '^background-type=centered' $ini || \
        bbfatal "weston.ini from meta-st-openstlinux changed; update the edit in ${FILE}"
}
