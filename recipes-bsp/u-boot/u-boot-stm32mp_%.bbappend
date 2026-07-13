FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "${@bb.utils.contains('MACHINE_FEATURES', '00395 00365', 'file://0001-Add-fdtfile-definition-for-cargt-00395-00365.patch', '', d)} \
            file://0002-Autosave-env-when-defaults-are-set.patch \
            file://0003-Add-MMC-boot-configuration-commands-in-fb_mmc_boot_ops.patch \
            "