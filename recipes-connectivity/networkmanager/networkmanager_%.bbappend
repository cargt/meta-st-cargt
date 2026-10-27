# Build nmtui (NetworkManager's text UI, needs libnewt) so cargt-image-dev can
# ship it. The networkmanager package RRECOMMENDS every enabled sub-package, so
# drop nmtui from that list: other images keep nmcli only, and an image that
# wants nmtui asks for networkmanager-nmtui by name.
PACKAGECONFIG:append = " nmtui"
RRECOMMENDS:${PN}:remove = "${PN}-nmtui"
