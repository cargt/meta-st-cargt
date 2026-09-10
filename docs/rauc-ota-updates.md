# RAUC A/B OTA Updates — STM32MP2 (00395-02-00365)

> **Status: draft.** This describes the RAUC-based remote update mechanism
> added to `meta-st-cargt` / `meta-cargt-stm32mp-addons` for machine
> `stm32mp25-cargt-00395-02-00365`. It's being written up for
> dev.cargt.com; a companion doc for the i.MX/SWUpdate side is planned once
> that work happens. eMMC A/B updates and SD card boot are both now
> verified working; RAUC-over-SD-card and the rollback-safety fix are
> still open — see "Testing status" at the end before treating any
> specific claim as fully validated in production.

## 1. Overview

For NXP-based boards in this org, remote firmware updates go through
SWUpdate: a single-bank, in-place rootfs overwrite. STM32MP2 boards use
**RAUC** instead, with a **dual-bank (A/B) atomic-swap** model: every
updatable partition exists as two copies (`bootfs-a`/`bootfs-b`,
`vendorfs-a`/`vendorfs-b`, `rootfs-a`/`rootfs-b`, `fip-a`/`fip-b`). An
update is written entirely to the *inactive* copy while the device keeps
running normally from the active one; only on the next reboot does the
device switch over — which is real, verified protection against a
partial/interrupted *write* (a copy that only ever half-installs can't
end up selected as primary).

**Important caveat, confirmed by testing (§2.5): automatic fallback if
the new copy fails to *boot* is not yet implemented.** The A/B swap
itself is solid — install, reboot, and slot-selection have all been
exercised heavily and work reliably — but if a newly-installed bank fails
to boot at all (bad kernel, corrupted bootfs, a crash before reaching a
health checkpoint), nothing today automatically reverts to the previous
good bank. That gap is real and documented, not a hypothetical edge case
— see §2.5 before describing this system as fully self-healing.

## 2. Theory of Operation

### 2.1 Partition layout

```
| TF-A(2) | Metadata(2) | fip-a | fip-b | u-boot-env | bootfs-a | bootfs-b | vendorfs-a | vendorfs-b | rootfs-a | rootfs-b | userfs |
```

- **fip-a / fip-b** — the FIP (Firmware Image Package: BL31 + U-Boot +
  U-Boot DTB) for each bank. RAUC-managed, `raw` slot type.
- **metadata1 / metadata2** — TF-A FWU metadata (redundant pair). Records
  which bank is active/previous and each bank's accept/trial state. Not a
  RAUC slot; written directly by `update_metadata.sh` (§2.3).
- **bootfs-a / bootfs-b** — kernel Image + DTB + `extlinux.conf`, one per
  bank. ext4, RAUC-managed.
- **vendorfs-a / vendorfs-b** — vendor partition, one per bank. ext4,
  RAUC-managed.
- **rootfs-a / rootfs-b** — the root filesystem, one per bank. ext4,
  RAUC-managed. This is what most of a bundle's size actually is.
- **userfs** — a single partition, **not** duplicated. Shared, persistent
  application/user data that survives every OTA update untouched (grown to
  fill remaining eMMC/SD space on first boot — see §3.6).
- **u-boot-env** — U-Boot's environment, single partition, not RAUC-managed.

The `-b` slot of each A/B partition starts **empty** at first flash/build;
it's populated by the very first `rauc install`.

Defined in `meta-cargt-stm32mp-addons/wic/sdcard-stm32mp257f-cargt-00395-02-00365-optee-vendorfs-2GB.wks.in`
(SD card `.wks.in`; ST's `flashlayout-stm32mp.bbclass` auto-generates the
matching eMMC-production FlashLayout TSV from the same partition set, so
both flashing paths — wic for SD card, `production_program_service.py` for
eMMC — stay in sync automatically from this one file).

### 2.2 Boot flow and bank selection

