# Needed to tell Yocto to search inside this path
FILESEXTRAPATHS:prepend := "${THISDIR}/${LINUX_VERSION}:"


# KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00378', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00378_kernel_config_mods.config', '', d)} "
# KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00365', '${WORKDIR}/fragments/features/$n{LINUX_VERSION}/cargt_00365_kernel_config_mods.config', '', d)} "

KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = "${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00378_kernel_config_mods.config"
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = "${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00365_kernel_config_mods.config"


SRC_URI += " file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features"
SRC_URI += " file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features"


SRC_URI:class-devupstream += " file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features"
SRC_URI:class-devupstream += " file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features"


SRC_URI += " file://${LINUX_VERSION}/${LINUX_VERSION}${LINUX_SUBVERSION}/0003-Apply-patch-for-CC33xx-Driver.patch"
asdf