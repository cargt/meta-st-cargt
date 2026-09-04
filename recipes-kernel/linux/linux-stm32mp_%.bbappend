# Needed to tell Yocto to search inside this path
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00395', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00395_kernel_config_mods.config', '', d)} "
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00378', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00378_kernel_config_mods.config', '', d)} "
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00365', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00365_kernel_config_mods.config', '', d)} "
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00393', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00393_kernel_config_mods.config', '', d)} "

SRC_URI += "file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_00395_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_00393_kernel_config_mods.config;subdir=fragments/features \
            "

# 00378 SOM: CC33xx wifi/bt driver
SRC_URI += "${@bb.utils.contains('MACHINE_FEATURES', '00378', 'file://${LINUX_VERSION}/0001-Apply-patch-for-CC33xx-Driver.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00378', 'file://${LINUX_VERSION}/0002-Fix-patch-for-Makefile-to-include-driver-CC33XX-sour.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00378', 'file://${LINUX_VERSION}/0003-Fix-crash-during-driver-initialization.-See-https-e2.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00378', 'file://${LINUX_VERSION}/0004-Initial-check-in-for-00378-support.patch', '', d)} \
            "

# 00365 carrier board: display support
SRC_URI += "${@bb.utils.contains('MACHINE_FEATURES', '00365', 'file://${LINUX_VERSION}/0005-Add-support-for-Globaltech-GTG-Panels.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00365', 'file://${LINUX_VERSION}/0006-Add-support-for-max25221-for-10in-LVDS-display.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00365', 'file://${LINUX_VERSION}/0008-Add-support-for-GLT028240320IS1-display-on-STM32MP2.patch', '', d)} \
            "

# 00365 carrier board: PCIe reset GPIO fix
SRC_URI += "${@bb.utils.contains('MACHINE_FEATURES', '00365', 'file://${LINUX_VERSION}/0009-pcie-stm32-use-cansleep-gpio-api-for-reset.patch', '', d)} \
            "

# RX8111 RTC: present on both SOMs (00395 and 00378)
SRC_URI += "${@bb.utils.contains('MACHINE_FEATURES', '00395', 'file://${LINUX_VERSION}/0007-Add-support-for-RX8111-RTC-on-00395.patch', '', d)} \
            ${@bb.utils.contains('MACHINE_FEATURES', '00378', 'file://${LINUX_VERSION}/0007-Add-support-for-RX8111-RTC-on-00395.patch', '', d)} \
            "

# stm32-usart break_ctl pm_runtime race fix: not tied to any one board's
# MACHINE_FEATURES - it's a generic driver correctness fix (async
# pm_runtime_get() racing an immediate register write) that can affect any
# STM32MP2 board with a UART-attached device that issues an out-of-band
# break control (observed via btnxpuart's power-save workqueue on 00395),
# so apply it unconditionally rather than gating it.
SRC_URI += "file://${LINUX_VERSION}/0010-serial-stm32-fix-break_ctl-pm_runtime-race.patch"

# tcpci ALERT_MASK is missing several legitimate alert types (FAULT,
# VBUS_DISCNCT, RX_BUF_OVF, V_ALARM_LO/HI), causing "irq N: nobody
# cared" and a disabled TCPC interrupt line when a PD-negotiating host
# triggers one repeatedly. Generic driver correctness fix, not tied to
# any one board - see the patch for the observed failure.
SRC_URI += "file://${LINUX_VERSION}/0011-usb-typec-tcpci-unmask-fault-vbus-discnct-alerts.patch"

SRC_URI:class-devupstream += " file://${LINUX_VERSION}/cargt_00395_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_00393_kernel_config_mods.config;subdir=fragments/features \
                               "
