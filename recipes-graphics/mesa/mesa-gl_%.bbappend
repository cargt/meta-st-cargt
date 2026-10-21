# meta-st-stm32mp makes mesa-gl MACHINE_ARCH, but its only change (dropping the
# KHR headers, which gcnano-userland provides) is the same for every
# stm32mpcommon machine. Keep it in the CPU-tune feed.
PACKAGE_ARCH:stm32mpcommon = "${TUNE_PKGARCH}"
