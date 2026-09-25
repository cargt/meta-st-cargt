FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# The base recipe sets S = "${WORKDIR}/git" but never fetches via git://
# (only file://), so nothing creates that directory -- do_patch needs S to
# point at where the file:// fetcher actually places the sources.
S = "${WORKDIR}"

# The direct-resize2fs fallback path never fscks a filesystem before
# growing it, unlike every other first-boot resize script in this BSP --
# see the patch for the corruption this caused elsewhere.
SRC_URI += "file://0001-fsck-before-resize2fs-in-direct-resize-path.patch"

# RAUC A/B boards only: bootfs/vendorfs/rootfs are fixed-size -a/-b slots
# with no remaining space to grow into (unlike single-bank boards) - see
# the patch for why leaving this unpatched costs minutes on every OTA
# update's first boot into the newly-installed slot, not just once.
SRC_URI:append = "${@bb.utils.contains('COMBINED_FEATURES', 'rauc', ' file://0002-skip-fixed-size-ab-partitions.patch', '', d)}"

# RAUC A/B boards only: userfs is shared across both rootfs-a/rootfs-b
# slots, but this script's own "already ran" state (a disabled systemd
# unit) lives in /etc, part of rootfs - which every OTA update reflashes.
# Without this, the (now userfs-only, but still slow) fsck+resize2fs pass
# re-runs on every OTA update's first boot into the newly-installed slot,
# not just the very first boot ever. See the patch.
SRC_URI:append = "${@bb.utils.contains('COMBINED_FEATURES', 'rauc', ' file://0003-skip-userfs-resize-if-already-done.patch', '', d)}"

# Found via RAUC's SD card testing: a board whose .wks.in gives userfs a
# small fixed size (with the rest of the card intentionally left
# unpartitioned, expecting first-boot growth) needs the GPT partition
# table entry itself extended before resize2fs/systemd-growfs have
# anything to grow into - neither one ever touches the partition table.
# Guarded to only act when userfs is genuinely the last partition with
# real free space after it, so it's a safe no-op on eMMC (already sized
# to fill the disk at flash time). See the patch.
#
# Gated like 0002/0003 rather than applied unconditionally: it's written
# on top of 0003 (uses its USERFS_ALREADY_RESIZED marker and context) and
# doesn't apply to the stock script, and the only .wks.in files with a
# small fixed userfs are the A/B boards' own. A single-bank board that
# ever needs it would have to take 0003 too.
SRC_URI:append = "${@bb.utils.contains('COMBINED_FEATURES', 'rauc', ' file://0004-extend-userfs-gpt-partition-before-growing-it.patch', '', d)}"

# sgdisk/resizepart/lsblk (0004's patch) were only ever present on the
# test images incidentally, pulled in by something else - make them a
# real dependency so this doesn't silently no-op (its failure mode is
# graceful, but silent) on a leaner image that happens not to include
# them for some other reason.
RDEPENDS:${PN} += "${@bb.utils.contains('COMBINED_FEATURES', 'rauc', ' gptfdisk util-linux-resizepart util-linux-lsblk', '', d)}"

# Content now depends on the machine (COMBINED_FEATURES includes
# MACHINE_FEATURES), so this can't stay a shared tune-arch package: without
# this, an A/B board and a single-bank board built in the same tree would
# share (and overwrite) one package with the wrong content for one of them.
PACKAGE_ARCH = "${MACHINE_ARCH}"
