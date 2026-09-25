FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Good-boot marking (rauc status mark-good after a successful boot) is
# handled by the rauc-mark-good sub-package meta-rauc's own "rauc" recipe
# already ships and RRECOMMENDS - no need to duplicate it here.
#
# Everything below is A/B-board specific and gated on COMBINED_FEATURES
# "rauc" (DISTRO_FEATURES "rauc" AND the machine's MACHINE_FEATURES
# "rauc"). A machine without the A/B layout that still ends up with rauc
# installed (e.g. via meta-rauc's packagegroup-base-rauc) falls back to
# meta-rauc's stock example config instead of failing do_install on a
# missing per-machine system.conf.
#
# system.conf is machine-specific (only its [system] compatible= line
# differs per board, but a mismatch there means a bundle built for one
# board silently fails RAUC's compatibility check on another) - fetched
# from a per-machine subdirectory rather than a single shared file, and
# explicitly installed over whatever the base rauc-conf recipe's own
# do_install already placed from its own generic example file. (ca.cert.pem
# needs no SRC_URI entry: the base recipe already fetches it, and
# FILESEXTRAPATHS makes it pick up this layer's copy.)
CARGT_RAUC_AB = "${@bb.utils.contains('COMBINED_FEATURES', 'rauc', '1', '0', d)}"

SRC_URI:append = "${@' file://${MACHINE}/system.conf file://post-install.sh file://st-boot-script.sh' if d.getVar('CARGT_RAUC_AB') == '1' else ''}"

do_install:append () {
    if [ "${CARGT_RAUC_AB}" = "1" ]; then
        install -Dm 0644 ${WORKDIR}/${MACHINE}/system.conf ${D}${sysconfdir}/rauc/system.conf
        install -Dm 0755 ${WORKDIR}/post-install.sh ${D}${libdir}/rauc/post-install.sh
        install -Dm 0755 ${WORKDIR}/st-boot-script.sh ${D}${libdir}/rauc/st-boot-script.sh
    fi
}

FILES:${PN} += "${libdir}/rauc"

# st-boot-script.sh is #!/bin/bash, post-install.sh is #!/usr/bin/env
# python3 - neither interpreter is otherwise pulled in by this recipe's own
# RDEPENDS.
RDEPENDS:${PN} += "${@'bash python3-core' if d.getVar('CARGT_RAUC_AB') == '1' else ''}"

# Per-machine content.
PACKAGE_ARCH = "${MACHINE_ARCH}"
