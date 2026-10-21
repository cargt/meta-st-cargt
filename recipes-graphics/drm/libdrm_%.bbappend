# meta-st-stm32mp makes libdrm MACHINE_ARCH, but its PACKAGECONFIG and patches
# are the same for every stm32mpcommon machine. Keep it in the CPU-tune feed so
# weston, gtk, cairo, gstreamer, ... stay shared between boards.
PACKAGE_ARCH:stm32mpcommon = "${TUNE_PKGARCH}"
