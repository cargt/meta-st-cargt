FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# Upstream's rootfs resize path skips e2fsck before resize2fs, unlike the
# other three filesystems it resizes on first boot -- growing an unverified
# ext4 filesystem produced severe metadata corruption on affected units.
# See the patch for details.
SRC_URI += "file://0001-resize-fsck-rootfs-before-growing-it.patch"

# Not RAUC-specific - affects any board's userfs on a genuinely fresh
# image's first boot. A single e2fsck pass that actually fixes something
# leaves resize2fs unwilling to grow the filesystem; see the patch.
SRC_URI += "file://0003-fsck-userfs-twice-before-resizing.patch"

# RAUC A/B boards only: bootfs/vendorfs/rootfs are fixed-size -a/-b slots
# with no remaining space to grow into (unlike single-bank boards, where
# they legitimately grow to fill whatever's left on the eMMC/SD card) - see
# the patch for why leaving this unpatched costs minutes on every OTA
# update's first boot into the newly-installed slot, not just once.
#
# The same "first boot into a newly-installed slot" problem also applies
# to userfs itself: it's shared (not A/B duplicated), but this script's
# own re-run guard lives inside whichever rootfs is currently booting, so
# a fresh OTA-installed bank retriggers userfs's full e2fsck -c bad-blocks
# scan too, even though userfs was already grown once, long before that
# bank existed - see the patch (confirmed on hardware: this scan
# outlasted OP-TEE's own watchdog and reset the board mid-scan, repeatedly,
# with no journal/pstore trace since it happens before Linux userspace
# ever starts).
SRC_URI:append = "${@bb.utils.contains('DISTRO_FEATURES', 'rauc', ' file://0002-skip-first-boot-resize-for-fixed-size-ab-partitions.patch file://0004-skip-userfs-resize-if-already-done.patch', '', d)}"
