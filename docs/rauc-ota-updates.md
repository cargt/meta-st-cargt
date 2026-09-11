# RAUC A/B OTA Updates — STM32MP2 (00395-02-00365)

> **Status: draft.** This describes the RAUC-based remote update mechanism
> added to `meta-st-cargt` / `meta-cargt-stm32mp-addons` for machine
> `stm32mp25-cargt-00395-02-00365`. It's being written up for
> dev.cargt.com; a companion doc for the i.MX/SWUpdate side is planned once
> that work happens. RAUC A/B updates are now verified working
> end-to-end on **both** eMMC and SD card, **and the rollback-safety gap
> (§2.5) is now closed and confirmed working end-to-end on real
> hardware**: env-based `bootcount`/`bootlimit` rollback, a kernel
> watchdog-behavior fix, and a bank that fails to boot `bootlimit`
> times in a row now automatically falls back to the previous good
> bank with no manual intervention. See §2.5 and "Testing status" for
> the full verification history.

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

**§2.5 update: automatic fallback if the new copy fails to *boot* is now
confirmed working end-to-end.** The A/B swap itself has always been
solid — install, reboot, and slot-selection have been exercised heavily
and work reliably. Rollback safety (env-based `bootcount`/`bootlimit`,
§2.5) required two independent fixes (a kernel watchdog-behavior config
and the U-Boot bootcount patch itself) before a full test with both
genuinely present together was possible; that test has now been run and
passed cleanly: a bank deliberately sabotaged to fail at boot got
exactly `bootlimit` (3) real attempts, each one correctly recovering via
a watchdog reset rather than hanging forever, then automatically fell
back to the previous good bank on the 4th attempt with zero manual
intervention — verified via a fully passive serial capture and
confirmed post-boot state over SSH. This system can now be described as
self-healing on a failed boot.

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
  One partition, but not a single point of failure for env writes: per
  `fw_env.config`, it holds two redundant environment copies at different
  offsets (`-0x4000` and `-0x2000`, `0x2000` each) — standard
  `libubootenv` redundant-environment behavior.

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

### 2.5 Rollback safety: env-based bootcount (implemented and confirmed working end-to-end)

**Original gap** (kept here for context): `set-primary` used to
unconditionally, persistently rewrite `bootcmd` the moment `rauc install`
finished — no countdown, no "try N times, then revert." If a
newly-installed bank failed to boot at all, nothing automatically fell
back to the previous good bank; confirmed live by simulating a missing
kernel on an inactive bank and watching U-Boot fall through to its own
interactive prompt with no recovery attempt.

**Implementation** (`0007-enable-bootcount-env-for-ab-rollback-safety.patch`
+ a redesigned `st-boot-script.sh`):

- `CONFIG_FWU_MULTI_BANK_UPDATE` is disabled. It was already enabled in
  the defconfig, and U-Boot's generic autoboot logic
  (`common/autoboot.c bootdelay_process()`) consults it ahead of the
  plain bootcount mechanism whenever set — but stm32mp2 has no
  `fwu_plat_get_bootidx()` implementation (unlike stm32mp1, which reads a
  TAMP backup register also written by TF-A), so it falls through to a
  weak default that resolves to "always run `bootcmd`" regardless of
  actual bank state. Confirmed empirically on hardware (marker commands
  in `bootcmd`/`altbootcmd`, full reset, autoboot left uninterrupted)
  before disabling it — it was pure dead weight.
- `CONFIG_BOOTCOUNT_LIMIT` + `CONFIG_BOOTCOUNT_ENV` are enabled instead —
  U-Boot's generic, portable, environment-only bootcount backend
  (`drivers/bootcount/bootcount_env.c`), no hardware register needed.
- `st-boot-script.sh set-primary BOOTNAME` now sets **both** `bootcmd`
  (the new bank) and `altbootcmd` (the other, current-good bank) as a
  real pair, and arms the trial: `upgrade_available=1`, `bootcount=0`,
  and explicitly `fw_setenv bootlimit 3` (matching TF-A's own
  independent 4-try trial convention). Per `bootcount_env.c`, bootcount
  only accumulates — and is only ever compared against `bootlimit` — while
  `upgrade_available=1`, so a normal (non-trial) boot is unaffected.
  **The explicit `fw_setenv bootlimit` call is not redundant with the
  defconfig default**: a compiled-in default only populates a genuinely
  fresh/reset environment, not one already persisted by an older U-Boot
  build — any board provisioned before this feature existed would
  otherwise silently have the safety net disabled forever. Making
  `set-primary` set it explicitly every time makes the fix
  self-installing regardless of when a given board's environment was
  first created.