1. **TF-A BL2** reads `metadata1`/`metadata2` (stock upstream FWU logic,
   no patch needed) and boots into the selected bank's `fip-a`/`fip-b` →
   U-Boot.
2. **U-Boot** runs `bootcmd`. In this platform version, TF-A's bank choice
   is **not** automatically propagated into U-Boot's own partition
   selection — the `altboot`/`altbootcmd` mechanism exists in the
   defconfig (added by
   `0006-stm32mpu-update-env-to-support-boot-A-B.patch`) but nothing
   deterministically threads a TF-A-selected index into it in this
   ecosystem version (`ST_OSTL_COMPATIBILITY_VERSION = "6.1"`; the
   propagation feature landed only in ecosystem-6.2, which this board
   isn't on). Instead, `st-boot-script.sh`'s `set-primary` handler
   persistently rewrites U-Boot's `bootcmd` itself via `fw_setenv` (see
   §2.4) — that's what actually makes U-Boot pick the correct bank on the
   next power-on.
3. U-Boot's `bootcmd` (as rewritten) sets `altboot` and runs
   `bootcmd_stm32mp`, which loads that bank's `extlinux.conf` from
   `bootfs-a`/`bootfs-b` and boots the kernel with `root=/dev/mmcblkNpM`
   and `rauc.slot=A|B` on the cmdline — both values patched into that
   slot's `extlinux.conf` at install time by `post-install.sh` (§2.3).
4. **Linux boots**; `rauc.slot=` on `/proc/cmdline` tells RAUC and every
   other consumer which bank is currently running.
5. **Trial/good-boot**: a newly-installed bank boots in *trial* state
   (FWU metadata bank_state = `V`). RAUC's `rauc-mark-good.service`
   (shipped by the `rauc` recipe itself, no local patch) calls `rauc
   status mark-good` after a successful boot, which invokes
   `st-boot-script.sh get-primary` → `update_metadata.sh ... accept`,
   flipping the bank to `A` (Accepted). **This bookkeeping is currently
   the only thing tracking accept/trial state — nothing in the boot chain
   actually acts on it if a boot fails. See §2.5.**

### 2.5 Known limitation: no automatic rollback on a failed boot

**Confirmed on hardware — this is the most significant open gap in the
current implementation.** The A/B mechanism correctly *selects* whichever
bank was last committed via `set-primary`, and correctly records
accept/trial state in FWU metadata — but if that bank then **fails to
boot**, nothing automatically falls back to the previous good bank.

Verified by: on a known-good boot (bank A), mounting the *inactive* bank
B's `bootfs-b` (safe — not the running bank) and renaming away its kernel
`Image.gz` to simulate a broken OTA install; then, from the serial
console, interactively (not persisted) simulating what `set-primary B`
would leave behind. U-Boot correctly found `bootfs-b`'s `extlinux.conf`,
failed to retrieve the now-missing `/Image.gz`
(`EXTLINUX FAILED: continuing...`), fell through its EFI boot-manager
path, and landed back at the interactive `STM32MP>` prompt — with **no**
attempt to fall back to bank A. On real hardware, with nobody watching a
serial console, the device would simply sit there.

Root cause: `set-primary` unconditionally, persistently rewrites
`bootcmd` via `fw_setenv` the moment `rauc install` finishes — there is
no countdown or "try N times, then revert." U-Boot's own
`bootcount`/`bootlimit`/`altbootcmd` primitives exist in the environment
(added by the A/B U-Boot patch) but `bootlimit` is unset
(`fw_printenv bootlimit` → empty), so they're never actually invoked.
Separately, `get-primary`'s "accept" call isn't gated on any real health
check — it fires on the first status query after boot, which may happen
well before anything resembling a meaningful "did this update actually
work" checkpoint.

