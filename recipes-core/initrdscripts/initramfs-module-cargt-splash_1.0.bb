SUMMARY = "initramfs-framework module to start the Cargt boot splash early"
DESCRIPTION = "Starts the rootfs's psplash-drm from the initramfs once the \
rootfs is mounted, rather than waiting for systemd."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = "file://cargt-splash"

S = "${WORKDIR}"

inherit allarch

# After 90-rootfs has mounted the rootfs, before 99-finish switches to it
do_install() {
    install -Dm 0755 ${WORKDIR}/cargt-splash ${D}/init.d/91-splash
}

FILES:${PN} = "/init.d/91-splash"
RDEPENDS:${PN} = "initramfs-module-rootfs"