- `st-boot-script.sh get-primary` is now a pure read-only query (just
  reports the current bank from `/proc/cmdline`) — it no longer calls
  `update_metadata.sh ... accept` itself, fixing a second, related issue
  where "accept" used to fire on the first status query after boot,
  before any real health checkpoint.
- `st-boot-script.sh get-state` (invoked by `rauc-mark-good.service`
  after a real health checkpoint) does the actual accept
  (`update_metadata.sh ... accept`), resyncs `bootcmd`/`altbootcmd` to
  whatever bank is *currently* running, and disarms
  (`upgrade_available=0`, `bootcount=0`). This runs identically whether
  the current bank is good because a fresh install succeeded, or because
  U-Boot's own bootcount mechanism already fell back to it automatically
  — either way, "whatever's running now" becomes the new baseline.

**A deployment gotcha worth knowing**: after changing `st-boot-script.sh`
(or any file that ends up in a bundle), the bundle **must be rebuilt**
before testing — a stale already-built `.raucb` will silently deploy old
script content with no error. Confirmed the hard way: a bundle built
before the `bootlimit` self-install fix landed was installed and tested
for a while before the mismatch was caught (`md5sum` on the deployed
`/usr/lib/rauc/st-boot-script.sh` vs. the local source file disagreed,
and `fw_printenv bootlimit` came back empty even after `set-primary`
ran). Also note each bank's rootfs regenerates its own SSH host key on
its first boot after being freshly installed — expect (and ignore) an
SSH "REMOTE HOST IDENTIFICATION HAS CHANGED" warning the first time you
connect to a bank right after installing a bundle into it; it is not a
MITM concern, just a fresh-image artifact (`ssh-keygen -R <host>` before
reconnecting, or use `-o StrictHostKeyChecking=accept-new` while testing).

**Testing gotcha specific to eMMC**: every `bootfs-a`/`bootfs-b` image
carries *two* extlinux config directories, `mmc0_extlinux/` (SD-card
literal `root=`) and `mmc1_extlinux/` (eMMC literal `root=`) — see §2.6.
On an eMMC-booting board, `mmc0_extlinux/extlinux.conf` is completely
dormant; U-Boot's `boot_prefixes` env resolves to `/mmc1_` and never
reads it. Editing `mmc0_extlinux/extlinux.conf`'s `root=` to simulate a
bad boot on eMMC is a silent no-op — the corruption never reaches the
kernel cmdline. (Traced directly in `boot/pxe_utils.c label_boot()`:
there is no `root=`-specific substitution logic anywhere in U-Boot — the
`APPEND` line is used verbatim as `bootargs` after only `${var}` macro
expansion. The device/partition-number "correction" seen when comparing
a bank's `mmc0_extlinux` content to its actual booted cmdline is not a
runtime substitution at all — it's two independently-baked,
independently-patched files that simply never get reconciled against
each other.) Any failure-injection test on eMMC must edit
`mmc1_extlinux/extlinux.conf`.

**Status as of this writing**: implemented and deployed to both eMMC
banks (`bootlimit=3` confirmed armed). A live sabotage test — corrupt the
inactive bank's real `root=` (via `mmc1_extlinux` on eMMC / `mmc0_extlinux`
on SD card, whichever the board actually reads), arm the trial via
`set-primary`, reboot, and watch for automatic fallback to the other bank
after `bootlimit` failed attempts — **initially failed on both eMMC and
SD card**: the board went completely network-unreachable (not just
SSH-unreachable) for many minutes with no recovery, versus the ~30-40s a
working watchdog-reset cycle should take, and needed a physical
power-cycle each time.

**Root cause #1, found via a direct A/B test with live serial console
observation both times**: rebuilt U-Boot with patch 0007 (this section's
own bootcount mechanism) entirely removed, verified via `strings` on the
raw compiled binary that `CONFIG_BOOTCOUNT_LIMIT` was genuinely not
compiled in, flashed that binary into the SD card's active FIP slot, and
reproduced the identical sabotage against it. **The old, unmodified
U-Boot hung identically** — ruling out patch 0007 itself as the cause.
(Build-system note: getting a genuinely reverted test artifact required
cleansstating and rebuilding `fip-stm32mp` specifically, not just
`u-boot-stm32mp`/`tf-a-stm32mp` — `fip-stm32mp.bb` is a separate recipe
that assembles the final FIP and wasn't being invalidated by rebuilding
the other two, producing misleading "still broken" results on the first
two attempts.)

