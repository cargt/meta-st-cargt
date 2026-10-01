#!/bin/sh
# Create /run/cargt-part/<name> symlinks to the partition named <name> on
# whichever physical MMC device (eMMC vs SD card) the running root
# filesystem actually lives on.
#
# /dev/disk/by-partlabel/<name> is NOT safe to use directly for this: it's a
# system-wide symlink, and eMMC and SD card both carry partitions with the
# same names (bootfs-a, rootfs-a, metadata1, u-boot-env, ...) by design (the
# same image gets flashed to either). If both devices are present at once
# (eMMC always is; SD card is whenever inserted), by-partlabel resolves to
# whichever device udev happened to process last/first - undefined, and not
# necessarily the device we're actually running from. RAUC's system.conf,
# post-install.sh, update_metadata.sh and fw_env.config all need a path
# that's guaranteed to point at the CURRENT root's own device.
#
# This reuses the exact same device-detection and PARTNAME-scan technique
# already used by mount-partitions.sh (systemd-mount-partitions recipe,
# meta-st-openstlinux) for /boot, /vendor, /usr/local - not a new mechanism,
# just applied to the other consumers that were still using by-partlabel.

SYMLINK_DIR=/run/cargt-part

# Partition names this board actually has. Duplicating this list (rather
# than symlinking whatever PARTNAMEs happen to exist) keeps behavior
# predictable and catches a missing partition as a missing symlink instead
# of silently doing nothing.
PART_NAMES="metadata1 metadata2 fip-a fip-b u-boot-env bootfs-a bootfs-b vendorfs-a vendorfs-b rootfs-a rootfs-b userfs"

root_mmc_id() {
    root_device=$(findmnt --noheadings --output=SOURCE / 2>/dev/null | cut -d'[' -f1)
    case "$root_device" in
        /dev/mmcblk0*) echo 0 ;;
        /dev/mmcblk1*) echo 1 ;;
        /dev/mmcblk2*) echo 2 ;;
        /dev/disk/by-*)
            link=$(readlink -f "$root_device")
            case "$link" in
                */mmcblk0p*) echo 0 ;;
                */mmcblk1p*) echo 1 ;;
                */mmcblk2p*) echo 2 ;;
            esac
            ;;
    esac
}

mmc_id=$(root_mmc_id)
if [ -z "$mmc_id" ]; then
    logger "cargt-device-symlinks: could not determine root's mmc device, skipping"
    exit 0
fi

mkdir -p "$SYMLINK_DIR"
rm -f "$SYMLINK_DIR"/*

for name in $PART_NAMES; do
    device=""
    for f in /sys/block/mmcblk${mmc_id}/mmcblk${mmc_id}p*; do
        [ -r "$f/uevent" ] || continue
        partname=$(sed -n 's/^PARTNAME=//p' "$f/uevent")
        if [ "$partname" = "$name" ]; then
            device="/dev/$(basename "$f")"
            break
        fi
    done
    if [ -n "$device" ]; then
        ln -sf "$device" "$SYMLINK_DIR/$name"
    else
        logger "cargt-device-symlinks: partition '$name' not found on mmc${mmc_id}"
    fi
done
