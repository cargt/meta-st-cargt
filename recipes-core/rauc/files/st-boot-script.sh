#!/bin/bash
# RAUC "custom" bootloader backend for the TF-A FWU metadata A/B scheme,
# backed by U-Boot's env-based bootcount mechanism for automatic rollback
# safety (see 0007-enable-bootcount-env-for-ab-rollback-safety.patch).
# Called by rauc as: <script> get-primary | set-primary BOOTNAME | get-state

arg1=$1

# Matches CONFIG_BOOTCOUNT_BOOTLIMIT in the U-Boot patch - kept here too
# (not just relied on as a compiled-in default) because U-Boot only
# populates NEW default env entries into a genuinely fresh/reset
# environment; an environment already persisted by an older U-Boot build
# (i.e. any board that already went through provisioning before this
# rollback-safety feature existed) carries forward unaffected, silently
# leaving bootlimit unset and the whole safety net disabled. Setting it
# explicitly here makes set-primary self-installing regardless of when
# the board's environment was first created.
BOOTLIMIT=3

bootcmd_for() {
    case "$1" in
        A) echo "echo 'Boot A';setenv altboot 0;run bootcmd_stm32mp" ;;
        B) echo "echo 'Boot B';setenv altboot 1;run bootcmd_stm32mp" ;;
    esac
}

other_bootname() {
    case "$1" in
        A) echo "B" ;;
        B) echo "A" ;;
    esac
}

current_bootname() {
    if grep -q "rauc.slot=A" /proc/cmdline; then
        echo "A"
    else
        echo "B"
    fi
}

# Called by rauc right after a successful install, to commit BOOTNAME (A/B)
# as the slot to try booting next - with a real automatic-rollback safety
# net this time, not just a one-way commit. bootcmd is set to BOOTNAME's
# boot commands, altbootcmd to the OTHER (current, known-good) bank's, and
# upgrade_available/bootcount are armed so U-Boot's own env-based bootcount
# mechanism automatically falls back to altbootcmd - the previous good
# bank - if BOOTNAME never reaches a good boot (get-state below) within
# bootlimit attempts (3, see the U-Boot patch).
if [ "$arg1" = "set-primary" ]
then
    bootname=$2
    case "$bootname" in
        A|B)
            other=$(other_bootname "$bootname")
            fw_setenv bootcmd "$(bootcmd_for "$bootname")"
            fw_setenv altbootcmd "$(bootcmd_for "$other")"
            fw_setenv bootlimit "$BOOTLIMIT"
            fw_setenv upgrade_available 1
            fw_setenv bootcount 0
            ;;
        *)
            echo "set-primary: unknown bootname '$bootname'" >&2
            exit 1
            ;;
    esac
    exit $?
fi

# Reports which bank is CURRENTLY running - read-only, no side effects.
# Accepting a trial bank or disarming the rollback safety net should only
# ever happen at a real health checkpoint (get-state, below), not merely
# because something queried our status.
if [ "$arg1" = "get-primary" ]
then
    current_bootname
    exit 0
fi

# Reached when st-status-mark-good.sh calls `rauc status mark-good` after
# a successful boot - the actual "this boot is confirmed good" checkpoint.
# Runs the same way regardless of whether we got here via a fresh
# set-primary commit succeeding, or via U-Boot's bootcount mechanism
# automatically falling back to the other bank after BOOTNAME failed to
# reach this point - either way, the CURRENTLY running bank is now the
# confirmed-good baseline:
#  - accept it in FWU metadata (bank_state A, ends TF-A's own independent
#    trial tracking too)
#  - resync bootcmd/altbootcmd so bootcmd always reflects the current
#    (confirmed-good) bank going forward, and altbootcmd the other
#  - disarm the bootcount safety net (upgrade_available=0, bootcount=0)
#    so a normal boot into this same bank next time doesn't unnecessarily
#    carry a stale trial count forward
if [ "$arg1" = "get-state" ]
then
    current=$(current_bootname)
    other=$(other_bootname "$current")
    if [ "$current" = "A" ]
    then
        /usr/lib/fwu/update_metadata.sh 0 0 accept > /dev/null
    else
        /usr/lib/fwu/update_metadata.sh 1 1 accept > /dev/null
    fi
    fw_setenv bootcmd "$(bootcmd_for "$current")"
    fw_setenv altbootcmd "$(bootcmd_for "$other")"
    fw_setenv upgrade_available 0
    fw_setenv bootcount 0
    echo "good"
    exit 0
fi
