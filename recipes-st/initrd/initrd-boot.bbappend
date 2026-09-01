FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# Upstream's rootfs resize path skips e2fsck before resize2fs, unlike the
# other three filesystems it resizes on first boot -- growing an unverified
# ext4 filesystem produced severe metadata corruption on affected units.
# See the patch for details.
SRC_URI += "file://0001-resize-fsck-rootfs-before-growing-it.patch"
