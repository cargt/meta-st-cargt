FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://0001-Initial-check-in-for-00378-support.patch \
            file://0002-stm32mp2-switch-off-pmic-on-system-off.patch \
            file://0003-stm32-stgen-read-rtc-before-disabling-counter-on-suspend.patch \
            file://0004-stm32mp2-dont-mask-pm-change-state-failure.patch \
            file://0005-stm32-rtc-align-shadow-register-timeout-with-other-.patch \
            file://0006-stm32-rtc-return-error-instead-of-panic-on-shadow-t.patch \
            file://0007-stm32-stgen-dont-panic-on-suspend-time-rtc-read-fai.patch \
            file://0008-stm32-stgen-dont-panic-on-resume-time-rtc-read-fail.patch \
            "

