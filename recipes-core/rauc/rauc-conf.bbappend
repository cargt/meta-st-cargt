FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Good-boot marking (rauc status mark-good after a successful boot) is
# handled by the rauc-mark-good sub-package meta-rauc's own "rauc" recipe
# already ships and RRECOMMENDS - no need to duplicate it here.
#
# system.conf is machine-specific (only its [system] compatible= line
# differs per board, but a mismatch there means a bundle built for one
# board silently fails RAUC's compatibility check on another) - fetched
# from a per-machine subdirectory rather than a single shared file, and
# explicitly installed over whatever the base rauc-conf recipe's own
# do_install already placed from its own generic example file.
SRC_URI:append:stm32mp25-cargt-00395-02-00365 = " file://stm32mp25-cargt-00395-02-00365/system.conf"
SRC_URI:append:stm32mp25-cargt-00395-01-00365 = " file://stm32mp25-cargt-00395-01-00365/system.conf"

SRC_URI:append = " \
    file://ca.cert.pem \
    file://post-install.sh \
    file://st-boot-script.sh \
"

do_install:append () {
    install -Dm 0644 ${WORKDIR}/${MACHINE}/system.conf ${D}${sysconfdir}/rauc/system.conf
    install -Dm 0755 ${WORKDIR}/post-install.sh ${D}${libdir}/rauc/post-install.sh
    install -Dm 0755 ${WORKDIR}/st-boot-script.sh ${D}${libdir}/rauc/st-boot-script.sh
}

FILES:${PN} += "${libdir}/rauc"

# st-boot-script.sh is #!/bin/bash, post-install.sh is #!/usr/bin/env
# python3 - neither interpreter is otherwise pulled in by this recipe's own
# RDEPENDS.
RDEPENDS:${PN} += "bash python3-core"
