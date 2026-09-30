FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://0001-Initial-check-in-for-00378-support.patch \
            file://0002-stm32mp2-switch-off-pmic-on-system-off.patch \
            file://0003-stm32-stgen-read-rtc-before-disabling-counter-on-suspend.patch \
            "

