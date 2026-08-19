# alsa-state's postinst unconditionally does:
#   alsactl -g -f ${localstatedir}/lib/alsa/asound.state restore
# with no existence check, but the file it restores from ships in the
# separate alsa-states package, which alsa-state only RRECOMMENDS (not
# RDEPENDS). If alsa-states isn't installed, postinst fails with
# "Cannot open .../asound.state for reading: No such file or directory"
# and leaves the package half-configured.
# Make the dependency hard so the state file is always present.
RDEPENDS:${PN} += "alsa-states"
