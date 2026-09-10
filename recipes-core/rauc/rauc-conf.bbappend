FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Good-boot marking (rauc status mark-good after a successful boot) is
# handled by the rauc-mark-good sub-package meta-rauc's own "rauc" recipe
# already ships and RRECOMMENDS - no need to duplicate it here.
SRC_URI:append = " \
    file://system.conf \
    file://ca.cert.pem \
    file://post-install.sh \
    file://st-boot-script.sh \
"

do_install:append () {
    install -Dm 0755 ${WORKDIR}/post-install.sh ${D}${libdir}/rauc/post-install.sh
    install -Dm 0755 ${WORKDIR}/st-boot-script.sh ${D}${libdir}/rauc/st-boot-script.sh
}

FILES:${PN} += "${libdir}/rauc"

# st-boot-script.sh is #!/bin/bash, post-install.sh is #!/usr/bin/env
# python3 - neither interpreter is otherwise pulled in by this recipe's own
# RDEPENDS.
RDEPENDS:${PN} += "bash python3-core"
