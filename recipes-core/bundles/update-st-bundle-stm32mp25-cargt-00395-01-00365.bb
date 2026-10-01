SUMMARY = "RAUC OTA update bundle for stm32mp25-cargt-00395-01-00365"

inherit bundle

# Slot image filenames below are this machine's; building it under any
# other MACHINE can only fail (or, worse, pick up stale files).
COMPATIBLE_MACHINE = "^stm32mp25-cargt-00395-01-00365$"

# Must match [system] compatible= in recipes-core/rauc/files/stm32mp25-cargt-00395-01-00365/system.conf.
RAUC_BUNDLE_COMPATIBLE = "cargt-stm32mp25-00395-01-00365"
RAUC_BUNDLE_SLOTS = "fip bootfs vendorfs rootfs"
RAUC_BUNDLE_FORMAT = "verity"

RAUC_SLOT_bootfs = "st-image-bootfs"
RAUC_SLOT_bootfs[fstype] = "ext4"
RAUC_SLOT_bootfs[type] = "image"
RAUC_SLOT_bootfs[file] = "st-image-bootfs-cargt-openstlinux-weston-stm32mp25-cargt-00395-01-00365.bootfs.ext4"

RAUC_SLOT_vendorfs = "st-image-vendorfs"
RAUC_SLOT_vendorfs[fstype] = "ext4"
RAUC_SLOT_vendorfs[type] = "image"
RAUC_SLOT_vendorfs[file] = "st-image-vendorfs-cargt-openstlinux-weston-stm32mp25-cargt-00395-01-00365.vendorfs.ext4"

RAUC_SLOT_rootfs = "cargt-image-dev"
RAUC_SLOT_rootfs[fstype] = "ext4"
RAUC_SLOT_rootfs[type] = "image"
RAUC_SLOT_rootfs[file] = "cargt-image-dev-cargt-openstlinux-weston-stm32mp25-cargt-00395-01-00365.rootfs.ext4"

RAUC_SLOT_fip = "fip-stm32mp"
RAUC_SLOT_fip[fstype] = "raw"
RAUC_SLOT_fip[type] = "boot"
RAUC_SLOT_fip[file] = "fip/fip-stm32mp257f-cargt-00395-01-00365-optee-emmc.bin"
RAUC_SLOT_fip[rename] = "fip-stm32mp257f-cargt-00395-01-00365-optee-emmc.bin"

# Development-only signing key/cert - replace both for production use.
RAUC_KEY_FILE = "${THISDIR}/files/development-1.key.pem"
RAUC_CERT_FILE = "${THISDIR}/files/development-1.cert.pem"
