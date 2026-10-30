#!/bin/sh
#
# RAUC slot "install" hook for the fip slot (see update-st-bundle-cargt-fip.inc).
#
# The bundle's fip slot image is the board-wide FIP; the per-panel FIPs
# (one per -glt* entry in the machine's STM32MP_DT_FILES_EMMC) ride along
# as extra files under fip/ in the bundle. This hook replaces RAUC's own
# raw write for the slot and writes whichever FIP matches the running
# board, so a board flashed with a per-panel FlashLayout keeps its panel
# devicetree across an update instead of reverting to the board-wide one.
#
# The running variant comes from /proc/device-tree/compatible entry 0:
# every Cargt per-panel DT has "cargt,<dtb basename>" there (U-Boot
# derives fdtfile=<dtb basename>.dtb from the same string), which maps to
# fip/fip-<dtb basename>-optee-emmc.bin. Anything else - an "st," name, a
# variant with no FIP in the bundle, an unreadable compatible - falls back
# to the board-wide slot image. Output goes to RAUC's log.
#
# CARGT_DT_COMPATIBLE_FILE overrides the compatible path, for testing only.

set -u

log() {
    echo "fip-install-hook: $*"
}

select_fip() {
    compat_file="${CARGT_DT_COMPATIBLE_FILE:-/proc/device-tree/compatible}"
    compat=""
    if [ -r "$compat_file" ]; then
        compat=$(tr '\0' '\n' < "$compat_file" | head -n 1)
    fi

    case "$compat" in
    cargt,*)
        variant=${compat#cargt,}
        ;;
    *)
        log "compatible[0] '$compat' is not a cargt,<dtb> name, using board-wide FIP" >&2
        echo "$RAUC_IMAGE_NAME"
        return
        ;;
    esac

    # The name ends up in a path below, so only allow what a dtb basename
    # can contain.
    case "$variant" in
    "" | *[!A-Za-z0-9._-]* | .*)
        log "compatible[0] '$compat' has an unexpected name, using board-wide FIP" >&2
        echo "$RAUC_IMAGE_NAME"
        return
        ;;
    esac

    candidate="$RAUC_BUNDLE_MOUNT_POINT/fip/fip-$variant-optee-emmc.bin"
    if [ -f "$candidate" ]; then
        echo "$candidate"
    else
        log "no per-panel FIP for '$variant' in bundle, using board-wide FIP" >&2
        echo "$RAUC_IMAGE_NAME"
    fi
}

slot_install() {
    fip=$(select_fip)
    log "writing $(basename "$fip") to $RAUC_SLOT_DEVICE (slot $RAUC_SLOT_NAME)"

    if [ -b "$RAUC_SLOT_DEVICE" ] && command -v blockdev > /dev/null; then
        fip_size=$(wc -c < "$fip")
        dev_size=$(blockdev --getsize64 "$RAUC_SLOT_DEVICE")
        if [ "$fip_size" -gt "$dev_size" ]; then
            log "$fip ($fip_size bytes) does not fit $RAUC_SLOT_DEVICE ($dev_size bytes)"
            exit 1
        fi
    fi

    if ! dd if="$fip" of="$RAUC_SLOT_DEVICE" bs=64k conv=fsync 2>&1; then
        log "writing $fip to $RAUC_SLOT_DEVICE failed"
        exit 1
    fi
}

case "${1:-}" in
slot-install)
    if [ "${RAUC_SLOT_CLASS:-}" != "fip" ]; then
        log "unexpected slot class '${RAUC_SLOT_CLASS:-}'"
        exit 1
    fi
    slot_install
    ;;
*)
    log "unsupported hook '${1:-}'"
    exit 1
    ;;
esac
