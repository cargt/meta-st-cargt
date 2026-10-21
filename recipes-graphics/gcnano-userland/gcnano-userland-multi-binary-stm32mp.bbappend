# The GPU userland binaries are selected per SoC family (GCNANO_MACHINE =
# stm32mp2), not per board, so all stm32mp2 boards get the same package.
# Keep it in the CPU-tune feed so every GL/EGL user stays shared between boards.
PACKAGE_ARCH = "${TUNE_PKGARCH}"

# MACHINE is only read by the EULA check in do_unpack (to look up
# ACCEPT_EULA_<machine>); it does not affect the unpacked binaries. The check
# still runs on every build - this only keeps MACHINE out of the task signature.
do_unpack[vardepsexclude] += "MACHINE"

# Changes feed in this release; see the PR note in conf/layer.conf.
PR = "r1"
