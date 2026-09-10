# RAUC A/B boards only: suffix bootfs/vendorfs/rootfs partition labels with
# "-a" in the initial (first-flash) build's mount-partitions.sh, matching
# the A/B slot naming added for RAUC OTA updates - userfs stays unsuffixed
# (not A/B managed). "rauc" is a distro-wide feature (see the distro conf
# commit), but this recipe is shared by every board built against
# meta-st-cargt, RAUC or not - gate the "-a" suffixing on it, falling back
# to upstream's own unsuffixed behavior otherwise, so non-RAUC boards
# aren't left looking for partition labels that don't exist on their media.
python set_partitions_list() {
    partitionsconfig = (d.getVar('PARTITIONS_IMAGES') or "").split()
    rauc = bb.utils.contains('DISTRO_FEATURES', 'rauc', True, False, d)

    if len(partitionsconfig) > 0:
        partitionsconfigflags = d.getVarFlags('PARTITIONS_IMAGES')
        # The "doc" varflag is special, we don't want to see it here
        partitionsconfigflags.pop('doc', None)

        for config in partitionsconfig:
            for f, v in partitionsconfigflags.items():
                if config == f:
                    items = v.split(',')
                    # Make sure a mount point is available
                    if len(items) > 2 and items[1] and items[2]:
                        if not rauc or items[1] == '${STM32MP_USERFS_LABEL}':
                            bb.debug(1, "Appending '%s,%s' to MOUNT_PARTITIONS_LIST." % (items[1], items[2]))
                            d.appendVar('MOUNT_PARTITIONS_LIST', ' ' + items[1] + ',' + items[2])
                        else:
                            bb.debug(1, "Appending '%s-a,%s' to MOUNT_PARTITIONS_LIST." % (items[1], items[2]))
                            d.appendVar('MOUNT_PARTITIONS_LIST', ' ' + items[1] + '-a' + ',' + items[2])
                    break
}
