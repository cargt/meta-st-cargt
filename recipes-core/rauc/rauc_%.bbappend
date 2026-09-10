FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# RAUC doesn't recognize ".bin" as a valid "raw" slot image by default,
# causing "Unsupported image ... for slot type raw" on install - our fip
# slot image is fip-stm32mp257f-cargt-00395-02-00365-optee-emmc.bin.
SRC_URI:append = " file://0001-support-bin-extension.patch "
