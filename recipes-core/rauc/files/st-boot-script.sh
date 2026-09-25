#!/bin/bash
# RAUC "custom" bootloader backend for the TF-A FWU metadata A/B scheme,
# backed by U-Boot's env-based bootcount mechanism for automatic rollback
# safety (see 0007-enable-bootcount-env-for-ab-rollback-safety.patch).
#
# RAUC 1.15 calls this as (src/bootloaders/custom.c):
#   get-primary                 -> print the bootname U-Boot will boot next
#   set-primary BOOTNAME        -> make BOOTNAME the bank to boot next
#   get-state BOOTNAME          -> print "good" or "bad"
#   set-state BOOTNAME good|bad -> record BOOTNAME's state
#
# Who calls what:
#   rauc install      : set-state <target> bad (before writing), then
#                       set-primary <target> (after writing, before the
#                       post-install handler runs)
#   rauc status       : get-primary, get-state A, get-state B (read-only)
#   rauc status mark-good (rauc-mark-good.service, after
#   boot-complete.target) : set-state <booted> good
#   rauc status mark-bad [booted|other] : set-state <slot> bad
#
# get-primary/get-state MUST stay free of side effects: any status query
# (rauc status, D-Bus GetSlotStatus from an update agent, and even the
# status fetch `rauc status mark-good` itself does before marking) runs
# them. Accepting a trial bank happens only in set-state ... good.
#
# Env variables owned by this script (all in U-Boot's env):
#   bootcmd / altbootcmd     : boot commands for the primary / fallback bank
#   upgrade_available        : 1 while a trial is armed (bootcount active)
#   bootcount / bootlimit    : U-Boot bootcount_env counters
#   rauc_bad                 : space-separated bootnames marked bad
#
# Every state change is written as ONE fw_setenv script (libubootenv
# writes the whole redundant env copy once), so a power loss mid-update
# can't leave e.g. bootcmd pointing at the new bank with altbootcmd stale.

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

PART_PREFIX=/run/cargt-part
UPDATE_METADATA=/usr/lib/fwu/update_metadata.sh

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

metadata_index() {
    case "$1" in
        A) echo 0 ;;
        B) echo 1 ;;
    esac
}

valid_bootname() {
    case "$1" in
        A|B) return 0 ;;
        *) return 1 ;;
    esac
}

current_bootname() {
    local param
    for param in $(cat /proc/cmdline); do
        case "$param" in
            rauc.slot=*) echo "${param#rauc.slot=}"; return ;;
        esac
    done
}

getenv() {
    fw_printenv -n "$1" 2>/dev/null
}

# Bank named by the persisted bootcmd ("Boot A"/"Boot B"), i.e. the bank
# U-Boot tries first. Falls back to the running bank for an env that
# predates set-primary ever running (stock "run bootcmd_stm32mp" etc.).
bootcmd_bootname() {
    case "$(getenv bootcmd)" in
        *"Boot A"*) echo "A" ;;
        *"Boot B"*) echo "B" ;;
        *) current_bootname ;;
    esac
}

# True once U-Boot has given up on bootcmd's bank and is running altbootcmd
# (bootcount_env only counts - and only compares against bootlimit - while
# upgrade_available=1).
trial_exhausted() {
    local count limit
    [ "$(getenv upgrade_available)" = "1" ] || return 1
    count=$(getenv bootcount)
    limit=$(getenv bootlimit)
    [ -n "$limit" ] || limit=$BOOTLIMIT
    [ "${count:-0}" -gt "$limit" ] 2>/dev/null
}

is_marked_bad() {
    case " $(getenv rauc_bad) " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# rauc_bad value with $1 added (add) or removed (del).
bad_list() {
    local op=$1 name=$2 out="" b
    for b in $(getenv rauc_bad); do
        [ "$b" = "$name" ] || out="$out $b"
    done
    [ "$op" = "add" ] && out="$out $name"
    echo $out
}

# Apply "name=value" lines from stdin as one env write (empty value deletes).
setenv_atomic() {
    fw_setenv --script -
}

# Refuse to hand the board to a bank with nothing installed in it (e.g. the
# still-empty -b bank of a freshly flashed board): check for an ext4
# superblock magic (0xEF53 at byte 1080) on its rootfs.
bank_has_rootfs() {
    local dev magic
    dev="$PART_PREFIX/rootfs-$(echo "$1" | tr 'AB' 'ab')"
    magic=$(dd if="$dev" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$magic" = "53ef" ]
}

# Make $1 the confirmed-good baseline: accept it in FWU metadata (both
# indexes equal ends TF-A's own trial tracking), point bootcmd at it and
# altbootcmd at the other bank, disarm the bootcount safety net. $2 is the
# rauc_bad value to store alongside.
commit_baseline() {
    local bank=$1 bad=$2 other idx
    other=$(other_bootname "$bank")
    idx=$(metadata_index "$bank")
    "$UPDATE_METADATA" "$idx" "$idx" accept > /dev/null || return 1
    setenv_atomic <<EOF
bootcmd=$(bootcmd_for "$bank")
altbootcmd=$(bootcmd_for "$other")
upgrade_available=0
bootcount=0
rauc_bad=$bad
EOF
}

cmd=$1
current=$(current_bootname)
if ! valid_bootname "$current"; then
    echo "cannot determine booted bank (no rauc.slot=A|B on /proc/cmdline)" >&2
    exit 1
fi

case "$cmd" in
get-primary)
    # The bank the next boot will actually land on: bootcmd's bank, unless
    # U-Boot already exhausted its trial and is running altbootcmd.
    primary=$(bootcmd_bootname)
    if trial_exhausted; then
        primary=$(other_bootname "$primary")
    fi
    echo "$primary"
    ;;

get-state)
    bank=$2
    valid_bootname "$bank" || { echo "get-state: unknown bootname '$bank'" >&2; exit 1; }
    if is_marked_bad "$bank"; then
        echo "bad"
    elif [ "$bank" != "$current" ] && [ "$bank" = "$(bootcmd_bootname)" ] && trial_exhausted; then
        # bootcmd's bank failed bootlimit times and we're on the fallback,
        # but mark-good hasn't run yet to record that permanently.
        echo "bad"
    else
        echo "good"
    fi
    ;;

