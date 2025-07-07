# Needed to tell Yocto to search inside this path
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00378', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00378_kernel_config_mods.config', '', d)} "
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00365', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00365_kernel_config_mods.config', '', d)} "

SRC_URI += "file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features \
            file://0001-Initial-check-in-for-00378-support.patch \
            "

SRC_URI:class-devupstream += " file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features \
                               "
