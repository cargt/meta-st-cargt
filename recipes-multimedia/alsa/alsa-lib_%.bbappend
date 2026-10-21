# meta-st-stm32mp makes alsa-lib MACHINE_ARCH, but its patches (card configs
# for ST eval/discovery boards) are applied for every stm32mpcommon machine,
# so the package is identical on all of our boards. Keep it in the CPU-tune
# feed, otherwise everything linking alsa (pulseaudio, pipewire, gstreamer,
# ffmpeg, ...) becomes board-specific too.
PACKAGE_ARCH:stm32mpcommon = "${TUNE_PKGARCH}"

# Changes feed in this release; see the PR note in conf/layer.conf.
PR = "r1"
