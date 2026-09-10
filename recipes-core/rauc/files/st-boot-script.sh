#!/bin/bash
# RAUC "custom" bootloader backend for the TF-A FWU metadata A/B scheme.
# Called by rauc as: <script> get-primary | set-primary BOOTNAME | get-state

arg1=$1

# Called by rauc right after a successful install, to commit BOOTNAME (A/B)
# as the slot to boot next. U-Boot's own bootcmd unconditionally does
# `setenv altboot 0` on every normal boot (see
# 0006-stm32mpu-update-env-to-support-boot-A-B.patch) - there is no
# automatic TF-A-to-U-Boot hand-off of the FWU-selected bank in this
# ecosystem version, so without this, U-Boot always re-selects slot A
# regardless of what update_metadata.sh wrote. Persistently swapping
# bootcmd itself (rather than relying on bootcount/altbootcmd, which isn't
# even enabled - no CONFIG_BOOTCOUNT_LIMIT in this defconfig) makes U-Boot
# pick the right slot on the very next power-on.
if [ "$arg1" = "set-primary" ]
then
    bootname=$2
    case "$bootname" in
        A)
            fw_setenv bootcmd "echo 'Boot A';setenv altboot 0;run bootcmd_stm32mp"
            ;;
        B)
            fw_setenv bootcmd "echo 'Boot B';setenv altboot 1;run bootcmd_stm32mp"
            ;;
        *)
            echo "set-primary: unknown bootname '$bootname'" >&2
            exit 1
            ;;
    esac
    exit $?
fi

if [ "$arg1" = "get-primary" ]
then
    cat /proc/cmdline | grep "rauc.slot=A" > /dev/null
    if test $? == 0
    then
        # Currently on A and it booted fine: leave trial mode (accept it).
        /usr/lib/fwu/update_metadata.sh 0 0 accept > /dev/null
        echo "A"
    else
        /usr/lib/fwu/update_metadata.sh 1 1 accept > /dev/null
        echo "B"
    fi
    exit 0
fi

# Reached when st-status-mark-good.sh calls `rauc status mark-good` after a
# successful boot.
if [ "$arg1" = "get-state" ]
then
    echo "good"
    exit 0
fi
