FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://0002-Autosave-env-when-defaults-are-set.patch \
            file://0003-Add-MMC-boot-configuration-commands-in-fb_mmc_boot_ops.patch \
            file://0004-Read-OTP-MAC-addresses-independently-so-partial-pro.patch \
            file://0005-stm32mp2-Add-missing-STM32MP255-cases-to-get_eth_nb.patch \
            "
