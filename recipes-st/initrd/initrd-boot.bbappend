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
#
# 0004's marker WRITE (not its check, which is correct and stays) turned
# out to be actively harmful on the SD card build: this script always
# runs before resize-helper.service, so it was permanently winning the
# race to mark userfs "done" - via a resize2fs call that can't actually
# grow a fixed-size GPT partition on SD card - before resize-helper.service
# (the only script with the tools to fix that) ever got a chance to. See
# 0005.
SRC_URI:append = "${@bb.utils.contains('COMBINED_FEATURES', 'rauc', ' file://0002-skip-first-boot-resize-for-fixed-size-ab-partitions.patch file://0004-skip-userfs-resize-if-already-done.patch file://0005-dont-mark-userfs-resized-from-the-initrd.patch', '', d)}"

# Content now depends on the machine (COMBINED_FEATURES includes
# MACHINE_FEATURES), so this can't stay a shared allarch package: without
# this, an A/B board and a single-bank board built in the same tree would
# share (and overwrite) one package with the wrong content for one of them.
#
# A plain PACKAGE_ARCH assignment (or override) doesn't work here:
# allarch.bbclass force-sets PACKAGE_ARCH = "all" from a RecipePreFinalise
# event handler, and setVar() there also drops active overrides. A second
# handler registered here runs after allarch's, and allarch's own
# anonymous python then leaves the recipe alone since PACKAGE_ARCH is no
# longer "all" ("Allow this class to be included but overridden").
# Nothing is compiled, so keep allarch's no-toolchain behavior by hand.
python cargt_initrd_boot_machine_arch () {
    d.setVar("PACKAGE_ARCH", "${MACHINE_ARCH}")
}
addhandler cargt_initrd_boot_machine_arch
cargt_initrd_boot_machine_arch[eventmask] = "bb.event.RecipePreFinalise"
INHIBIT_DEFAULT_DEPS = "1"
