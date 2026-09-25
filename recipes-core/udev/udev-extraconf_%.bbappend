FILESEXTRAPATHS:prepend := "${THISDIR}/udev-extraconf:"

# RAUC A/B boards only: stop the generic auto-mounter from grabbing our A/B
# partitions - see the ignorelist file's own comment for why this is a hard
# requirement (RAUC needs exclusive access to write the inactive slot).
SRC_URI:append = "${@bb.utils.contains('COMBINED_FEATURES', 'rauc', ' file://cargt-ab-partitions.ignorelist', '', d)}"

do_install:append() {
    if ${@bb.utils.contains('COMBINED_FEATURES', 'rauc', 'true', 'false', d)}; then
        install -m 0644 ${WORKDIR}/cargt-ab-partitions.ignorelist ${D}${sysconfdir}/udev/mount.ignorelist.d/
    fi
}

FILES:${PN} += "${sysconfdir}/udev/mount.ignorelist.d/cargt-ab-partitions.ignorelist"

# Content now depends on the machine (COMBINED_FEATURES includes
# MACHINE_FEATURES), so this can't stay a shared tune-arch package: without
# this, an A/B board and a single-bank board built in the same tree would
# share (and overwrite) one package with the wrong content for one of them.
PACKAGE_ARCH = "${MACHINE_ARCH}"