**Practical effect**: today, "rollback safety" only covers TF-A/U-Boot
correctly booting whichever bank was last committed — not recovering
automatically from a bank that fails to boot at all. Fixing this
requires an architectural change (wiring `bootcount`/`bootlimit` into
`bootcmd_stm32mp` so `set-primary` arms a real retry-then-revert instead
of committing unconditionally, or porting the "propagate boot index from
TF-A" mechanism noted as landing in ecosystem-6.2 — this platform is on
6.1) — not a same-session patch. Treat this as a known limitation until
it's addressed.

### 2.3 Update flow (what `rauc install` actually does)

1. RAUC verifies the bundle's signature against `/etc/rauc/ca.cert.pem`
   and writes each bundle slot (`fip`, `bootfs`, `vendorfs`, `rootfs`)
   straight to the **inactive** bank's partitions.
2. RAUC's post-install handler, `post-install.sh`, runs:
   - Mounts the newly-written `bootfs-X`, patches its `extlinux.conf`:
     `root=/dev/mmcblk<N>p10` → `p11` (or vice versa) and
     `rauc.slot=A` → `rauc.slot=B` (or vice versa), via regex substitution
     against the "A is default" baked-in config.
   - Mounts the newly-written `rootfs-X`, patches `mount-partitions.sh`'s
     embedded `bootfs-a`/`vendorfs-a` label references to point at the
     slot that was just installed.
   - Calls `/usr/lib/fwu/update_metadata.sh <new> <old> refuse` — writes
     `metadata1`/`metadata2` with the new bank marked `V` (trial) and the
     current bank staying `A` (accepted), i.e. bootcount/trial mode is
     armed for the new bank.
3. RAUC's custom bootloader backend, `st-boot-script.sh`, is called with
   `set-primary <A|B>` — this is what actually commits the new bank as
   "boot this one next" by rewriting U-Boot's `bootcmd` (§2.2 step 2).
4. Device reboots (not automatic — the caller decides when).

### 2.4 Device-scoped partition resolution (`/run/cargt-part/`)

eMMC and SD card carry **identically-named** GPT partitions (the same
image gets flashed to either). `/dev/disk/by-partlabel/<name>` is a
system-wide symlink — ambiguous whenever both devices are present at once
(eMMC is always present; SD card whenever inserted), and not guaranteed to
resolve to the device actually being booted from.

`cargt-device-symlinks.service` (a small oneshot script, runs early in
boot, `Before=... rauc.service`) determines which physical `mmcblkN` the
running root filesystem actually lives on (via `findmnt` on `/`), then
creates `/run/cargt-part/<name>` symlinks scoped to *that* device only —
reusing the same device-detection technique already proven by
`mount-partitions.sh` for `/boot`/`/vendor`/`/usr/local`. Every RAUC
consumer (`system.conf`, `post-install.sh`, `update_metadata.sh`,
`fw_env.config`) references `/run/cargt-part/<name>`, never
`/dev/disk/by-partlabel/<name>` directly.

**The one exception**: the kernel's own `root=` cmdline argument. It's
resolved by the kernel *before* any userspace symlink service can run, so
it must be a literal `/dev/mmcblk<N>p<M>` device path, not a label/UUID —
set per-target (`UBOOT_EXTLINUX_ROOT:target-emmc` /
`:target-sdcard`) in the machine conf. U-Boot's extlinux boot flow does
generate two separate config directories per bootfs image
(`mmc0_extlinux/`, `mmc1_extlinux/`, each with the correct device-specific
`root=` baked in) — **but as of this writing, U-Boot does not actually
select the one matching the device it's booting from.** See §2.6 — this
is currently the blocking issue for SD card boot.

### 2.6 SD card boot: two bugs found and fixed — now working

