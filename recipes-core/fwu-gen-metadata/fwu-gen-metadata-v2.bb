SUMMARY = "Tool to write FWU metadata (v2 format) with u-boot's mkfwumdata"
LICENSE = "BSD-2-Clause"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/BSD-2-Clause;md5=cb641bc04cda31daea161b1bc15da69f"

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI = "file://update_metadata.sh"

S = "${WORKDIR}/git"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    install -d ${D}${libdir}/fwu
    install -m 0755 ${WORKDIR}/update_metadata.sh ${D}${libdir}/fwu/
}

FILES:${PN} += "${libdir}/fwu"

RDEPENDS:${PN} += "bash u-boot-tools-stm32mp"