set-primary)
    # Called by rauc right after writing BOOTNAME. Arms a real trial when
    # BOOTNAME isn't the running bank: bootcmd -> BOOTNAME, altbootcmd ->
    # the current (known-good) bank, bootcount armed, so U-Boot falls back
    # automatically if BOOTNAME never reaches set-state ... good within
    # bootlimit attempts. (TF-A's own trial state is armed separately, by
    # post-install.sh, which rauc runs after this.)
    bank=$2
    valid_bootname "$bank" || { echo "set-primary: unknown bootname '$bank'" >&2; exit 1; }
    other=$(other_bootname "$bank")
    if [ "$bank" = "$current" ]; then
        trial=0
    else
        trial=1
    fi
    setenv_atomic <<EOF
bootcmd=$(bootcmd_for "$bank")
altbootcmd=$(bootcmd_for "$other")
bootlimit=$BOOTLIMIT
upgrade_available=$trial
bootcount=0
rauc_bad=$(bad_list del "$bank")
EOF
    ;;

set-state)
    bank=$2
    state=$3
    valid_bootname "$bank" || { echo "set-state: unknown bootname '$bank'" >&2; exit 1; }
    case "$state" in
    good)
        if [ "$bank" = "$current" ]; then
            # The real health checkpoint (rauc-mark-good.service). Same
            # handling whether we got here because a fresh install booted
            # fine, or because U-Boot already fell back to this bank after
            # the other one failed - in the latter case, record the failed
            # bank as bad before the trial counters that prove it are reset.
            bad=$(bad_list del "$bank")
            if [ "$(getenv upgrade_available)" = "1" ] && [ "$(bootcmd_bootname)" != "$current" ]; then
                if ! trial_exhausted; then
                    # An install into the other bank is pending and hasn't
                    # been booted yet (mark-good run by hand before the
                    # reboot) - don't cancel it.
                    echo "rauc_bad=$bad" | setenv_atomic
                    exit $?
                fi
                failed=$(other_bootname "$current")
                case " $bad " in
                    *" $failed "*) ;;
                    *) bad="$bad $failed" ;;
                esac
                echo "bank $failed failed its trial boot, staying on $current" >&2
            fi
            commit_baseline "$current" "$(echo $bad)"
        else
            # Only clears a bad mark; making it boot is set-primary's job.
            echo "rauc_bad=$(bad_list del "$bank")" | setenv_atomic
        fi
        ;;
    bad)
        other=$(other_bootname "$bank")
        if [ "$bank" = "$current" ]; then
            # mark-bad on the running bank: switch to the other bank
            # (accepted, no trial - it's the known alternative, and there's
            # nothing to fall back to anyway).
            if is_marked_bad "$other" || ! bank_has_rootfs "$other"; then
                echo "set-state: refusing to mark $bank bad, bank $other is not bootable" >&2
                exit 1
            fi
            commit_baseline "$other" "$(bad_list add "$bank")" || exit 1
            # commit_baseline points bootcmd at $other; nothing else to do.
        else
            # Inactive bank: rauc install does this to its target before
            # overwriting it. If that bank was pending as primary (an
            # earlier install not yet rebooted into), cancel it so a
            # half-written bank can never be booted; set-primary re-arms it
            # once the new write completes.
            commit_baseline "$current" "$(bad_list add "$bank")"
        fi
        ;;
    *)
        echo "set-state: unknown state '$state'" >&2
        exit 1
        ;;
    esac
    ;;

*)
    echo "usage: $0 get-primary | set-primary A|B | get-state A|B | set-state A|B good|bad" >&2
    exit 1
    ;;
esac