**Root cause #2, found via source investigation (`drivers/watchdog/arm_smc_wdt.c`,
kernel `.config`)**: `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` (an upstream
Linux default, not set by any of this project's own kernel config
fragments) makes the kernel's generic watchdog core detect that U-Boot
already armed the hardware watchdog and auto-feed it **in-kernel**,
independent of userspace, until systemd opens `/dev/watchdog`
(`RuntimeWatchdogSec=32`) and takes real ownership. Since our sabotage
hang happens in the initrd — before systemd ever starts — the kernel
just kept silently feeding the watchdog through the entire hang,
forever. **Fixed** by adding
`# CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED is not set` to
`cargt_rauc_kernel_config_mods.config` (gated on the RAUC feature, since
a non-RAUC board doesn't need this behavior changed). **Confirmed working
on real hardware**: after deploying the fixed kernel, the identical
corrupted-`root=` sabotage now reliably triggers
`E/TC Panic 'Watchdog' at .../stm32_iwdg_it_handler` (OP-TEE's own
watchdog IRQ handler — the same recovery signature previously only seen
for post-systemd crashes) roughly 20-30s into the hang, followed by a
clean reset and automatic retry. Reproduced 6 times in a row without a
single miss.

**Root cause #3 (found along the way, also fixed): a U-Boot autoboot
partition-scan bug, unrelated to rollback-safety but blocking this exact
test.** `distro_bootpart` (`include/config_distro_bootcmd.h`'s
`scan_dev_for_boot_part`) is left at whatever value a scan attempt last
computed it to and is never reset — only `devplist` gets cleared at the
end of that macro. A previous interactive session's leftover value
persists across power cycles (once written to flash, e.g. by this
board's `env_check` autosave, or an explicit `saveenv`) and gets
incremented further by the A/B `+1` adjustment on top of an already-wrong
base, drifting the "selected" partition further from the real bootfs
partitions (6/7) with each affected boot — observed landing on 8, then
9-and-10, in two different sessions. **Workaround/fix**:
`setenv distro_bootpart` (clear it) then `saveenv` — confirmed this
alone restores correct automatic scanning indefinitely afterward. A
proper patch would have `scan_dev_for_boot_part` clear
`distro_bootpart` itself the same way it already clears `devplist`.

**A "root cause #4" was initially suspected here and turned out to be a
false lead worth recording as a cautionary tale, not a real bug**: an
extended test run showed `bootcount` staying fixed at a manually-set
value across multiple automatic hang → watchdog-panic → reset cycles,
strongly suggesting `bootcount_store()`'s `env_save()` call wasn't
persisting across a hard reset. The actual explanation was much more
mundane: that entire test run (and the kernel watchdog-fix verification
before it) was executed against a U-Boot binary built while patch 0007
was *temporarily removed* from `SRC_URI` for the A/B isolation test in
§2.5's history, and it was never rebuilt with 0007 restored before
moving on — so `CONFIG_BOOTCOUNT_LIMIT` was never actually compiled
into the binary running on the board at all. `bootcount_inc()`/
`bootcount_error()` were the stub no-op versions
(`include/bootcount.h`'s `#else` branch) the whole time, which fully
explains every symptom: `bootcmd` always ran (the stub
`bootcount_error()` always returns 0), and `env_save()` was never
reached (not a silent failure — the function that calls it,
`bootcount_store()`, was never linked in). Confirmed by checking the
deployed FIP binary directly with `strings` for the
`"Bootlimit (%lu) exceeded"` marker compiled into the real
`bootcount_error()` — it was absent. After rebuilding with 0007
genuinely present (confirmed via the same `strings` check) and
redeploying just the FIP (no full image rebuild needed — only the
U-Boot/TF-A/OP-TEE binary changes for this), the full mechanism worked
correctly on the very first try — see "Testing status".

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

**RAUC-over-SD-card: confirmed working end-to-end.** Physically
re-strapping the boot-mode switches to load U-Boot itself from the SD
card (not just Linux) resolved the `fw_env.config`/`set-primary` caveat
noted in an earlier draft of this section — with both U-Boot and Linux
genuinely on the SD card, `fw_setenv` correctly targets the same
`u-boot-env` partition U-Boot itself reads. That surfaced one more bug
in the same family, caught before it could produce misleading test
results: `post-install.sh` hardcoded `rootfs_part_num_dico = {"A": 10,
"B": 11}` (eMMC's numbers) when patching the newly-installed bank's
`extlinux.conf` — on the SD card the regex's search pattern (literal
`p10`) never matched, so bank B's config was left saying `rauc.slot=B`
while still pointing `root=` at bank A's own partition. Fixed by
discovering the actual partition number baked into each device's own
"A" default and deriving "B" as that number plus one, rather than
assuming fixed values — correct on both eMMC and SD card without any
device detection, since rootfs-b always immediately follows rootfs-a in
the partition order on either device.

With that fixed, a full `rauc install` → reboot → verify cycle over the
SD card succeeded: `root=/dev/mmcblk0p13`, `rauc.slot=B`, `rauc status`
reports `booted: B`, `boot_status: good`. This is the first complete
RAUC A/B OTA update cycle confirmed working on the SD card.

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
| `recipes-bsp/u-boot/u-boot-stm32mp/0007-enable-bootcount-env-for-ab-rollback-safety.patch` | Disables the (confirmed-inert) `CONFIG_FWU_MULTI_BANK_UPDATE`, enables `CONFIG_BOOTCOUNT_LIMIT`/`CONFIG_BOOTCOUNT_ENV` — the actual rollback-safety mechanism (§2.5) |
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

### 3.7 Known issue (separate from rollback-safety): autoboot partition scan drifts to the wrong partition

**Found during rollback-safety testing, root-caused and worked around -
flagging clearly since it affects normal automatic booting, not just
A/B rollback.** On several occasions, neither persisted `bootcmd`
variant ("Boot A" nor "Boot B") could automatically reach its real
bootfs partition via the normal distro-boot flow
(`scan_dev_for_boot_part` -> `scan_dev_for_boot` in
`include/config_distro_bootcmd.h`) - instead landing on whatever
partition was one or two past the correct one (`vendorfs-a`/`vendorfs-b`
instead of `bootfs-a`/`bootfs-b`) and ultimately failing ("BootOrder not
defined", "EFI boot manager: Cannot load any image"), dropping to the
interactive U-Boot prompt.

**Root cause**: `scan_dev_for_boot_part`'s `distro_bootpart` variable is
never reset - only `devplist` gets cleared
(`"setenv devplist\0"`) at the end of that macro; `distro_bootpart`
itself is left holding whatever the last scan attempt computed. Once a
stale value gets written to the persisted environment (e.g. via this
board's `env_check` autosave, or an explicit `saveenv` during
interactive debugging), it survives power cycles and gets pushed further
by the A/B `+1` adjustment (`if test ${altboot} = 1; then setexpr
distro_bootpart ${distro_bootpart} + 1; fi;`) applied on top of an
already-wrong base, drifting the "selected" partition further from the
real bootfs partitions (6/7) with each affected boot - observed landing
on 8 in one session, then 9-and-10 in a later one, with `devplist`
independently confirmed correct (`6 7`) throughout.

**Confirmed fix**: `setenv distro_bootpart` (clear it, no value) then
`saveenv` at the U-Boot prompt. Verified this restores correct automatic
scanning (`Found /mmc1_extlinux/extlinux.conf`, proceeds to boot
normally) and stays fixed across multiple subsequent boots - the
persisted clear sticks. A proper upstream-style patch would have
`scan_dev_for_boot_part` clear `distro_bootpart` itself at the end of
the loop the same way it already clears `devplist`, so a stale value
can never accumulate in the first place; not yet implemented as a real
patch in this layer.

Workaround if a device gets stuck at the U-Boot prompt from this before
the above fix is applied: a fully manual boot (`ext4load` the
kernel/dtb/initrd from the correct bootfs partition directly, set
`bootargs` by hand, then `booti`) reliably recovers the device without
needing a reflash.

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
- **Deployed `st-boot-script.sh` doesn't match the local source file**:
  the bundle wasn't rebuilt after the last edit. Compare
  `md5sum /usr/lib/rauc/st-boot-script.sh` on target against the local
  `recipes-core/rauc/files/st-boot-script.sh` before trusting any live
  test result — a stale bundle installs old script content with no
  error or warning of any kind.
- **`fw_printenv bootlimit` comes back empty even after `set-primary`
  ran**: see §2.5 — a compiled-in defconfig default for `bootlimit` does
  not retroactively populate an environment already persisted by an
  older U-Boot build. `set-primary` sets it explicitly for exactly this
  reason; if it's still empty, the deployed script predates that fix
  (see the previous bullet).
- **SSH "REMOTE HOST IDENTIFICATION HAS CHANGED" right after an
  install+reboot**: expected — the freshly-installed bank's rootfs
  regenerates its own SSH host key on first boot. Not a MITM concern.
  `ssh-keygen -R <DUT-IP>` before reconnecting, or use
  `-o StrictHostKeyChecking=accept-new` while iterating on a bench DUT.
- **Simulating a bad boot on eMMC by editing `extlinux.conf`'s `root=`
  has no effect**: make sure you edited `mmc1_extlinux/extlinux.conf`,
  not `mmc0_extlinux/extlinux.conf` — see §2.5/§2.6. The latter is
  completely dormant on an eMMC-booting board; U-Boot never reads it.

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
- **Rollback-on-failed-boot:** **PASS — confirmed working end-to-end on
  real hardware.** See §2.5 for the full history (several distinct root
  causes found along the way). Summary:
  - Patch 0007 / the bootcount U-Boot mechanism was **ruled out** as the
    cause of the original hang-forever regression (A/B test against an
    unmodified U-Boot reproduced the identical hang).
  - The real cause was `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` letting
    the kernel silently auto-feed the watchdog through any pre-systemd
    hang. **Fixed and confirmed on real hardware**: the identical
    corrupted-`root=` sabotage now reliably triggers a watchdog panic
    and clean reset ~20-30s into the hang.
  - A separate, unrelated U-Boot autoboot partition-scan bug
    (`distro_bootpart` never resets, drifting to the wrong partition
    across boots) was found and fixed (`setenv distro_bootpart;
    saveenv`) — this was blocking automatic retries, not a
    rollback-safety defect itself.
  - A "root cause #4" (bootcount not persisting across a hard reset)
    was initially suspected but turned out to be a false lead: the
    binary under test that whole time had been built with patch 0007
    temporarily removed for an earlier isolation test and never
    rebuilt with it restored, so the bootcount mechanism was simply
    never compiled in. See §2.5 for the full account.
  - **With both fixes genuinely present together for the first time**
    (verified via `strings` on the deployed FIP), a full, fully passive
    (zero manual interaction) test passed cleanly: bank B, deliberately
    sabotaged to fail at boot, got exactly `bootlimit` (3) real
    attempts — each one hanging and then correctly recovering via a
    watchdog reset — and automatically fell back to bank A on the 4th
    attempt. Confirmed via SSH afterward: correct bank, `bootcmd`/
    `altbootcmd` correctly resynced, `upgrade_available=0` and
    `bootcount=0` correctly disarmed by `rauc-mark-good`. The A/B
    swap-on-successful-boot behavior (§1) remains solid throughout, as
    it always has been.
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
- **SD card RAUC updates: PASS.** With U-Boot itself also physically
  strapped to the SD card (resolving the `fw_env.config` dual-media
  caveat noted in an earlier draft), a full `rauc install` → reboot →
  verify cycle succeeded: `root=/dev/mmcblk0p13`, `rauc.slot=B`, `rauc
  status` reports `booted: B`, `boot_status: good`. Found and fixed one
  more bug in the same "eMMC/SD card numbers don't match" family along
  the way — `post-install.sh`'s hardcoded `rootfs_part_num_dico`
  (§2.6) — before it could produce a misleading result.
- **Known gap remaining on the SD card path:** `userfs` has not yet had
  its resize verified on a fresh SD card flash built with the e2fsck-twice
  fix (§ implementation notes) — the SD card currently in use for testing
  still has `userfs` stuck at its built 200M size from before that fix
  landed, which was enough to block pushing a bundle to `/usr/local`
  during this round (worked around by staging it in `/tmp` instead).
  Re-verify on the next fresh SD card reflash.

This section reflects the state as of the most recent test session; keep
it in sync as the userfs-resize re-verification and any rollback-mechanism
fix land.
