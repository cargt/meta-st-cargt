# Upstream libiio ships iiod.service with a self-referential
# "Alias=iiod.service" in its own [Install] section. systemd refuses to
# enable a unit under a name it considers an alias of itself:
#   Failed to enable unit: Refusing to operate on alias name or linked
#   unit file: iiod.service
# which fails libiio-iiod's postinst and leaves the package half-configured.
# Strip the bogus self-alias; the unit still installs/enables normally
# under its own name without it.
do_install:append() {
    sed -i '/^Alias=iiod.service$/d' ${D}${systemd_system_unitdir}/iiod.service
}
