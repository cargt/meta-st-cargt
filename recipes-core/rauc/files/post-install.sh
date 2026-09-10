#!/usr/bin/env python3

"""
Post script to be run by RAUC:
- after installing the images
- before reboot

Patches the newly-installed bootfs's extlinux.conf (root= device path and
rauc.slot=) and the newly-installed rootfs's mount-partitions.sh (bootfs/
vendorfs partition-label references) to point at the slot that was just
installed, then puts that slot into FWU "trial" state so TF-A/U-Boot boot
into it once, falling back to the previous slot if it doesn't reach a good
boot (see st-status-mark-good.sh / rauc-mark-good.service).
"""

import ctypes
import ctypes.util
import fileinput
import os
import re
import subprocess
import sys

# /run/cargt-part/<name>, not /dev/disk/by-partlabel/<name> - see
# system.conf's comment: eMMC and SD card both carry partitions with the
# same names, so the system-wide by-partlabel symlink is ambiguous whenever
# both are present. cargt-device-symlinks.service resolves these scoped to
# whichever device root is actually mounted from.
part_prefix = "/run/cargt-part/"
mount_partition_file = "/sbin/mount-partitions.sh"
temp_mount_dir = "/tmp"
get_next_boot_slot = {"A": "B", "B": "A"}

# userfs is not managed by the A/B mechanism
part_dico = {"boot": {"A": "bootfs-a", "B": "bootfs-b"},
             "vendorfs": {"A": "vendorfs-a", "B": "vendorfs-b"},
             "rootfs": {"A": "rootfs-a", "B": "rootfs-b"}}

boot_part_num_dico = {"A": 0, "B": 1}

# root= is a literal /dev/mmcblkNpM path (see the machine conf's
# UBOOT_EXTLINUX_ROOT comment for why PARTLABEL/PARTUUID don't work here) -
# N (which device) never changes between A and B, only M (the partition
# number) does. rootfs-a/rootfs-b are always partitions 10/11 on this
# board's layout - update both this and the machine conf if that ever
# changes on either device.
rootfs_part_num_dico = {"A": 10, "B": 11}


def mkdir(name):
    if not os.path.exists(name):
        try:
            os.mkdir(name)
        except OSError:
            print("Creation of %s the directory failed" % name)


def rmdir(name):
    if os.path.exists(name):
        try:
            os.rmdir(name)
        except OSError:
            print("Deletion of %s the directory failed" % name)


libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)


def mount(source, target, fs):
    ret = libc.mount(source.encode(), target.encode(), fs.encode(), 0, None)
    if ret < 0:
        errno = ctypes.get_errno()
        print("Error mounting %s (%s) on %s: %s" % (source, fs, target, os.strerror(errno)))


def umount(target):
    print("umount %s" % target)
    ret = libc.umount(target.encode(), None)
    if ret < 0:
        errno = ctypes.get_errno()
        print("Error umounting %s: %s" % (target, os.strerror(errno)))


def get_boot_slot():
    """Return the currently-running boot slot from the kernel cmdline (rauc.slot=A|B)."""
    with open("/proc/cmdline", "r") as cmdline:
        for line in cmdline:
            for param in line.split():
                if "rauc.slot=" in param:
                    return param.split("=")[1]
    return None


current_boot_slot = get_boot_slot()
next_boot_slot = get_next_boot_slot[current_boot_slot]

print("current_boot_slot=%s next_boot_slot=%s" % (current_boot_slot, next_boot_slot))

# Update the root= mount point and rauc.slot in the newly-installed bootfs's extlinux.conf.
dirName = "%s/boot_%s" % (temp_mount_dir, next_boot_slot)
mkdir(dirName)
mount('%s%s' % (part_prefix, part_dico["boot"][next_boot_slot]), dirName, 'ext4')

# "A" is the default configuration baked into the build.
for root, dirs, files in os.walk("%s/" % dirName):
    for file in files:
        if file.endswith("extlinux.conf"):
            print("Updating: %s" % os.path.join(root, file))
            with fileinput.FileInput(os.path.join(root, file), inplace=True, backup='.bak') as f:
                for line in f:
                    x = re.sub(r'(root=/dev/mmcblk\d+p)%d\b' % rootfs_part_num_dico["A"],
                               r'\g<1>%d' % rootfs_part_num_dico[next_boot_slot],
                               line)
                    x = x.replace("rauc.slot=A", "rauc.slot=%s" % next_boot_slot)
                    print(x, end='')

umount(dirName)
rmdir(dirName)

# Update vendorfs/bootfs partition-label references in the newly-installed rootfs.
dirName = "%s/rootfs_%s" % (temp_mount_dir, next_boot_slot)
mkdir(dirName)
mount('%s%s' % (part_prefix, part_dico["rootfs"][next_boot_slot]), dirName, 'ext4')

with fileinput.FileInput("%s/%s" % (dirName, mount_partition_file), inplace=True, backup='.bak') as f:
    for line in f:
        x = line.replace("%s,/boot" % part_dico["boot"]["A"], "%s,/boot" % part_dico["boot"][next_boot_slot])
        x = x.replace("%s,/vendor" % part_dico["vendorfs"]["A"], "%s,/vendor" % part_dico["vendorfs"][next_boot_slot])
        print(x, end='')

umount(dirName)
rmdir(dirName)

# Put the next slot into FWU trial state (bootcount enabled) - already-good
# current slot stays accepted. If the new slot doesn't reach a good boot,
# TF-A/U-Boot fall back to the current one.
# Wait for this to actually finish (and sync) before returning - RAUC
# considers the install done as soon as this script exits, and a reboot
# shortly after a fire-and-forget call here could race the metadata write
# never landing on disk.
subprocess.run(["/usr/lib/fwu/update_metadata.sh",
                 "%d" % boot_part_num_dico[next_boot_slot],
                 "%d" % boot_part_num_dico[current_boot_slot],
                 "refuse"], check=True)
