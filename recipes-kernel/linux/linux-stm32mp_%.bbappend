# Needed to tell Yocto to search inside this path
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00395', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00395_kernel_config_mods.config', '', d)} "
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00378', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00378_kernel_config_mods.config', '', d)} "
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00365', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00365_kernel_config_mods.config', '', d)} "

SRC_URI += "file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_00395_kernel_config_mods.config;subdir=fragments/features \
            file://fragment.cfg \
            "


SRC_URI += "${@bb.utils.contains('MACHINE_FEATURES', '00378', 'file://${LINUX_VERSION}/0004-Initial-check-in-for-00378-support.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00365', 'file://${LINUX_VERSION}/0005-Add-support-for-Globaltech-GTG-Panels.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00365', 'file://${LINUX_VERSION}/0006-Add-support-for-max25221-for-10in-LVDS-display.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00395', 'file://${LINUX_VERSION}/0007-Add-support-for-RX8111-RTC-on-00395.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00365', 'file://${LINUX_VERSION}/0008-Add-support-for-GLT028240320IS1-display-on-STM32MP2.patch', '', d)} \
            "

SRC_URI:class-devupstream += " file://${LINUX_VERSION}/cargt_00395_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features \
                               "
