# Ship every eMMC FIP variant in the bundle and let a slot install hook
# write the one matching the running board's panel variant.
#
# The fip slot image (RAUC_SLOT_fip[file], set by the including recipe)
# stays the board-wide FIP and is the hook's fallback. Every other entry
# in the machine's STM32MP_DT_FILES_EMMC (the per-panel -glt* DTs) adds
# fip/fip-<dt>-optee-emmc.bin to the bundle; fip-install-hook.sh picks
# one from /proc/device-tree/compatible[0] at install time. The extra
# FIPs come from the same fip-stm32mp deploy the slot image already
# depends on.

SRC_URI += "file://fip-install-hook.sh"
# A recipe that fetches files must name its license file (bundle.bbclass
# already defaults LICENSE to MIT).
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

RAUC_BUNDLE_HOOKS[file] = "fip-install-hook.sh"
RAUC_SLOT_fip[hooks] = "install"

# STM32MP_DT_FILES_EMMC minus CUBEMX_DTB (the board-wide DT, whose FIP is
# already the slot image).
def cargt_bundle_panel_fips(d):
    board_dt = d.getVar('CUBEMX_DTB')
    panel_dts = [dt for dt in (d.getVar('STM32MP_DT_FILES_EMMC') or '').split()
                 if dt != board_dt]
    return ' '.join('fip/fip-%s-optee-emmc.bin' % dt for dt in panel_dts)

CARGT_BUNDLE_PANEL_FIPS = "${@cargt_bundle_panel_fips(d)}"
RAUC_BUNDLE_EXTRA_FILES += "${CARGT_BUNDLE_PANEL_FIPS}"
