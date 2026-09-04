FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://0002-Autosave-env-when-defaults-are-set.patch \
            file://0003-Add-MMC-boot-configuration-commands-in-fb_mmc_boot_ops.patch \
            file://0004-Read-OTP-MAC-addresses-independently-so-partial-pro.patch \
            file://0005-stm32mp2-Add-missing-STM32MP255-cases-to-get_eth_nb.patch \
            "

# Per-machine fdtfile default: MACHINE-keyed (not MACHINE_FEATURES-keyed, which
# can't tell 00395-01-00365 and 00395-02-00365 apart since they share the same
# "00395 00365" features) so each board gets its own correctly-named
# devicetree instead of fdtfile being left unset.
SRC_URI:append:stm32mp25-cargt-00395-01-00365 = " file://stm32mp25-cargt-00395-01-00365/0001-Add-fdtfile-definition-for-cargt-00395-01-00365.patch"
SRC_URI:append:stm32mp25-cargt-00395-02-00365 = " file://stm32mp25-cargt-00395-02-00365/0001-Add-fdtfile-definition-for-cargt-00395-02-00365.patch"
