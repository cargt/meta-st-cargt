FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# rauc-native builds the bundle and, since RAUC 1.15, parses the manifest
# at bundle time - it rejects the fip "*.bin" image the same way the
# target does unless it carries the same extension mapping.
SRC_URI:append = " file://0001-support-bin-extension.patch "