**Confirmed working on hardware.** Bringing up SD card boot for the
first time surfaced two independent, unrelated bugs — both are the same
kind of mistake as the `u-boot-env` and udev-ignorelist issues in §3.3/3.5:
code or config that assumes eMMC and SD card share identical partition
*numbering* (they don't — see §2.1's fsbla1/fsbla2 note). Both are now
fixed, and a full SD card Linux boot has been verified end-to-end: kernel
mounts `root=/dev/mmcblk0p12` cleanly, `bootfs-a`/`vendorfs-a`/`userfs`
all mount without error, `rauc status` reports `booted: A`,
`boot_status: good`, and all twelve `/run/cargt-part/*` symlinks
correctly resolve to `mmcblk0` (SD card) devices — the device-scoped
symlink mechanism (§2.4) works correctly when actually booted from the
SD card, not just when booted from eMMC.

1. **`UBOOT_EXTLINUX_ROOT:target-sdcard` pointed at the wrong partition
   (fixed).** It was hardcoded to `root=/dev/mmcblk0p10`, copied from
   eMMC's numbering — but on the SD card, p10 is `vendorfs-a`, not
   `rootfs-a` (which is p12 there, due to the two extra `fsbla1`/`fsbla2`
   partitions at the front). The kernel booted fine and mounted p10 as
   root, but the initrd correctly detected this wasn't a real rootfs
   (`ERROR: There's no '/dev' on rootfs.`) and stalled. ~32 seconds later,
   the U-Boot-registered watchdog (`arm_smc_wdt`, armed at kernel boot)
   reset the board, which then booted normally back onto eMMC via the
   untouched, persisted `bootcmd` — **the board recovered on its own**;
   no data or state was lost. (This was initially misdiagnosed live as an
   unrecoverable hang, because a full boot-reset-reboot cycle takes
   ~200s+ and the on-the-spot investigation gave up waiting after ~90s. A
   burst of `regulator: disabling` messages for `vddcore`/`v1v8`/`v3v3`
   right before the stall looked suspicious but turned out to be a red
   herring — the identical burst appears at the same timestamp on every
   single eMMC boot too, completely harmlessly; it's Linux's standard
   "disable unused regulators" cleanup, unrelated to the actual failure.)
   Fixed: `UBOOT_EXTLINUX_ROOT:target-sdcard = "root=/dev/mmcblk0p12"`.
