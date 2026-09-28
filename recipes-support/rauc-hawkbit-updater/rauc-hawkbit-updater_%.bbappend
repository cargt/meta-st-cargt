# files-local/ (gitignored) takes priority over files/ if present: real
# hawkbit_server/auth_token values for this dev machine's own test server,
# kept out of git so the committed files/ configs stay generic/replicable
# placeholders for anyone else cloning this layer (see docs/rauc-ota-updates.md §5).
FILESEXTRAPATHS:prepend := "${THISDIR}/files-local:${THISDIR}/files:"

# rauc-hawkbit-updater polls a hawkBit server, downloads the assigned bundle
# and hands it to RAUC over D-Bus - the "pull" counterpart to this project's
# manual scp+`rauc install` push testing. This is currently a testing tool
# only (server is a Docker container on a dev machine, not any kind of
# production infrastructure), so it's wired into cargt-image-dev only, not
# the weston production image - see cargt-image-dev.bb.
#
# One config per DUT (each needs its own hawkBit controller id + per-target
# security token, obtained by registering the target via hawkBit's
# management REST API - see docs/rauc-ota-updates.md).
SRC_URI:append:stm32mp25-cargt-00395-02-00365 = " file://config.conf.00395-02-00365"
SRC_URI:append:stm32mp25-cargt-00395-01-00365 = " file://config.conf.00395-01-00365"

do_install:append:stm32mp25-cargt-00395-02-00365 () {
    install -Dm 0644 ${WORKDIR}/config.conf.00395-02-00365 ${D}${sysconfdir}/rauc-hawkbit-updater/config.conf
}
do_install:append:stm32mp25-cargt-00395-01-00365 () {
    install -Dm 0644 ${WORKDIR}/config.conf.00395-01-00365 ${D}${sysconfdir}/rauc-hawkbit-updater/config.conf
}

# The installed config.conf differs per machine, so the package must be
# MACHINE_ARCH. The overrides above don't trigger bitbake's automatic
# machine-arch detection (that only looks for files in MACHINE-named
# FILESPATH dirs), so without this both boards share one cortexa35
# package and whichever was built last overwrites the other's config -
# shipping the wrong controller id/auth token.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# bundle_download_location (config.conf) points at userfs, not rootfs -
# rootfs is a fixed-size ~2GB A/B slot with no headroom for a multi-hundred-
# MB bundle download sitting alongside the live system. userfs isn't
# populated from the rootfs image (it's a separate, first-boot-provisioned
# partition), so the download directory has to be created at runtime -
# tmpfiles.d handles that on every boot regardless of whether userfs was
# freshly reformatted.
do_install:append () {
    install -d ${D}${nonarch_libdir}/tmpfiles.d
    echo "d /usr/local/rauc-hawkbit 0750 rauc-hawkbit rauc-hawkbit -" > ${D}${nonarch_libdir}/tmpfiles.d/rauc-hawkbit-updater.conf

    install -Dm 0755 ${WORKDIR}/update-device-attrs.sh ${D}${libexecdir}/rauc-hawkbit-updater/update-device-attrs.sh

    # The stock unit sets ProtectSystem=full, which read-only-protects /usr -
    # and /usr/local lives under /usr. Carve out an explicit exception rather
    # than relying on undocumented nested-mountpoint behavior.
    #
    # ExecStartPre refreshes config.conf's [device] section with the
    # runtime hostname/build marker before the main process reads it (see
    # update-device-attrs.sh) - it's prefixed "+" to run as root regardless
    # of the service's own User=rauc-hawkbit, since config.conf is root-owned.
    install -d ${D}${systemd_system_unitdir}/rauc-hawkbit-updater.service.d
    cat > ${D}${systemd_system_unitdir}/rauc-hawkbit-updater.service.d/local-storage.conf <<EOF
[Service]
ReadWritePaths=/usr/local/rauc-hawkbit
ExecStartPre=+${libexecdir}/rauc-hawkbit-updater/update-device-attrs.sh
EOF
}

SRC_URI += "file://update-device-attrs.sh"

FILES:${PN} += " \
    ${nonarch_libdir}/tmpfiles.d/rauc-hawkbit-updater.conf \
    ${systemd_system_unitdir}/rauc-hawkbit-updater.service.d/local-storage.conf \
    ${libexecdir}/rauc-hawkbit-updater/update-device-attrs.sh \
    "
