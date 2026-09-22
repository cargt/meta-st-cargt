# Needed to tell Yocto to search inside this path
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00395', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00395_kernel_config_mods.config', '', d)} "
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00378', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00378_kernel_config_mods.config', '', d)} "
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00365', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00365_kernel_config_mods.config', '', d)} "
KERNEL_CONFIG_FRAGMENTS:append:stm32mp2common = " ${@bb.utils.contains('MACHINE_FEATURES', '00393', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_00393_kernel_config_mods.config', '', d)} "

# RAUC A/B OTA updates: dm-verity bundle verification + loop/dm/squashfs
# support RAUC itself needs. Gated on DISTRO_FEATURES (not MACHINE_FEATURES)
# since it's set distro-wide for cargt-openstlinux-weston, not per-board.
KERNEL_CONFIG_FRAGMENTS:append = " ${@bb.utils.contains('DISTRO_FEATURES', 'rauc', '${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_rauc_kernel_config_mods.config', '', d)} "

# Hung-task/workqueue-stall detection: not tied to any one board's
# MACHINE_FEATURES or to RAUC - any board with a hardware watchdog armed
# benefits equally, since this closes a real gap where a localized
# in-kernel deadlock (one lock held forever, everything downstream of it
# wedged) is invisible to a watchdog that's still being fed by an
# unaffected systemd main loop. Apply unconditionally.
KERNEL_CONFIG_FRAGMENTS:append = " ${WORKDIR}/fragments/features/${LINUX_VERSION}/cargt_watchdog_hardening_kernel_config_mods.config "

SRC_URI += "file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_00395_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_00393_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_rauc_kernel_config_mods.config;subdir=fragments/features \
            file://${LINUX_VERSION}/cargt_watchdog_hardening_kernel_config_mods.config;subdir=fragments/features \
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
#
# On its own this does NOT prevent the external abort it was written
# against - this port's pm_runtime callbacks never touch the actual
# peripheral clock (a separate .pm/uart_close() path does that), so
# pm_runtime_resume_and_get() here can succeed while the clock is still
# off. See 0012 for the real fix (in btnxpuart itself), found after the
# abort recurred - twice, on two different boards - with this patch
# already applied. Kept anyway: it's a real, harmless correctness
# improvement for a related (if largely dormant) async-resume-vs-
# system-suspend edge case.
SRC_URI += "file://${LINUX_VERSION}/0010-serial-stm32-fix-break_ctl-pm_runtime-race.patch"

# tcpci ALERT_MASK is missing several legitimate alert types (FAULT,
# VBUS_DISCNCT, RX_BUF_OVF, V_ALARM_LO/HI), causing "irq N: nobody
# cared" and a disabled TCPC interrupt line when a PD-negotiating host
# triggers one repeatedly. Generic driver correctness fix, not tied to
# any one board - see the patch for the observed failure.
SRC_URI += "file://${LINUX_VERSION}/0011-usb-typec-tcpci-unmask-fault-vbus-discnct-alerts.patch"

# btnxpuart_close() doesn't stop its own power-save timer/workqueue
# before tearing down the serdev port, letting a concurrent
# ps_work_func() call serdev_device_break_ctl() on a port that's
# already had its UART clock gated by close - the actual root cause of
# the stm32-usart external abort 0010 (above) was written against but
# doesn't prevent. Generic driver bug (mainline has the same gap as of
# this writing), not tied to any one board - see the patch for the full
# race and why it wedges the whole system, not just Bluetooth.
SRC_URI += "file://${LINUX_VERSION}/0012-bluetooth-btnxpuart-stop-ps-timer-work-before-close.patch"

# stm32_usart_shutdown() has the same non-blocking-pm_runtime_get()-vs-
# immediate-hardware-teardown pattern 0010 fixed in break_ctl(), but at a
# different call site: it races its own deferred runtime-PM resume
# (queued on the "pm" workqueue) against its own RX DMA channel terminate
# a few lines later, with no lock between them. Neither 0010 nor 0012
# touch this path - 0012 only stops btnxpuart's ps timer/work from racing
# close(), which doesn't help once shutdown() is running and simply
# finds the port already suspended. Found via System_hanging.log (Oops
# in vchan_tx_submit() on a LIST_POISON dereference). Generic driver
# correctness fix, not tied to any one board - see the patch.
SRC_URI += "file://${LINUX_VERSION}/0013-serial-stm32-fix-pm_runtime-race-in-shutdown-vs-rx-dma.patch"

SRC_URI:class-devupstream += " file://${LINUX_VERSION}/cargt_00395_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_00378_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_00365_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_00393_kernel_config_mods.config;subdir=fragments/features \
                               file://${LINUX_VERSION}/cargt_rauc_kernel_config_mods.config;subdir=fragments/features \
                               "
