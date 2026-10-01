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
boot (see st-boot-script.sh set-state / rauc-mark-good.service).

RAUC runs this AFTER st-boot-script.sh set-primary has already pointed
U-Boot's bootcmd at the new slot.

Also stops the weston graphical session before returning. rauc-hawkbit-
updater's post_update_reboot calls the raw reboot(2) syscall directly
(it holds CAP_SYS_BOOT for exactly this) rather than going through
systemd, so weston is normally still alive and submitting GPU commands
when the kernel's device_shutdown() tears down the GPU driver during
kernel_restart() - confirmed via dmesg to oops the out-of-tree galcore
driver's .shutdown() hook, then oops weston itself a moment later with a
NULL pointer dereference in gckCOMMAND_Commit, leaving kernel_restart()
never actually completing. Stopping weston here, before this script
returns and control passes back to whatever triggered the reboot, avoids
the race entirely regardless of which caller (rauc-hawkbit-updater's
direct reboot(2), or a manual `reboot`/`systemctl reboot` after a scp'd
install) ends up invoking it.
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

# "A" is the default configuration baked into the build - the bundle's
# bootfs image content is always A-flavored regardless of which slot it's
# being installed into. eMMC and SD card don't share partition numbering
# (the SD card's extra fsbla1/fsbla2 partitions shift rootfs-a from p10 to
# p12 there - see the machine conf's UBOOT_EXTLINUX_ROOT comment), so
# rather than hardcode a device-specific pair of numbers, discover
# whatever number is actually baked into this device's "A" config and
# derive "B" as the very next partition (always true by construction: the
# .wks.in/flashlayout always place rootfs-b immediately after rootfs-a on
# both devices). No change is needed when next_boot_slot is "A" - the
# bundle's content already matches, since it's always the A default.
def _next_rootfs_partnum(match):
    prefix, num = match.group(1), int(match.group(2))
    if next_boot_slot == "B":
        num += 1
    return "%s%d" % (prefix, num)


for root, dirs, files in os.walk("%s/" % dirName):
    for file in files:
        if file.endswith("extlinux.conf"):
            print("Updating: %s" % os.path.join(root, file))
            with fileinput.FileInput(os.path.join(root, file), inplace=True, backup='.bak') as f:
                for line in f:
                    x = re.sub(r'(root=/dev/mmcblk\d+p)(\d+)\b', _next_rootfs_partnum, line)
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

# Also arm U-Boot's own env-based bootcount safety net (upgrade_available/
# bootcmd/altbootcmd/bootlimit) via the backend's set-primary action.
#
# RAUC 1.15 itself already calls set-primary for the new slot during
# install (install.c: r_mark_active() -> custom backend "set-primary",
# right after "Marking target slot ... as bootable", before this handler
# runs), so this is normally a redundant, idempotent second write of the
# same values. It was added after two installs left the board on the old
# slot with upgrade_available=0; the likelier cause of that was the old
# backend's get-state, which reset bootcmd/upgrade_available to the running
# slot on ANY slot-status query (rauc status, D-Bus GetSlotStatus e.g. from
# rauc-hawkbit-updater) between install and reboot - fixed by making
# get-state read-only. Kept as a belt-and-braces guarantee that the trial
# is armed when this handler returns.
subprocess.run(["/usr/lib/rauc/st-boot-script.sh", "set-primary", next_boot_slot], check=True)

# Stop weston now, synchronously, so it's already gone by the time
# whatever triggered this install (rauc-hawkbit-updater's post_update_reboot,
# or a manual `reboot` after a scp'd install) actually reboots the board -
# see the module docstring. Not check=True: images without a weston
# graphical session (or where it's already stopped) shouldn't fail the
# install over this - `systemctl stop` on a unit that isn't loaded just
# exits non-zero, it's not a sign anything is actually wrong.
result = subprocess.run(["systemctl", "stop", "weston-graphical-session.service"])
print("stop weston-graphical-session.service: exit %d" % result.returncode)
