# Patches the auto-generated eMMC flashlayout TSVs (fastboot and optee
# bootschemes, main CUBEMX_DTB variant only - it supports all displays, so
# the per-panel -glt* variant TSVs are intentionally left untouched/single-
# bank) to duplicate bootfs/vendorfs/rootfs into A/B slots for RAUC OTA
# updates.
#
# ST's flashlayout-stm32mp.bbclass has no built-in concept of A/B
# duplication for PARTITIONS_IMAGES-driven partitions (unlike fip-a/fip-b,
# which it handles natively via ENABLE_FLASHLAYOUT_CONFIG_FWUP) - each
# PARTITIONS_IMAGES entry must map to exactly one real image recipe, so
# there's no way to express "two labels, one already-built image" or "an
# empty reserved slot" at that level. Splicing the already-correctly-
# resolved rows after the fact (rather than hand-authoring a static
# replacement TSV) keeps this working automatically across any upstream
# offset/filename changes.
#
# "-b" starts as an empty reserved partition (Opt=PED, Binary=none),
# matching how fip-b is already handled - populated by the first
# `rauc install`.

python do_create_flashlayout_config:append () {
    # NOTE: no "import os" here - bitbake concatenates :append python code
    # into the SAME function body as the original task, sharing local scope.
    # Importing os locally here would shadow the module-global "os" the
    # original (unappended) body above already relies on without importing
    # it itself, breaking its earlier os.path.join() calls with
    # UnboundLocalError.
    if not bb.utils.contains('DISTRO_FEATURES', 'rauc', True, False, d):
        return

    # Patch the WORKDIR staging tree, not DEPLOY_DIR_IMAGE - this task is
    # declared with [sstate-outputdirs] pointing FLASHLAYOUT_DESTDIR at
    # FLASHLAYOUT_DEPLOYDIR, and bitbake's sstate machinery only copies
    # staging -> deploy *after* this whole python function (base body +
    # this appended block) returns, so DEPLOY_DIR_IMAGE doesn't have
    # today's files yet at this point.
    deploydir = d.getVar('FLASHLAYOUT_DESTDIR')
    dtb = d.getVar('CUBEMX_DTB')

    for bootscheme in ('fastboot', 'optee'):
        tsv_path = os.path.join(deploydir, bootscheme, 'FlashLayout_emmc_%s-%s.tsv' % (dtb, bootscheme))
        if not os.path.exists(tsv_path):
            bb.warn('RAUC A/B flashlayout patch: %s not found, skipping' % tsv_path)
            continue
        rauc_ab_patch_flashlayout_tsv(tsv_path)
}

def rauc_ab_patch_flashlayout_tsv(tsv_path):
    with open(tsv_path, 'r') as f:
        lines = [l.rstrip('\n') for l in f.readlines() if l.strip()]

    header = lines[0]
    rows = [l.split('\t') for l in lines[1:]]

    names = ('bootfs', 'vendorfs', 'rootfs', 'userfs')
    idx = {}
    for i, row in enumerate(rows):
        if row[2] in names:
            idx[row[2]] = i

    if not all(n in idx for n in names):
        bb.warn('RAUC A/B flashlayout patch: %s missing one of bootfs/vendorfs/rootfs/userfs, skipping (already patched?)' % tsv_path)
        return

    bootfs_off = int(rows[idx['bootfs']][5], 16)
    vendorfs_off = int(rows[idx['vendorfs']][5], 16)
    rootfs_off = int(rows[idx['rootfs']][5], 16)
    userfs_off = int(rows[idx['userfs']][5], 16)

    bootfs_size = vendorfs_off - bootfs_off
    vendorfs_size = rootfs_off - vendorfs_off
    rootfs_size = userfs_off - rootfs_off

    ab_specs = [
        ('bootfs', rows[idx['bootfs']], bootfs_size, 0x10),
        ('vendorfs', rows[idx['vendorfs']], vendorfs_size, 0x12),
        ('rootfs', rows[idx['rootfs']], rootfs_size, 0x14),
    ]

    new_rows = []
    offset = bootfs_off
    for name, row, size, base_id in ab_specs:
        opt, pid, _, ptype, ip, _, binary = row
        # "-a": populated at first flash, same content as today.
        new_rows.append([opt, '0x%02X' % base_id, '%s-a' % name, ptype, ip,
                          '0x%08X' % offset, binary])
        offset += size
        # "-b": reserved-empty until the first OTA install.
        new_rows.append(['PED', '0x%02X' % (base_id + 1), '%s-b' % name, ptype, ip,
                          '0x%08X' % offset, 'none'])
        offset += size

    # userfs keeps its own Opt/Type/Binary, just moves to the new offset.
    opt, pid, name, ptype, ip, _, binary = rows[idx['userfs']]
    new_rows.append([opt, '0x16', name, ptype, ip, '0x%08X' % offset, binary])

    out_rows = rows[:idx['bootfs']] + new_rows + rows[idx['userfs'] + 1:]

    with open(tsv_path, 'w') as f:
        f.write(header + '\n')
        for row in out_rows:
            f.write('\t'.join(row) + '\n')

    bb.note('RAUC A/B flashlayout patch: wrote %s' % tsv_path)
