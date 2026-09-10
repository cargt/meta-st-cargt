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
SRC_URI:append = "${@bb.utils.contains('DISTRO_FEATURES', 'rauc', ' file://0002-skip-fixed-size-ab-partitions.patch', '', d)}"

# RAUC A/B boards only: userfs is shared across both rootfs-a/rootfs-b
# slots, but this script's own "already ran" state (a disabled systemd
# unit) lives in /etc, part of rootfs - which every OTA update reflashes.
# Without this, the (now userfs-only, but still slow) fsck+resize2fs pass
# re-runs on every OTA update's first boot into the newly-installed slot,
# not just the very first boot ever. See the patch.
SRC_URI:append = "${@bb.utils.contains('DISTRO_FEATURES', 'rauc', ' file://0003-skip-userfs-resize-if-already-done.patch', '', d)}"