2. **`boot_prefixes` is static, not device-aware.** U-Boot's own env has
   `boot_prefixes=/mmc1_` as a fixed value — nothing sets it to `/mmc0_`
   when booting from the SD card. Since both `mmc0_extlinux/` and
   `mmc1_extlinux/` physically exist on every `bootfs-a`/`bootfs-b` image
   (the same image is deployed to both eMMC and SD card), U-Boot always
   finds and uses `/mmc1_extlinux/extlinux.conf` regardless of which
   device it's actually scanning — silently pulling in the **eMMC's**
   `root=` even when booting from the SD card. Verified directly at the
   U-Boot prompt: with the stock (unmodified) environment, scanning `mmc
   0` still resolved `root=/dev/mmcblk1p10`; manually
   `setenv boot_prefixes /mmc0_` before the same scan correctly resolved
   the SD card's own config. `boot_instance` — the variable this
   project's test plan assumed could redirect OS boot target without
   touching physical boot-mode switches — turned out to *not* be usable
   for that: it gets re-derived from the actual hardware boot straps
   every boot (confirmed: persisting it via `fw_setenv` had no effect on
   the next boot's behavior), so it can't be used to steer
   `boot_prefixes` either. The fix instead derives it from `${devnum}`
   (reliably correct for whichever device is actually being scanned,
   regardless of how that scan was triggered) inside `mmc_boot` itself:
   `env set boot_prefixes "/mmc${devnum}_"` before
   `run scan_dev_for_boot_part`.

**Both bugs needed fixing together** — fixing only #1 without #2 would
have U-Boot keep resolving `/mmc1_extlinux/` (eMMC's config) regardless,
silently booting the wrong device's rootfs while appearing to test the
SD card.

A separate, one-off SD card write corruption was also hit and resolved
during this bring-up (an `ext4_check_descriptors` checksum failure on
`rootfs-a`) — root-caused by extracting the partition directly from the
source `.wic` file and running `e2fsck` against it with the
Yocto-native e2fsprogs (matching version; the host's stock `e2fsck` was
too old to even parse the filesystem's feature set), which came back
completely clean. That proved the corruption was introduced during the
`dd` write itself, not the build. A full-card `badblocks -sv` scan then
came back with **zero bad blocks**, and a repeat write succeeded cleanly
— so this was a transient write glitch, not a build bug or a
failing card. If a similar corruption reappears, re-verify the source
image first (rules out a build regression) before suspecting the card or
write path again.

**Not yet tested: RAUC-over-SD-card itself.** One more thing to account
for first — on this specific test rig, U-Boot is always physically
strapped to load from eMMC even when Linux boots from the SD card, and
`fw_env.config`'s `/run/cargt-part/u-boot-env` resolves to *whichever
device Linux's root is on* (§2.4) — so `fw_setenv` run from an
SD-card-booted system would target the SD card's own (unused)
`u-boot-env` partition, not the one U-Boot actually reads. That means
`st-boot-script.sh`'s `set-primary` (which relies on `fw_setenv`) would
silently fail to influence the next boot in *this specific dual-media
test configuration*. This is a test-rig artifact, not a product bug — a
real deployment that boots both U-Boot and Linux from the same SD card
(no eMMC, or boot straps set to SD) wouldn't hit it, since U-Boot's own
environment would live on that same card. Worth knowing before RAUC
install/set-primary testing over SD card is attempted, so a no-op
`set-primary` isn't misread as a new bug.

## 3. Implementation Details

### 3.1 Repo/layer map

| Repo | What it holds |
|---|---|
| `meta-st-cargt` | All RAUC recipes/patches, TF-A/U-Boot/kernel changes, bundle recipe, systemd units |
| `meta-cargt-stm32mp-addons` | Machine conf (`UBOOT_EXTLINUX_*`, `rauc.slot=A` default), `.wks.in` partition layout, `fw_env.config` |
| manifest (`cargt-stm32mp2.xml`) | Pins `rauc/meta-rauc` as a layer dependency |

### 3.2 Key files (`meta-st-cargt`)

| File | Purpose |
|---|---|
| `conf/distro/cargt-openstlinux-weston.conf` | `DISTRO_FEATURES += "gplv3 rauc"` — gates every RAUC-conditional recipe/patch below |
| `recipes-bsp/u-boot/u-boot-stm32mp/0006-stm32mpu-update-env-to-support-boot-A-B.patch` | Adds `altboot`/`altbootcmd` env vars to the stm32mp defconfig (ported from ST's `meta-st-ota`) |
| `recipes-bsp/trusted-firmware-a/tf-a-stm32mp/0002-add-logs-for-demo-purpose.patch` | NOTICE-level bank-selection logging, for visibility during bring-up |
| `recipes-kernel/linux/linux-stm32mp/6.6/cargt_rauc_kernel_config_mods.config` | `CONFIG_BLK_DEV_LOOP`, `CONFIG_SQUASHFS`, `CONFIG_MD`, `CONFIG_BLK_DEV_DM`, `CONFIG_BLK_DEV_NBD`, `CONFIG_DM_VERITY`, `CONFIG_CRYPTO_SHA256` — required for RAUC's dm-verity bundle format |
| `recipes-core/rauc/rauc_%.bbappend` + `files/0001-support-bin-extension.patch` | Patches RAUC's `update_handler.c` so it accepts `*.bin` images as `raw` slot type (needed for the fip binary) |
| `recipes-core/rauc/rauc-conf.bbappend` + `files/system.conf`, `post-install.sh`, `st-boot-script.sh`, `ca.cert.pem` | The actual RAUC config + custom bootloader backend + post-install patching logic (see §2.3/2.4) |
| `recipes-core/fwu-gen-metadata/fwu-gen-metadata-v2.bb` + `files/update_metadata.sh` | Writes TF-A FWU metadata (v2 format) via `mkfwumdata`; fixed platform-wide UUIDs, not per-board |
| `recipes-core/bundles/update-st-bundle-stm32mp25-cargt-00395-02-00365.bb` | The bundle recipe (slots, compatible string, signing key/cert) |
| `recipes-core/systemd/cargt-device-symlinks_1.0.bb` | The `/run/cargt-part/` symlink service (§2.4) |
| `recipes-core/systemd/systemd-mount-partitions.bbappend` | Adds `-a` suffix to bootfs/vendorfs/rootfs in `MOUNT_PARTITIONS_LIST` (not userfs) |
| `recipes-core/udev/udev-extraconf_%.bbappend` + `files/cargt-ab-partitions.ignorelist` | Excludes A/B partitions (mmc[01]p1–p11) from udev's generic auto-mounter — without this, the automounter races RAUC for exclusive access to the inactive slot ("Device or resource busy") |
| `recipes-st/initrd/initrd-boot/0002-skip-first-boot-resize-for-fixed-size-ab-partitions.patch` | Skips `init-resize.sh`'s fsck/resize for `root*`/`vendor*`/`boot*` — those partitions are fixed-size, only `user*` needs it |
| `recipes-bsp/tools/resize-helper/0002-skip-fixed-size-ab-partitions.patch`, `0003-skip-userfs-resize-if-already-done.patch` | Same idea for the other first-boot resize script; `0003` additionally records a marker **on userfs itself** (not in `/etc`, which every OTA update reflashes) so the slow `e2fsck -c` bad-blocks pass only ever runs once, not on every fresh-slot first boot |
| `recipes-cargt/images/cargt-image-dev.bb` / `cargt-image-weston.bb` | Installs `rauc rauc-conf fwu-gen-metadata-v2 u-boot-tools-stm32mp cargt-device-symlinks` when `rauc` is in `DISTRO_FEATURES` |

### 3.3 Key config (`meta-cargt-stm32mp-addons`)

- `conf/machine/stm32mp25-cargt-00395-02-00365.conf`:
  `UBOOT_EXTLINUX_KERNEL_ARGS:append = " rauc.slot=A"` (build-time default);
  `UBOOT_EXTLINUX_ROOT:target-emmc/:target-sdcard` (literal device paths,
  §2.4).
- `wic/sdcard-...-vendorfs-2GB.wks.in`: the partition table (§2.1). Its
  `u-boot-env` partition's `--part-name` must read `u-boot-env` (with the
  dash) to match both the actual eMMC layout and what
  `cargt-device-symlinks.sh`/`fw_env.config` look for — this drifted to
  `uboot-env` (no dash) at one point and silently broke the SD-card-side
  symlink for that one partition until caught by inspecting the built
  `.wic` file's partition table before the first SD card flash.
- `recipes-bsp/u-boot/libubootenv/.../fw_env.config`: points at
  `/run/cargt-part/u-boot-env`, not `/dev/disk/by-partlabel/u-boot-env`
  (§2.4).

### 3.4 Bundle contents

`update-st-bundle-stm32mp25-cargt-00395-02-00365.bb`:
- Slots: `fip`, `bootfs`, `vendorfs`, `rootfs` (matches `RAUC_BUNDLE_SLOTS`
  in `system.conf`'s `compatible=` string:
  `cargt-stm32mp25-00395-02-00365`).
- Format: `verity` (dm-verity-hashed, per-slot).
- Sourced from `st-image-bootfs`, `st-image-vendorfs`, and this layer's
  actual top image recipe (`cargt-image-dev`/`cargt-image-weston`) — **not**
  `st-image-weston`, which upstream reference material uses but which
  isn't the real image built here.
- Signed with a development cert/key pair
  (`recipes-core/bundles/files/development-1.{key,cert}.pem`) verified
  against `/etc/rauc/ca.cert.pem` on target. **Replace both for
  production** — these are demo-only, checked into the layer.

### 3.5 udev automount exclusion

`cargt-ab-partitions.ignorelist` excludes `/dev/mmcblk[01]p1` through
`p11` from the stock `udev-extraconf` automounter (which otherwise mounts
every filesystem-bearing partition under `/run/media/`, active or
inactive). `userfs` (p12) is intentionally left mountable — it's not part
of the A/B scheme and isn't auto-mounted by anything else anyway.

### 3.6 First-boot resize interactions

Two separate first-boot resize scripts exist in this BSP
(`initrd-boot`'s `init-resize.sh`, and `resize-helper`, both from ST).
Both originally tried to grow/fsck **every** ext4 partition on first boot —
correct for single-bank boards, wrong here: `bootfs`/`vendorfs`/`rootfs`
are fixed-size A/B slots with no space to grow into, and only `userfs`
ever needs it. Both were patched to restrict to `userfs` only (§3.2). The
actual multi-minute first-boot cost that motivated this investigation came
from `init-resize.sh`, which runs unconditionally in the initrd, before
systemd, and (pre-patch) did a full `e2fsck -f -y -c` bad-blocks scan on
`root`/`vendor`/`boot` on every boot.

`resize-helper` runs later, under systemd, and on this board takes the
`systemd-growfs` branch (not its own direct-`resize2fs`+`e2fsck -c`
fallback) — growing an already-full-size `userfs` this way completes in
well under a second, so it was never the source of the multi-minute delay.
It still got a second fix (`0003-skip-userfs-resize-if-already-done.patch`):
a persistent marker recorded on `userfs` itself (not in the
systemd-unit-disabled state resize-helper otherwise tracks its "already
ran" status with, which lives in `/etc` — part of rootfs, and so is reset
by every OTA update's fresh rootfs image). This avoids a redundant (if
cheap) growfs call on every fresh-slot boot, and is what keeps this board
off the slow fallback path if `systemd-growfs` ever becomes unavailable.
Verified on hardware: the marker's mtime is unchanged across a second
fresh-slot install, confirming the guarded growfs call is actually
skipped the second time, not just logged as if it were.

## 4. Examples

### 4.1 Build

```sh
bitbake cargt-image-dev
bitbake update-st-bundle-stm32mp25-cargt-00395-02-00365
```
Bundle lands in `tmp-glibc/deploy/images/<machine>/update-st-bundle-stm32mp25-cargt-00395-02-00365.raucb`.

### 4.2 Push and install

```sh
scp update-st-bundle-stm32mp25-cargt-00395-02-00365.raucb root@<DUT>:/usr/local/
ssh root@<DUT> 'rauc install /usr/local/update-st-bundle-stm32mp25-cargt-00395-02-00365.raucb'
```
`rauc install` targets whichever bank is currently inactive — no need to
specify which slot.

### 4.3 Reboot and confirm the switch

```sh
ssh root@<DUT> reboot
# ... wait for it to come back ...
ssh root@<DUT> 'cat /proc/cmdline; rauc status --output-format=json-pretty'
```
Look for `rauc.slot=B` (or `A`) on the cmdline matching the bank you just
installed into, and `"boot_status": "good"` on the now-booted slot in
`rauc status` output — the readable-text form of `rauc status` wraps
values in ANSI color codes, so prefer `--output-format=json` (or
`json-pretty`) for anything you intend to script against; parsing the
colored text directly is a real trap (see the Testing status note).

### 4.4 Manual bank inspection / control

```sh
rauc status --detailed
rauc status mark-good      # accept the current (trial) bank explicitly
/usr/lib/rauc/st-boot-script.sh get-primary
/usr/lib/rauc/st-boot-script.sh set-primary B
fw_printenv bootcmd altbootcmd altboot bootcount
```

### 4.5 Troubleshooting

- **`Unsupported image ... .bin for slot type raw`**: the `.bin`-extension
  RAUC patch (§3.2) isn't in the running `rauc` binary yet, or the RAUC
  D-Bus service hasn't picked up a just-rebuilt binary/config — restart it
  (`systemctl restart rauc.service`) after any RAUC-affecting package
  update, and confirm you're actually testing the newly-built bundle, not
  a stale one left over from before the fix.
- **`Device or resource busy` writing to the inactive slot**: the generic
  udev automounter mounted it first — confirm
  `cargt-ab-partitions.ignorelist` (§3.5) is actually installed and
  matches the partition in question.
- **Slot doesn't flip after install+reboot**: check `fw_printenv bootcmd`
  — if it still says `Boot A` (or whichever was previously active) after
  installing into the other bank, `set-primary` didn't run or didn't
  persist; this is the "no automatic TF-A→U-Boot hand-off" gap described
  in §2.2 — the fix lives entirely in `st-boot-script.sh`'s `set-primary`
  handler, so start there.

## Testing status

- **eMMC install/reboot/verify, both directions (A→B and B→A):** PASS.
  Confirmed via `rauc status`, `/proc/cmdline`, and a demo marker file.
- **eMMC repeated-cycle stress test:** PASS, 6/6 consecutive back-to-back
  A↔B cycles, no flakiness, no races. (One early iteration of the test
  script itself reported a false failure due to parsing colored
  `rauc status` text output — not a product bug; see §4.3.)
- **userfs resize-marker fix:** PASS, verified directly on hardware — a
  marker written to `userfs` on first grow is correctly left untouched
  (same mtime) across a subsequent fresh-slot OTA install, confirming the
  guarded resize call is actually skipped the second time.
- **Rollback-on-failed-boot:** **FAIL — confirmed gap, not yet fixed.**
  See §2.5. This is the most significant finding from this round of
  testing and should be treated as a known limitation, not a corner case,
  until addressed.
- **u-boot-env partition naming:** bug found and fixed before first SD
  card flash — see §3.3 — the SD card's `.wks.in` used `uboot-env`
  (no dash) where eMMC and every consumer expect `u-boot-env`.
- **udev A/B ignorelist device-numbering gap:** bug found and fixed — see
  §3.5 — the SD card's extra `fsbla1`/`fsbla2` partitions shift every
  later partition number by 2 relative to eMMC, so a combined
  `mmcblk[01]p1-p11` pattern left the SD card's actual `rootfs-a`/`rootfs-b`
  (p12/p13 there, not p10/p11) exposed to the generic automounter.
- **SD card boot: PASS.** See §2.6. Two bugs found and fixed (a wrong
  `UBOOT_EXTLINUX_ROOT:target-sdcard` partition number, p10→p12; a
  static, non-device-aware `boot_prefixes` U-Boot env value, now derived
  from `${devnum}` in `mmc_boot`), plus a one-off SD card write-corruption
  incident that turned out to be transient (source image and card both
  verified clean; a repeat write succeeded). Confirmed the board recovers
  on its own via its watchdog from a fatal-boot state — not a permanent
  hang, contrary to the initial live diagnosis. Full boot verified via
  SSH: correct `root=`, correct mounts, `rauc status` good, all
  `/run/cargt-part/*` symlinks correctly SD-card-scoped.
- **SD card RAUC updates: not yet tested.** SD card boot itself is now
  confirmed working, but installing/booting an actual RAUC update while
  running from the SD card hasn't been tried yet — see the
  `fw_env.config`/`set-primary` caveat in §2.6 first (specific to this
  dual-media test rig, not expected in a real SD-card-only deployment).

This section reflects the state as of the most recent test session; keep
it in sync as SD-card RAUC testing and any rollback-mechanism fix land.
