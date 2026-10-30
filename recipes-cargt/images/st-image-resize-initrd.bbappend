# Start the Cargt boot splash from the initramfs on the 00365 machines,
# where the DSI display is built into the kernel (see
# cargt_00365_kernel_config_mods.config), so the panel shows it about
# 5 s into boot rather than once systemd gets to it.
PACKAGE_INSTALL:append = "${@bb.utils.contains('MACHINE_FEATURES', '00365', ' initramfs-module-cargt-splash', '', d)}"
