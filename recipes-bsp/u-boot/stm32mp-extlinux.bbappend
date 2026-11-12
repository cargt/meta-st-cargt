# No MENU line in extlinux.conf. ST writes "MENU BACKGROUND <splash>" even for a
# single label, and any MENU line makes U-Boot's sysboot show an interactive
# menu ("Enter choice:"). One stray byte on the console during its TIMEOUT
# cancels the timeout, and U-Boot then waits for Enter forever. Without the MENU
# line, sysboot boots the default label at once. The cost is ST's U-Boot splash
# on the panel during that window; the Cargt splash comes from psplash in Linux.
UBOOT_EXTLINUX_SPLASH = ""
