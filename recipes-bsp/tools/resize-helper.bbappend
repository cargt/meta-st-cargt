FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# The base recipe sets S = "${WORKDIR}/git" but never fetches via git://
# (only file://), so nothing creates that directory -- do_patch needs S to
# point at where the file:// fetcher actually places the sources.
S = "${WORKDIR}"

# The direct-resize2fs fallback path never fscks a filesystem before
# growing it, unlike every other first-boot resize script in this BSP --
# see the patch for the corruption this caused elsewhere.
SRC_URI += "file://0001-fsck-before-resize2fs-in-direct-resize-path.patch"
