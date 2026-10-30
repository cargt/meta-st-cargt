# RAUC A/B OTA Updates — STM32MP2 (00395-01-00365 / 00395-02-00365)

> **Status: draft.** The custom bootloader backend was reworked and the
> A/B pieces made per-machine after the testing described below — see
> the first entry under "Testing status" before relying on it.
>
> This describes the RAUC-based remote update mechanism
> added to `meta-st-cargt` / `meta-cargt-stm32mp-addons`, brought up on
> `stm32mp25-cargt-00395-02-00365` first and then given full parity on
> `stm32mp25-cargt-00395-01-00365` (§2.1). It's being written up for
> dev.cargt.com; a companion doc for the i.MX/SWUpdate side is planned once
> that work happens. RAUC A/B updates are now verified working
> end-to-end on **both boards** and **both** eMMC and SD card, **and the
> rollback-safety gap (§2.5) is now closed and confirmed working
> end-to-end on real hardware**: env-based `bootcount`/`bootlimit`
> rollback, a kernel watchdog-behavior fix, and a bank that fails to boot
> `bootlimit` times in a row now automatically falls back to the previous
> good bank with no manual intervention. Two independent, non-RAUC-specific
> reliability bugs were also found and fixed along the way: a `userfs`
> resize bug specific to the SD card build (§3.6) and a Bluetooth driver
> race that could wedge the whole system (§3.8). See §2.5, §3.6, §3.8, and
> "Testing status" for the full verification history.

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

**Minimum eMMC/SD card size**: the fixed-size A/B partitions alone (not
counting `userfs`, which just fills whatever space is left) add up to
about **6.6 GiB**: `metadata1`+`metadata2` (1 MiB) + `fip-a`+`fip-b`
(8 MiB) + `u-boot-env` (0.5 MiB) + `bootfs-a`+`bootfs-b` (128 MiB) +
`vendorfs-a`+`vendorfs-b` (500 MiB) + `rootfs-a`+`rootfs-b` (6 GiB, 3 GiB
each) — confirmed via `lsblk` on real hardware for both
`00395-02-00365` and `00395-01-00365`. That's the absolute floor before
any `userfs` at all; budget **~8-10 GiB** in practice to leave real room
for persistent application data. The SD card layout adds two more small
fixed partitions up front (`fsbla1`/`fsbla2`, 256 KiB each, holding
TF-A BL2 - eMMC doesn't need these, since it stores its FSBL in
dedicated `mmcblk1boot0`/`boot1` hardware partitions instead), which is
negligible against this total - the same minimum-size guidance applies
to both media. Both DUTs this project has been tested on have ~29-31 GB
of eMMC, so this has not been a real constraint so far, but it's the
number to check against before ever considering smaller eMMC hardware
for a board in this family.

There are **two sources of truth** for this layout, which must be kept
in step by hand:
- **SD card**: `meta-cargt-stm32mp-addons/wic/sdcard-stm32mp257f-cargt-00395-02-00365-optee-vendorfs-2GB.wks.in`
  (and the `-optee-2GB` variant) — the `.wic` image.
- **eMMC**: ST's `flashlayout-stm32mp.bbclass` generates a single-bank
  FlashLayout TSV from `PARTITIONS_IMAGES` (not from the `.wks.in`), and
  `recipes-cargt/images/cargt-rauc-ab-flashlayout.inc` then splices it
  into the A/B layout (`bootfs`/`vendorfs`/`rootfs` → `-a`/`-b`, for
  every eMMC and SD card TSV — the main `CUBEMX_DTB` one and each
  per-panel `-glt*` one — in the fastboot, optee, opteemin and
  fastboot-opteemin bootschemes). Used by
  STM32CubeProgrammer / `production_program_service.py`. `00395-01-00365`
was brought up to the same layout afterward, in its own equivalently-named
`.wks.in` files - same partition structure and sizes, same minimum-media-size
guidance above.

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
   (FWU metadata bank_state = `V`, U-Boot `upgrade_available=1`).
   RAUC's `rauc-mark-good.service` (shipped by the `rauc` recipe itself,
   no local patch; `After=boot-complete.target`) calls `rauc status
   mark-good`, which RAUC turns into `st-boot-script.sh set-state <A|B>
   good`. That is the one place a trial is accepted: FWU metadata →
   `A` (Accepted), `bootcmd`/`altbootcmd` resynced to the running bank,
   bootcount disarmed. If the trial bank never gets that far, U-Boot's
   bootcount falls back to the other bank after `bootlimit` attempts
   (§2.5). Nothing currently hooks application-level health checks into
   `boot-complete.target`, so "good" today means "reached
   `multi-user.target`".

### 2.3 Update flow (what `rauc install` actually does)

Order as implemented by RAUC 1.15.2 (`src/install.c`):

1. RAUC verifies the bundle's signature against `/etc/rauc/ca.cert.pem`.
2. RAUC calls `st-boot-script.sh set-state <target> bad` *before* writing
   anything. The backend records the target in `rauc_bad`, and if that
   bank was still pending as primary from an earlier, not-yet-rebooted
   install, points `bootcmd` back at the running bank — so an interrupted
   write can never be booted.
3. RAUC writes each bundle slot (`fip`, `bootfs`, `vendorfs`, `rootfs`)
   straight to the **inactive** bank's partitions. The `fip` slot goes
   through the bundle's `fip-install-hook.sh` install hook, which picks
   the FIP matching the running panel variant (§3.4).
4. RAUC calls `st-boot-script.sh set-primary <A|B>`, which commits the
   new bank as "boot this one next" by rewriting U-Boot's `bootcmd`/
   `altbootcmd` and arming bootcount (§2.2 step 2, §2.5), and clears the
   bank's `rauc_bad` entry.
5. RAUC's post-install handler, `post-install.sh`, runs:
   - Mounts the newly-written `bootfs-X`, patches its `extlinux.conf`:
     `root=/dev/mmcblk<N>p10` → `p11` (or vice versa) and
     `rauc.slot=A` → `rauc.slot=B` (or vice versa), via regex substitution
     against the "A is default" baked-in config.
   - Mounts the newly-written `rootfs-X`, patches `mount-partitions.sh`'s
     embedded `bootfs-a`/`vendorfs-a` label references to point at the
     slot that was just installed.
   - Calls `/usr/lib/fwu/update_metadata.sh <new> <old> refuse` — writes
     `metadata1`/`metadata2` with the new bank marked `V` (trial) and the
     current bank staying `A` (accepted), i.e. TF-A's trial mode is
     armed for the new bank.
   - Calls `st-boot-script.sh set-primary <new>` again — a redundant,
     idempotent repeat of step 4, kept as a safety net (see the comment in
     `post-install.sh`).
6. Device reboots (not automatic — the caller decides when).

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
`root=` baked in); U-Boot picks between them via `boot_prefixes` — see
§2.6 for the SD card issues this caused and how they were resolved.

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
- `st-boot-script.sh` implements all four RAUC custom-backend verbs
  (RAUC 1.15 `src/bootloaders/custom.c`). The split that matters:
  **`get-primary`/`get-state` are strictly read-only**, and the only
  thing that accepts a trial is **`set-state <booted> good`**, which is
  what `rauc status mark-good` actually invokes.

  An earlier version put the accept logic in `get-state` and had no
  `set-state` handler at all (so `set-state` silently exited 0). It
  only appeared to work because `rauc status mark-good` fetches slot
  status — which calls `get-state A`/`get-state B` — before marking. The
  side effect was that *any* status query (`rauc status` over SSH, a
  D-Bus `GetSlotStatus` from an update agent) accepted the running bank
  and disarmed bootcount, and `rauc status mark-bad` did nothing.

  | Verb | Called by | Does |
  |---|---|---|
  | `get-primary` | `rauc status`, D-Bus | Prints the bank the next boot lands on: `bootcmd`'s bank, or `altbootcmd`'s if bootcount is already past `bootlimit`. |
  | `get-state X` | `rauc status`, D-Bus, and the status fetch inside `mark-good` | Prints `bad` if X is in `rauc_bad`, or X is `bootcmd`'s bank, not running, and its trial is exhausted; otherwise `good`. No writes. |
  | `set-primary X` | `rauc install` after writing; `rauc status mark-active` | `bootcmd`→X, `altbootcmd`→other, `bootlimit=3`, `bootcount=0`, `upgrade_available=1` (0 if X is the running bank), removes X from `rauc_bad`. |
  | `set-state X good` | `rauc status mark-good` (`rauc-mark-good.service`) | X running: FWU-accept X, resync `bootcmd`/`altbootcmd` to X, disarm; if we got here by fallback (trial exhausted), also adds the failed bank to `rauc_bad`. If an install into the other bank is pending and not yet booted, only clears X's bad mark (a manual `mark-good` before the reboot doesn't cancel the update). X not running: only clears X's bad mark. |
  | `set-state X bad` | `rauc install` (target, before writing); `rauc status mark-bad` | X not running: adds X to `rauc_bad`, re-baselines on the running bank (cancels a pending boot into X). X running: switches to the other bank (FWU-accepted, no trial) — refused if the other bank is in `rauc_bad` or has no ext4 superblock on its rootfs (e.g. the empty `-b` bank of a freshly flashed board). |

  `rauc_bad` is a new U-Boot env variable (space-separated bootnames)
  owned by this script; U-Boot itself ignores it. Every change is
  written as a single `fw_setenv --script -` transaction, so power loss
  mid-update can't leave `bootcmd` and `altbootcmd` out of step.

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
9-and-10, in two different sessions. **Fixed** by
`0008-reset-distro_bootpart-around-scan_dev_for_boot_part.patch` —
see §3.7 for the full account, including a subtlety found while fixing
it (a stale value present when the loop *starts* also needs clearing,
not just one left behind when it ends).

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

   **Caveat: this change is not in either layer.** No U-Boot patch,
   env file or script in `meta-st-cargt`/`meta-cargt-stm32mp-addons`
   sets `boot_prefixes` from `${devnum}`; the only thing that sets it is
   ST's sample `boot.scr` (`meta-st-stm32mp/.../stm32mp-extlinux/boot.scr.cmd`,
   from `${boot_device}${boot_instance}`, which is correct whenever
   U-Boot itself was loaded from the device being booted). It was most
   likely only ever applied to a test board's persisted environment. It
   matters only for the "U-Boot from eMMC, Linux from SD card" case; the
   supported SD card configuration (boot straps set so U-Boot also comes
   from the SD card, below) works without it. If that mixed case is ever
   needed, carry it as a real U-Boot patch.

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
| `meta-cargt-stm32mp-addons` | Machine conf (`MACHINE_FEATURES += "rauc"`, `UBOOT_EXTLINUX_*`, `rauc.slot=A` default), `.wks.in` partition layout |
| manifest (`cargt-stm32mp2.xml`) | Pins `rauc/meta-rauc` as a layer dependency |

### 3.2 Key files (`meta-st-cargt`)

| File | Purpose |
|---|---|
| `conf/distro/cargt-openstlinux-weston.conf` | `DISTRO_FEATURES += "gplv3 rauc"` — makes RAUC available distro-wide (meta-rauc requires it). It does **not** by itself enable A/B: every A/B-conditional recipe/patch below gates on `COMBINED_FEATURES` containing `rauc`, i.e. this distro feature **and** `MACHINE_FEATURES += "rauc"` in the machine conf (§3.3) |
| `recipes-bsp/u-boot/u-boot-stm32mp/0006-stm32mpu-update-env-to-support-boot-A-B.patch` | Adds `altboot`/`altbootcmd` env vars to the stm32mp defconfig (ported from ST's `meta-st-ota`) |
| `recipes-bsp/u-boot/u-boot-stm32mp/0007-enable-bootcount-env-for-ab-rollback-safety.patch` | Disables the (confirmed-inert) `CONFIG_FWU_MULTI_BANK_UPDATE`, enables `CONFIG_BOOTCOUNT_LIMIT`/`CONFIG_BOOTCOUNT_ENV` — the actual rollback-safety mechanism (§2.5) |
| `recipes-bsp/u-boot/u-boot-stm32mp/0008-reset-distro_bootpart-around-scan_dev_for_boot_part.patch` | Fixes the autoboot partition-scan drift bug (§3.7) — clears `distro_bootpart` before and after `scan_dev_for_boot_part`'s loop |
| `recipes-bsp/trusted-firmware-a/tf-a-stm32mp/0002-add-logs-for-demo-purpose.patch` | NOTICE-level bank-selection logging, for visibility during bring-up (drop for production) |
| `recipes-bsp/u-boot/libubootenv/<machine>/fw_env.config` | A/B machines point at `/run/cargt-part/u-boot-env`, not `/dev/disk/by-partlabel/u-boot-env` (§2.4); other machines keep by-partlabel |
| `recipes-kernel/linux/linux-stm32mp/6.6/cargt_rauc_kernel_config_mods.config` | `CONFIG_BLK_DEV_LOOP`, `CONFIG_SQUASHFS`, `CONFIG_MD`, `CONFIG_BLK_DEV_DM`, `CONFIG_BLK_DEV_NBD`, `CONFIG_DM_VERITY`, `CONFIG_CRYPTO_SHA256` — required for RAUC's dm-verity bundle format; also `# CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED is not set` (§2.5's root cause #2) |
| `recipes-kernel/linux/linux-stm32mp/6.6/cargt_watchdog_hardening_kernel_config_mods.config` | `CONFIG_DETECT_HUNG_TASK` + `CONFIG_BOOTPARAM_HUNG_TASK_PANIC` + `CONFIG_WQ_WATCHDOG` (§3.8) — applied unconditionally, not RAUC-gated, since it benefits any board with a hardware watchdog armed |
| `recipes-kernel/linux/linux-stm32mp/6.6/0010-serial-stm32-fix-break_ctl-pm_runtime-race.patch`, `0012-bluetooth-btnxpuart-stop-ps-timer-work-before-close.patch` | The Bluetooth power-save race fix (`0012`) and its predecessor (`0010`, kept but not sufficient alone — see §3.8) |
| `recipes-core/rauc/rauc_%.bbappend` + `files/0001-support-bin-extension.patch` | Patches RAUC's `update_handler.c` so it accepts `*.bin` images as `raw` slot type (needed for the fip binary). Applied unconditionally (harmless without A/B) |
| `recipes-core/rauc/rauc-conf.bbappend` + `files/<machine>/system.conf`, `files/post-install.sh`, `files/st-boot-script.sh`, `files/ca.cert.pem` | The actual RAUC config + custom bootloader backend (§2.5) + post-install patching logic (§2.3) — `system.conf` is per-machine (only its `compatible=` line differs), one subdirectory per board. Only installed on A/B machines; others get meta-rauc's stock example config. `PACKAGE_ARCH = MACHINE_ARCH` |
| `recipes-core/fwu-gen-metadata/fwu-gen-metadata-v2.bb` + `files/update_metadata.sh` | Writes TF-A FWU metadata (v2 format) via `mkfwumdata`; fixed platform-wide UUIDs, not per-board |
| `recipes-core/bundles/update-st-bundle-stm32mp25-cargt-00395-02-00365.bb`, `update-st-bundle-stm32mp25-cargt-00395-01-00365.bb` | The bundle recipes, one per board (slots, compatible string, signing key/cert), each with `COMPATIBLE_MACHINE` restricted to its own board |
| `recipes-core/bundles/update-st-bundle-cargt-fip.inc` + `files/fip-install-hook.sh` | Shared by both bundle recipes: adds the per-panel FIPs to the bundle and the `fip` slot install hook that writes the one matching the running board (§3.4) |
| `recipes-core/systemd/cargt-device-symlinks_1.0.bb` | The `/run/cargt-part/` symlink service (§2.4) |
| `recipes-core/systemd/systemd-mount-partitions.bbappend` | Adds `-a` suffix to bootfs/vendorfs/rootfs in `MOUNT_PARTITIONS_LIST` (not userfs), A/B machines only |
| `recipes-core/udev/udev-extraconf_%.bbappend` + `files/cargt-ab-partitions.ignorelist` | Excludes A/B partitions (eMMC `mmcblk1p1`–`p11`, SD card `mmcblk0p1`–`p13`; §3.5) from udev's generic auto-mounter — without this, the automounter races RAUC for exclusive access to the inactive slot ("Device or resource busy") |
| `recipes-st/initrd/initrd-boot/0002-skip-first-boot-resize-for-fixed-size-ab-partitions.patch` | Skips `init-resize.sh`'s fsck/resize for `root*`/`vendor*`/`boot*` — those partitions are fixed-size, only `user*` needs it |
| `recipes-st/initrd/initrd-boot/0004-skip-userfs-resize-if-already-done.patch`, `0005-dont-mark-userfs-resized-from-the-initrd.patch` | `0004` gives `init-resize.sh`'s `userfs` case the same persistent-marker check as `resize-helper` (§3.6); `0005` stops it from also *writing* that marker, since it always runs first and was winning the race to mark the job done before `resize-helper.service`'s real SD card fix ever got a chance (§3.6) |
| `recipes-bsp/tools/resize-helper/0002-skip-fixed-size-ab-partitions.patch`, `0003-skip-userfs-resize-if-already-done.patch`, `0004-extend-userfs-gpt-partition-before-growing-it.patch` | Same idea for the other first-boot resize script; `0003` records a marker **on userfs itself** (not in `/etc`, which every OTA update reflashes) so the slow `e2fsck -c` bad-blocks pass only ever runs once; `0004` extends `userfs`'s GPT partition before growing it — the actual mechanical fix for the SD card `userfs`-stuck-at-200M bug (§3.6). All three are applied on A/B machines only — `0004` is written on top of `0003` and doesn't apply to the stock script |
| `recipes-cargt/images/cargt-image-dev.bb` / `cargt-image-weston.bb` | Installs `rauc rauc-conf fwu-gen-metadata-v2 u-boot-tools-stm32mp cargt-device-symlinks` and applies the A/B flashlayout splice (`cargt-rauc-ab-flashlayout.inc`) when `rauc` is in `COMBINED_FEATURES` |

### 3.3 Key config (`meta-cargt-stm32mp-addons`)

- `conf/machine/stm32mp25-cargt-00395-02-00365.conf`,
  `stm32mp25-cargt-00395-01-00365.conf` (same pattern, one per board):
  `MACHINE_FEATURES += "rauc"` (the per-board A/B switch, §3.2);
  `UBOOT_EXTLINUX_KERNEL_ARGS:append = " rauc.slot=A"` (build-time default);
  `UBOOT_EXTLINUX_ROOT:target-emmc/:target-sdcard` (literal device paths,
  §2.4 — partition numbers confirmed via a live partition table dump on
  each board, not assumed identical between them).
- `wic/sdcard-...-vendorfs-2GB.wks.in` (one per board): the partition
  table (§2.1). Its
  `u-boot-env` partition's `--part-name` must read `u-boot-env` (with the
  dash) to match both the actual eMMC layout and what
  `cargt-device-symlinks.sh`/`fw_env.config` look for — this drifted to
  `uboot-env` (no dash) at one point and silently broke the SD-card-side
  symlink for that one partition until caught by inspecting the built
  `.wic` file's partition table before the first SD card flash.

### 3.4 Bundle contents

`update-st-bundle-stm32mp25-cargt-00395-02-00365.bb` (the `-01-` recipe
is identical apart from the machine name):
- Slots (`RAUC_BUNDLE_SLOTS`): `fip`, `bootfs`, `vendorfs`, `rootfs` —
  each matching a `[slot.<name>.N]` class in `system.conf`.
- Compatible (`RAUC_BUNDLE_COMPATIBLE`): `cargt-stm32mp25-00395-02-00365`,
  which must equal `system.conf`'s `[system] compatible=` or RAUC refuses
  the bundle.
- Format: `verity` (dm-verity-hashed, per-slot).
- Sourced from `st-image-bootfs`, `st-image-vendorfs`, and
  **`cargt-image-dev`** for `rootfs` — hardcoded, including for boards
  whose factory image is `cargt-image-weston` (upstream reference
  material uses `st-image-weston`, which isn't the image built here).
  Slot filenames hardcode the distro name too.
- `fip` is the eMMC FIP (`...-optee-emmc.bin`); it is byte-identical to
  the `-sdcard.bin` build, so the same bundle serves both media. The slot
  image is the main (board-wide) variant. The bundle also carries
  `fip/fip-<dt>-optee-emmc.bin` for every other entry in the machine's
  `STM32MP_DT_FILES_EMMC` (the four per-panel `-glt*` DTs), added by
  `update-st-bundle-cargt-fip.inc`, so the panel list follows the
  machine conf.
- The `fip` slot has a RAUC `install` hook (`fip-install-hook.sh`,
  `RAUC_SLOT_fip[hooks] = "install"`) in place of RAUC's own raw write.
  It reads `/proc/device-tree/compatible` entry 0. On a per-panel board
  that is `cargt,<dtb basename>` (e.g.
  `cargt,stm32mp257f-cargt-00395-01-00365-glt0557201280is1`, the same
  string U-Boot derives `fdtfile` from), and the hook writes
  `fip/fip-<dtb basename>-optee-emmc.bin` to the inactive `fip` slot. If
  entry 0 isn't a `cargt,` name, or the bundle has no FIP for it (the
  board-wide DT has none under `fip/`), it writes the board-wide slot
  image instead. Either way it logs the chosen FIP to RAUC's journal
  (`fip-install-hook: writing fip-...bin to ...`). So a board flashed
  with a per-panel FlashLayout keeps its panel DT, panel, and touch
  across updates. This depends on the per-panel DTs' unique
  `cargt,<dtb>` first compatible; a board still running a DT without it
  falls back to the board-wide FIP, as every board did before the hook.
- `COMPATIBLE_MACHINE` restricts each bundle recipe to its own board.
- No bundle version is set and there is no downgrade protection.
- Signed with a development cert/key pair
  (`recipes-core/bundles/files/development-1.{key,cert}.pem`) verified
  against `/etc/rauc/ca.cert.pem` on target. **Replace both for
  production** — these are demo-only, checked into the layer.

### 3.5 udev automount exclusion

`cargt-ab-partitions.ignorelist` excludes eMMC `/dev/mmcblk1p1`–`p11`
and SD card `/dev/mmcblk0p1`–`p13` (the SD card's extra `fsbla1`/`fsbla2`
shift its numbering by 2) from the stock `udev-extraconf` automounter
(which otherwise mounts every filesystem-bearing partition under
`/run/media/`, active or inactive). `userfs` (eMMC p12, SD card p14) is
intentionally left mountable — it's not part of the A/B scheme and isn't
auto-mounted by anything else anyway. Installed only on A/B machines;
`udev-extraconf` is therefore `MACHINE_ARCH`.

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

**A second, more serious instance of this same bug class was found later**
(via live serial console on `00395-01-00365`, after its first-ever OTA
install into bank B repeatedly failed to boot — see below): `init-resize.sh`
itself still had exactly the unprotected `userfs` case this section
originally believed only affected the (harmless, sub-second)
`resize-helper` path. Its own "already resized" guard
(`$ROOTFS_DIR/etc/.resized`) lives inside whichever rootfs is currently
booting, gating the *entire* loop — so while `root`/`vendor`/`boot` are
correctly no-ops now (§ above), `userfs`'s full
`e2fsck -f -y -c -C 0` bad-blocks scan (plus a second `e2fsck` pass and
`resize2fs`, from `0001`/`0003`) still ran unconditionally on every fresh
bank's first boot, because a freshly OTA-installed rootfs has never had
the chance to create that marker. Unlike `resize-helper`'s cheap
`systemd-growfs` path, this one *is* the expensive, unconditional
bad-blocks scan, running in the initramfs before systemd or the kernel's
own watchdog userspace handling is active.

Confirmed on hardware: against `00395-01-00365`'s ~22GB `userfs`, the scan
was still at ~8% after 24 seconds (full run: several minutes) — long
enough that OP-TEE's own watchdog (`stm32_iwdg`) panicked and reset the
SoC mid-scan, every time, before Linux userspace or `systemd-journald`
ever started. This looked identical to an unexplained early-boot hang
from the OS side (no journal entry, no pstore record — `journalctl
--list-boots` showed only the *final* boot, with none of the three failed
attempts in between), and was only root-caused by moving a live serial
cable onto the affected board and watching a boot attempt directly.
U-Boot's rollback-safety mechanism (§2.5) correctly treated this as
"bank B keeps failing to boot" and fell back to bank A after `bootlimit`
(3) attempts — itself a good sign that rollback safety generalizes
correctly, but masking a real, separate defect in the resize path.

**Fixed** (`0004-skip-userfs-resize-if-already-done.patch`): give
`init-resize.sh`'s `userfs` case the exact same persistent-marker
protection `resize-helper`'s own `0003` patch already established —
mount the `userfs` device long enough to check for
`.resize-helper-done` at its root (the same file, since `/usr/local` is
exactly where `userfs` is later mounted), skip the scan entirely if
present, and write the marker there after resizing if this script is the
one that ends up doing it (so a board's very first boot doesn't depend
on `resize-helper.service` running afterward to set it). Confirmed on
hardware, both boards: after rebuilding and re-installing, `00395-01-00365`
booted bank B successfully on the first attempt (serial log shows a
single `SKIP USERFS [...] (already resized)` line in place of the scan),
and the A→B→A round trip now completes cleanly both directions.
`00395-02-00365` was rebuilt and re-tested with the same fix as a
precaution — it had not been observed to hit this failure (a faster eMMC
and/or smaller `userfs` may have kept it under the watchdog timeout by
chance), but the underlying bug was equally present there before this
fix, and the fix doesn't change behavior on the already-working board.

**A third, unrelated `userfs` bug specific to the SD card build was found
later, once the two fixes above let a fresh SD card boot far enough to
actually observe it: `userfs` stayed stuck at its built 200M size
forever, no matter how many times either resize script ran or how
successfully either reported.** Root cause: on the SD card build,
`userfs` is created as a small, fixed-size GPT partition (200M — see the
`.wks.in`, §2.1), with the rest of the card deliberately left
unpartitioned for `userfs` to grow into later. `resize2fs` and
`systemd-growfs` both only ever grow a filesystem to fill its *existing*
partition boundary — neither one ever touches the GPT partition table
itself — so without an explicit partition-table extension first, neither
had anything to grow into. eMMC never hits this: its flashlayout sizes
`userfs` to consume the whole remaining capacity directly at flash time,
so there's normally no free space left after it for this to matter.

Fixed in two parts, both required together:

1. **The actual mechanical fix, in `resize-helper.sh`**
   (`0004-extend-userfs-gpt-partition-before-growing-it.patch`): before
   calling `systemd-growfs`/`resize2fs`, extend the `userfs` GPT
   partition table entry to consume the rest of the disk — delete and
   recreate it with the same start sector, type GUID, unique GUID, and
   name (only the end boundary moves, so nothing about how the partition
   is identified changes), then tell the running kernel about the new
   size via `resizepart` (falling back to `partprobe`). Guarded to only
   ever act when `userfs` is genuinely the last partition on the disk
   with real free space after it — a safe no-op on eMMC. Also handles a
   real gotcha: an image `dd`'d onto a physically larger card than it was
   built for leaves the GPT backup header (and the primary header's own
   recorded "last usable sector") still reflecting the original, smaller
   image size until `sgdisk -e` runs once — without that, the free space
   after the last partition isn't visible to `sgdisk` at all and the
   extend silently does nothing.
2. **Why the fix above didn't take effect at first, in `init-resize.sh`**
   (`0005-dont-mark-userfs-resized-from-the-initrd.patch`): this earlier,
   initrd-stage script always runs *before* `resize-helper.service`, and
   was unconditionally writing the shared `.resize-helper-done` marker
   right after its own `resize2fs` attempt — regardless of whether that
   attempt actually grew anything (it can't, on SD card, without fix #1
   above). By the time `resize-helper.service` ran later and checked the
   same marker, it saw "already done" and skipped its entire resize
   block, including the new extend logic — permanently losing the race
   on every single boot, since this script always runs first. Fixed by
   no longer writing the marker from `init-resize.sh`; its own
   fsck+resize2fs attempt is left in place unchanged (still useful on
   eMMC), but only `resize-helper.service` — the only script that can
   actually verify, and on SD card ensure, the marker is true — sets it
   now.

Root-caused via a debug line added to `resize-helper.service` printing
marker state at its very first line (confirmed: already `1` on a
completely fresh boot, before `resize-helper` had done anything at all)
and by directly extracting the built `.wic` image's `userfs` partition
region and reading it with `debugfs` (confirmed: the marker is not baked
into the image itself — it really is written live, this early, only by
`init-resize.sh`). **Verified on hardware, both DUTs**: a completely
fresh SD card write now grows `userfs` from 200M to ~21GB automatically
on first boot, no manual intervention.

### 3.7 Fixed: autoboot partition scan drifted to the wrong partition

**Found during rollback-safety testing and fixed by
`0008-reset-distro_bootpart-around-scan_dev_for_boot_part.patch`
- flagging clearly since it affected normal automatic booting, not just
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
never reset - only `devplist` was cleared (`"setenv devplist\0"`) at the
end of that macro; `distro_bootpart` itself was left holding whatever
the last scan attempt computed. Once a stale value gets written to the
persisted environment (e.g. via this board's `env_check` autosave, or an
explicit `saveenv` during interactive debugging), it survives power
cycles and gets pushed further by the A/B `+1` adjustment (`if test
${altboot} = 1; then setexpr distro_bootpart ${distro_bootpart} + 1;
fi;`) applied on top of an already-wrong base, drifting the "selected"
partition further from the real bootfs partitions (6/7) with each
affected boot - observed landing on 8 in one session, then 9-and-10 in
a later one, with `devplist` independently confirmed correct (`6 7`)
throughout.

An important subtlety found while fixing this: clearing
`distro_bootpart` only at the *end* of the loop (guarding the *next*
scan) is not sufficient by itself. A stale value already present when
the loop *starts* gets used as-is for the very first iteration instead
of `${devplist}`'s real first element - reproduced even on a single,
otherwise-correct scan with `devplist` verified correct throughout. The
loop needs a clean slate on entry too, not just a guarantee that it
leaves one behind.

**Fix**: `distro_bootpart` is now cleared both immediately before the
loop starts and after it ends, so every invocation of
`scan_dev_for_boot_part` computes it fresh from `${devplist}` on its
very first iteration regardless of what either variable held on entry.
Confirmed on hardware with a rigorous before/after test: deliberately
persisted a stale `distro_bootpart` (`setenv distro_bootpart 99;
saveenv`) followed by a genuine hard `reset` reliably reproduced the
wrong-partition scan with only the end-of-loop clear in place; adding
the before-the-loop clear and repeating the identical test resulted in
a fully correct boot, verified through the real build pipeline (not
just a live interactive env edit) by rebuilding `u-boot-stm32mp` and
`fip-stm32mp` from the patched source and redeploying before retesting.

Workaround if an unpatched device gets stuck at the U-Boot prompt from
this: a fully manual boot (`ext4load` the kernel/dtb/initrd from the
correct bootfs partition directly, set `bootargs` by hand, then
`booti`) reliably recovers the device without needing a reflash.

### 3.8 Fixed: Bluetooth power-save race could wedge the whole system

**Not a RAUC-specific bug — found during unrelated overnight eMMC A/B
soak testing, but significant enough (and general enough) to record
here alongside the other kernel/driver fixes this project produced.**
Both DUTs independently hung during ~7 hours of otherwise unremarkable
A/B cycling, with no Bluetooth-specific activity in progress on either.
Symptoms: the board stayed fully reachable over the network — ping,
TCP, even SSH authentication all worked — but no new process could ever
be forked; an already-open serial console session kept working for a
while before it, too, stopped responding.

**Root cause, found via live serial console (a spare shell that hadn't
yet tried to fork anything survived long enough to investigate)**: a
synchronous external abort in `stm32_usart_break_ctl` (the STM32 UART
driver), triggered by `btnxpuart` (the NXP Bluetooth driver)'s
power-save workqueue calling `serdev_device_break_ctl()` on a port that
was concurrently being (or had already been) closed — hitting an
unclocked peripheral inside a spinlock-protected critical section. The
faulting task is killed without ever reaching the matching unlock,
which wedges every later user of that same lock (most importantly the
port's own IRQ handler), and eventually the whole system once enough
kworkers pile up stuck behind it. `btnxpuart_close()` tears down the
port without first stopping its own independent power-save
timer/workqueue, so a concurrent `ps_work_func()` can still fire on a
port that's already (or about to be) unclocked by close — and since
that timer/work item runs off the ordinary kernel timer/workqueue,
completely decoupled from the HCI device's own open/close lifecycle,
this can happen on **any** ordinary Bluetooth power-cycle (rfkill,
`bluetoothd` restart, `hciconfig hciN down`, suspend/resume), not just
module unbind — `nxp_serdev_remove()` already stops the timer/work
correctly before tearing down the port, but that synchronization was
missing from the far more commonly exercised `close()` path.

An existing patch on this port, `0010-serial-stm32-fix-break_ctl-pm_runtime-race.patch`
(already present before this bug was found), turned out **not** to
prevent this: it makes `stm32_usart_break_ctl()` use the blocking
`pm_runtime_resume_and_get()` instead of the non-blocking variant, on
the theory that an async pm_runtime resume was racing the register
write — but this port's `pm_runtime` callbacks never actually gate its
peripheral clock at all; a completely separate `.pm`/`uart_close()` path
does that. The fix is kept (it's a real, harmless correctness
improvement for a different, largely dormant edge case) but was not
what closed this bug.

**Fixed** (`0012-bluetooth-btnxpuart-stop-ps-timer-work-before-close.patch`):
make `btnxpuart_close()` stop the power-save timer and cancel its
workqueue item — via `timer_delete_sync()`/`cancel_work_sync()`, not
`nxp_serdev_remove()`'s own `ps_cancel_timer()`/`ps_cleanup()`, which
permanently retire the timer/mutex for the rest of the device's
lifetime and would silently break Bluetooth power-save forever after
the first close/reopen if reused here — before tearing down the port.
Mainline `drivers/bluetooth/btnxpuart.c` has the same gap as of this
writing; this is a generic driver bug, not board-specific, carried here
until (if) it lands upstream.

**Also added, as defense-in-depth, not tied to this specific bug**:
`CONFIG_DETECT_HUNG_TASK` + `CONFIG_BOOTPARAM_HUNG_TASK_PANIC`
(timeout raised to 600s, from the 120s default, to avoid false-positiving
on the legitimate one-time first-boot `userfs` bad-blocks scan discussed
in §3.6). The reason the hardware watchdog never caught this hang on its
own: once systemd opens `/dev/watchdog` and starts feeding it from its
own main event loop, that loop has no dependency on whatever gets stuck
elsewhere in the kernel, so it keeps petting the watchdog indefinitely
while a completely unrelated subsystem silently deadlocks — the
watchdog only verifies "is whoever holds this device still alive," not
"is the whole system healthy." A confirmed stuck task now escalates
into a real kernel panic after the timeout, which *does* stop systemd's
watchdog-feed loop, letting the already-armed hardware watchdog fire and
actually recover the board. No U-Boot changes are needed for this:
`bootcount`/`bootlimit` (§2.5) are only ever tracked while
`upgrade_available=1` (an active RAUC trial), so a watchdog reset during
ordinary operation has no effect on A/B rollback bookkeeping.

**Verified on hardware, both boards**: 30 (then 100) rapid `hciconfig
hci0 down`/`up` cycles — deliberately targeting the exact
close-vs-power-save-workqueue race — produced zero external aborts and
zero stuck kworkers on either board, both remaining fully responsive
throughout. Not yet verified under longer-duration/overnight soak
conditions — the original failures took hours of incidental Bluetooth
activity to manifest, so this stress test is strong evidence but not a
full replacement for that.

## 4. Examples

### 4.1 Build

bitbake must run inside the `crops/poky:ubuntu-22.04-yocto-pkgs`
container on build hosts newer than Ubuntu 22.04 (e.g. via
`/yocto/run-docker-ai.sh`):

```sh
/yocto/run-docker-ai.sh /mnt/build1/cln-mp2-ip \
  'source layers/openembedded-core/oe-init-build-env build && \
   bitbake cargt-image-dev update-st-bundle-stm32mp25-cargt-00395-02-00365'
```
`MACHINE` must be the board the bundle is for (the bundle recipes carry
`COMPATIBLE_MACHINE`). The bundle recipe depends on its slot images, so
building it alone also builds them. It lands in
`tmp-glibc/deploy/images/<machine>/update-st-bundle-<machine>-<machine>.raucb`
(a timestamped copy sits next to it).

### 4.1a Initial flash

The A/B layout is a different partition table, so a board still on the
single-bank layout **cannot** be converted by OTA — flash it once:
- eMMC: STM32CubeProgrammer with the patched
  `FlashLayout_emmc_<CUBEMX_DTB>-optee.tsv` (the main variant) or a
  per-panel `-glt*` one — all of them are spliced to A/B.
- SD card: the `.wic` / `.wic.bmap` from the same deploy directory.

The `-b` bank starts empty (eMMC) or as a copy of `-a`'s FIP only (SD
card); the first `rauc install` fills it.

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
rauc status --detailed                 # read-only: never accepts/disarms anything
rauc status mark-good                  # accept the running (trial) bank
rauc status mark-bad other             # cancel a pending, not-yet-booted install
rauc status mark-bad booted            # switch to the other bank on next boot
rauc status mark-active other          # make the other bank primary (arms a trial)
/usr/lib/rauc/st-boot-script.sh get-primary      # bank the next boot lands on
/usr/lib/rauc/st-boot-script.sh get-state B      # good | bad
fw_printenv bootcmd altbootcmd upgrade_available bootcount bootlimit rauc_bad
```
`get-primary` reports the bank U-Boot will boot next, not the one
currently running (that's `rauc.slot=` on `/proc/cmdline`, or `booted:`
in `rauc status`). Right after `rauc install` it already names the new
bank. `rauc_bad` lists banks that failed a trial boot, were marked bad
by hand, or were left half-written by an interrupted install.

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
  handler, so start there. If `bootcmd` names the new bank but the board
  came back on the old one, check `bootcount` against `bootlimit` and
  `rauc_bad`: the new bank failed its trial and U-Boot fell back (§2.5).
- **Build fails with `rauc-conf` unable to find `<machine>/system.conf`,
  or a single-bank board comes up looking for `bootfs-a`**: A/B gating
  is off for that machine or wrongly on. Everything A/B-specific keys off
  `COMBINED_FEATURES` containing `rauc` — check
  `bitbake -e <recipe> | grep ^COMBINED_FEATURES=` and the machine conf's
  `MACHINE_FEATURES += "rauc"`. See "Enabling A/B on another machine"
  below.
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

### 4.6 Enabling A/B on another machine

Everything A/B-specific keys off `COMBINED_FEATURES` containing `rauc`
(`DISTRO_FEATURES` "rauc" from the distro **and** `MACHINE_FEATURES`
"rauc" from the machine conf), so a machine without it keeps its stock
single-bank layout even when built with this distro. To add a board:

1. Machine conf: `MACHINE_FEATURES += "rauc"`,
   `UBOOT_EXTLINUX_KERNEL_ARGS:append = " rauc.slot=A"`, per-target
   `UBOOT_EXTLINUX_ROOT` (literal `/dev/mmcblkNpM` of `rootfs-a` — check
   the real partition numbers on each medium), rootfs/vendorfs/bootfs
   sizes that fit twice (§2.1).
2. `.wks.in` with the `-a`/`-b` partitions (§2.1); `rootfs-b` must
   immediately follow `rootfs-a` (post-install.sh relies on it).
3. `recipes-core/rauc/files/<machine>/system.conf` with a unique
   `compatible=`.
4. `recipes-bsp/u-boot/libubootenv/<machine>/fw_env.config` pointing at
   `/run/cargt-part/u-boot-env`.
5. A bundle recipe with matching `RAUC_BUNDLE_COMPATIBLE`, slot
   filenames and `COMPATIBLE_MACHINE`.
6. Check `cargt-ab-partitions.ignorelist` covers that board's A/B
   partition numbers on each medium.
7. Optional (hawkBit, §5): a `config.conf.<board>` and matching
   `SRC_URI`/`do_install` override in `rauc-hawkbit-updater_%.bbappend`.

Recipes whose content now depends on the machine because of this gating
(`udev-extraconf`, `systemd-mount-partitions`, `resize-helper`,
`initrd-boot`, `rauc-conf`) are `PACKAGE_ARCH = "${MACHINE_ARCH}"`, so
A/B and single-bank boards built in one tree don't share a package.
`initrd-boot` inherits `allarch`, which force-sets `PACKAGE_ARCH` from an
event handler, so its bbappend overrides it from a second handler. The
U-Boot patches `0006`–`0008` stay unconditional: without an armed trial
(`upgrade_available=0`) they don't change boot behavior.

## 5. hawkBit Pull-Based OTA Testing (Optional)

Everything above uses manual push testing (`scp` a bundle, `rauc install`
over SSH). `rauc-hawkbit-updater` (in `recipes-support/`) adds the pull
counterpart: a hawkBit server assigns a distribution set to a target, the
device polls, downloads, and installs automatically. This is testing
infrastructure only — the server is a plain Docker container on a dev
machine, not anything production. `recipes-support/rauc-hawkbit-updater/files/config.conf.*`
ships with placeholder `hawkbit_server`/`auth_token` values; follow this
section to fill in your own.

### 5.1 Stand up the server

```bash
cd docs/hawkbit && docker compose up -d
```

The server's Management/DDI REST API comes up on `:8083`; the browsable
management UI (separate container, talks to the same server) on `:8088`,
login `admin`/`admin`. **The server must be reachable from the DUTs** — bind/
publish on this machine's real LAN IP, not `127.0.0.1`.

This image doesn't ship the Vaadin management UI bundled into the main
server container (older hawkBit versions did) — that's why it's a second
container. The `hawkbit-ui` one only needs `hawkbit.server.mgmtUrl` pointed
at the main server's internal Docker-network address, not the host's.

### 5.2 Register each DUT as a target

```bash
curl -s -X POST http://<server-ip>:8083/rest/v1/targets \
  -u admin:admin -H 'Content-Type: application/json' \
  -d '[{"controllerId": "<MACHINE>", "name": "<friendly name>", "description": "..."}]'
```

The response's `securityToken` field is the `auth_token` value for that
board's `config.conf.*`. `controllerId` must exactly match `target_name`
in the config — this project uses the board's `MACHINE` name.

You can also supply your own `securityToken` in the request body instead
of letting the server generate one (add `"securityToken": "<32 hex
chars>"` to the object above) — useful if you ever need to recreate a
target and want it to match a value already baked into a board's
`config.conf`, without touching the board again. §5.5's automated stress
test relies on exactly this to re-register targets after a reset.

By default hawkBit's DDI API doesn't accept per-target tokens at all
(`authentication.targettoken.enabled` defaults to `false`) — enable it once,
server-wide:

```bash
curl -s -X PUT http://<server-ip>:8083/rest/v1/system/configs/authentication.targettoken.enabled \
  -u admin:admin -H 'Content-Type: application/json' -d '{"value": true}'
```

### 5.3 Push an update

```bash
# 1. Software module (one .raucb per version)
SM_ID=$(curl -s -X POST http://<server-ip>:8083/rest/v1/softwaremodules \
  -u admin:admin -H 'Content-Type: application/json' \
  -d '[{"name": "cargt-image-dev", "version": "<version>", "type": "os"}]' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")

# 2. Upload the bundle as that module's artifact
curl -s -X POST http://<server-ip>:8083/rest/v1/softwaremodules/$SM_ID/artifacts \
  -u admin:admin -F "file=@update-st-bundle-<machine>.raucb;filename=bundle.raucb"

# 3. Distribution set wrapping that module
DS_ID=$(curl -s -X POST http://<server-ip>:8083/rest/v1/distributionsets \
  -u admin:admin -H 'Content-Type: application/json' \
  -d "[{\"name\": \"<name>\", \"version\": \"<version>\", \"type\": \"os\", \"modules\": [{\"id\": $SM_ID}]}]" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")

# 4. Assign - this is what actually triggers the device's next poll to act
curl -s -X POST http://<server-ip>:8083/rest/v1/distributionsets/$DS_ID/assignedTargets \
  -u admin:admin -H 'Content-Type: application/json' \
  -d '[{"id": "<controllerId>"}]'
```

The device notices on its next poll (`retry_wait` in `config.conf`, default
60s), downloads, installs via RAUC's D-Bus API, and — since
`post_update_reboot = true` — reboots into the new slot on its own. No
manual `rauc install`/reboot needed once this is wired up correctly.

### 5.4 Target attributes (hostname / firmware version)

`update-device-attrs.sh` (an `ExecStartPre` on the service) refreshes the
config's `[device]` section with the live hostname (a unique per-board
identifier, machine name + MAC address) and the current build's
`/etc/ota-demo-version` marker on every start, so both show up as target
attributes in the UI. hawkBit only *pushes* attributes to the server on
demand, though — not on every poll. If they look stale, re-request them:

```bash
curl -s -X PUT http://<server-ip>:8083/rest/v1/targets/<controllerId> \
  -u admin:admin -H 'Content-Type: application/json' -d '{"requestAttributes": true}'
```

**Verified on hardware, both DUTs**: 3 consecutive fully-automatic
hawkBit-driven update cycles each (alternating A→B→A→B slots correctly
every time), no manual intervention required once the bootloader
activation fix (see this repo's commit history) and the config's `[device]` section were both in
place. (That verification predates the backend rework in §2.5: the
"activation fix" was likely compensating for the old `get-state` resetting
`bootcmd` whenever hawkBit's D-Bus status query ran — repeat it on the
reworked backend.)

### 5.5 Extended stress testing

`docs/hawkbit/weekend-stress-test.sh` runs the same cycle continuously and
unattended for as long as you let it: rebuild, bundle, push via hawkBit,
wait for auto-install+reboot, verify the slot/boot-status, repeat - for
both DUTs, alternating, indefinitely. Fill in `BUILD_DIR`/`OE_INIT`/
`DUT_IP`/`DUT_TOKEN` at the top for your setup and run it in a `tmux`
session (or similar) so it survives your terminal closing; stop it any
time with `touch <same directory>/STOP`.

It self-disables a DUT after 3 consecutive failures (rather than hammering
a possibly-stuck board indefinitely) and automatically resets the whole
hawkBit stack once its artifact store passes 5GB - hawkBit's Management
REST API only soft-deletes old software modules/artifacts (the DB row is
hidden, but the uploaded bundle file is never actually freed from disk),
so a long-running test needs this or the artifact store grows without
bound until performance degrades and installs start timing out. The reset
re-registers both targets with the same fixed tokens already in each
board's `config.conf`, so the DUTs never need reconfiguring.

**Verified on hardware, both DUTs**: 110+ consecutive PASS cycles with zero
failures over roughly 18 hours once the fixes above were in place (host
key handling, `files-local/` config override, and the artifact-store
reset), with 7 automatic resets happening transparently mid-run.
(Also run on the pre-rework backend — §2.5.)

**Rollback-safety testing added and verified on hardware, both DUTs**: the
script now also runs a rollback-safety test every 4th cycle per DUT -
deliberately corrupts the currently-inactive slot's init, forces a boot
into it via RAUC's own bootloader backend, and confirms the platform's
bootcount/watchdog logic automatically falls back to the previous good
slot with no RAUC/userspace involvement. A second overnight run (~15
hours, 109+ consecutive PASS, 0 failures) with this enabled caught two
real bugs the original soak test never exercised, since it never
deliberately broke a boot:

- A reboot-time kernel crash: `rauc-hawkbit-updater`'s `post_update_reboot`
  calls the raw `reboot(2)` syscall directly (it holds
  `AmbientCapabilities=CAP_SYS_BOOT` for exactly this), bypassing systemd's
  graceful shutdown - so `weston` was still alive and submitting GPU
  commands the instant `device_shutdown()` tore down the out-of-tree
  Vivante `galcore` driver, oopsing it and then `weston` itself a moment
  later. `kernel_restart()` never completed; the board sat in a
  half-torn-down state until forced back with a raw `sysrq` reboot. Fixed
  by stopping `weston-graphical-session.service` synchronously in
  `post-install.sh`, before control returns to whatever triggers the
  reboot afterward (see that file's module docstring).
- `meta-cargt-stm32mp-addons` mainline (`scarthgap`) was missing
  `MACHINE_FEATURES += "rauc"`, so the entire custom RAUC backend
  (`st-boot-script.sh`, the mark-good service, the `/run/cargt-part/`
  device symlinks) silently never got installed - `rauc` itself still
  "worked" via its own generic fallback config (raw bundle copying doesn't
  need the custom backend), masking the gap until `rauc status`/mark-good
  were actually exercised. Fixed by merging the already-prepared
  `feature/rauc-support` branch (which had this and the full A/B partition
  layout) forward onto current `scarthgap`.

Once both fixes were applied and both DUTs freshly reflashed, the rerun
passed 12+ rollback-safety tests per DUT with zero failures, validating
the backend-rework + per-machine A/B gating item below on real hardware
for the first time.

### 5.6 Drag-and-drop single-board updates (no hawkBit)

For pushing one `.raucb` bundle to one bench-top board without standing
up hawkBit or scripting the REST calls in §5.3, `rauc-web-updater`
(`recipes-support/rauc-web-updater/`) is a standalone recipe that installs
a tiny web page on the board itself, listening on port 8080:

```
http://<dut-ip>:8080/
```

Drop a `.raucb` file onto the page (or click to browse), and it uploads,
runs `rauc install` synchronously, and shows the install log plus a
"Reboot now" link on success - it deliberately doesn't reboot on its own,
so whoever just dropped a bundle gets to see the result first. The same
flow works from a script via curl:

```bash
curl -s -X POST -F "bundle=@my-update.raucb" http://<dut-ip>:8080/upload
curl -s http://<dut-ip>:8080/reboot   # once you're happy with the log
```

Like `rauc-hawkbit-updater`, it's wired into `cargt-image-dev` only (same
`COMBINED_FEATURES` rauc gate), not the production weston image, and it's
unauthenticated by design - a dev/lab convenience for one board at a time
on a trusted network, not a fleet-management tool. See the script's own
docstring for the reasoning.

**Verified on hardware** (`stm32mp25-cargt-00395-02-00365`): page load,
curl-simulated upload+install (full install log returned, slot updated),
`/reboot` trigger, clean reboot with the slot flipped and boot status
good.

## Testing status

- **Backend rework (`set-state`, read-only `get-state`/`get-primary`,
  `rauc_bad`, single-transaction env writes) and per-machine A/B gating
  (`MACHINE_FEATURES += "rauc"` / `COMBINED_FEATURES`): VERIFIED ON
  HARDWARE, both DUTs** — see §5.5's rollback-safety testing writeup.
  12+ A→B→A round trips and 12+ rollback-sabotage tests per DUT, all
  PASS, `rauc status` confirmed not to disturb `upgrade_available`/
  `bootcount` across repeated queries. Getting a clean hardware run
  required fixing two bugs the gating itself had been masking (missing
  `MACHINE_FEATURES += "rauc"` on `meta-cargt-stm32mp-addons` mainline,
  and an unrelated reboot-time kernel crash) - see §5.5 for both.
  Earlier verification before this: the backend's state transitions in a
  host-side simulation (fake `fw_printenv`/`fw_setenv`: install, manual
  mark-good before reboot, successful trial, failed trial + fallback,
  mark-bad booted with and without a bootable other bank); bitbake parse
  of the gated variables for `00395-02-00365` (A/B) and
  `00395-00365v3` (single-bank).

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
- **`init-resize.sh` userfs bad-blocks scan re-running on every fresh
  bank: found and fixed.** See §3.6. Root-caused via live serial console
  on `00395-01-00365`: a full multi-minute `e2fsck -c` bad-blocks scan of
  `userfs` re-ran on every OTA update's first boot into a freshly-installed
  bank (the script's own marker lives inside the rootfs being booted, not
  on `userfs`), long enough to trip OP-TEE's watchdog and reset the SoC —
  three times, before U-Boot's rollback logic correctly fell back to the
  previous good bank. Fixed with the same persistent-userfs-marker pattern
  already used by `resize-helper` (`0004-skip-userfs-resize-if-already-done.patch`).
  Confirmed on hardware: `00395-01-00365` now completes an A→B→A round
  trip cleanly, first attempt each direction; `00395-02-00365` rebuilt and
  re-tested with the same fix as a precaution, no regression.
- **`00395-01-00365` brought up to full A/B RAUC parity with
  `00395-02-00365`:** PASS. Same partition layout (`.wks.in` for both SD
  card variants), machine conf (`rauc.slot`, `UBOOT_EXTLINUX_ROOT` for
  both eMMC and SD card), per-machine `system.conf`, dedicated bundle
  recipe, and the same `/run/cargt-part/`-scoped `fw_env.config` fix
  `00395-02-00365` already had. Confirmed via live reflash and testing:
  initial bring-up flawless, A→B→A round trip PASS after the userfs-resize
  fix above (the only real defect found was the one described there, not
  specific to this board's partition layout itself).
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
    across boots) was found and fixed with a real patch
    (`0008-reset-distro_bootpart-around-scan_dev_for_boot_part.patch`,
    see §3.7) — this was blocking automatic retries, not a
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
  - **Repeated and confirmed on `00395-01-00365`** (same sabotage
    method: bank B's `root=` pointed at a nonexistent partition):
    live serial console captured a real `Panic 'Watchdog'` during a
    failed Boot B attempt and `Bootlimit (3) exceeded. Using
    altbootcmd`, and the board fell back to bank A with `bootcmd`/
    `altbootcmd` resynced and `bootcount`/`upgrade_available` cleared —
    same result as the primary board. After restoring the correct
    `root=` value, bank B booted cleanly again on the very next
    attempt, confirming the sabotage/recovery cycle leaves no lasting
    damage.
- **btnxpuart Bluetooth power-save race causing a full system wedge:
  found and fixed.** Both DUTs independently hung during ~7 hours of
  otherwise unremarkable eMMC A/B soak testing - no Bluetooth-specific
  activity in progress on either. Root-caused via live serial console:
  a synchronous external abort in `stm32_usart_break_ctl`, called from
  `btnxpuart`'s power-save workqueue racing the port being closed -
  see the patch (`0012-bluetooth-btnxpuart-stop-ps-timer-work-before-close.patch`)
  for the full mechanism. Confirmed the existing `0010` pm_runtime fix
  did not prevent this: it manages a PM path that never actually gates
  this port's clock. Also added `CONFIG_DETECT_HUNG_TASK` +
  `CONFIG_BOOTPARAM_HUNG_TASK_PANIC` (timeout raised to 600s to avoid
  false-positiving on the legitimate first-boot userfs resize scan) so
  a future localized deadlock of this general shape reaches the
  hardware watchdog automatically instead of silently persisting for
  the rest of the system's uptime - confirmed no U-Boot changes are
  needed for this, since `bootcount`/`bootlimit` are only ever tracked
  while `upgrade_available=1` (an active RAUC trial), so a watchdog
  reset during ordinary operation has no effect on A/B rollback
  bookkeeping.

  **Fix verified on both boards** after a physical power cycle and
  reflash: 30 rapid `hciconfig hci0 down`/`up` cycles (deliberately
  targeting the exact close-vs-power-save-workqueue race) produced zero
  external aborts and zero stuck kworkers on either board, both
  remaining fully responsive throughout. Not yet verified under
  longer-duration/overnight soak conditions - the original failures
  took hours of incidental Bluetooth activity to manifest, so this
  stress test is strong evidence but not a full replacement for that.
- **Autoboot partition-scan drift: PASS (fixed).** See §3.7 — a real
  patch (`0008-reset-distro_bootpart-around-scan_dev_for_boot_part.patch`)
  now clears `distro_bootpart` both before and after
  `scan_dev_for_boot_part`'s loop. Confirmed on hardware through the
  real build pipeline (not just a live env edit): deliberately
  persisted a stale `distro_bootpart=99` and did a genuine hard reset —
  reproduced the bug with only an end-of-loop clear in place, then
  passed cleanly once the before-the-loop clear was added too.
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
- **SD card `userfs` resize: found and fixed (two real bugs, both now
  closed).** `userfs` was stuck at its built 200M size on every fresh SD
  card flash, on both boards, despite the e2fsck-twice fix and multiple
  earlier attempted fixes. Root-caused in two layers:
  1. **The actual mechanical fix**: `userfs`'s GPT partition itself is a
     fixed 200M entry on the SD card build (see the `.wks.in`), with the
     rest of the card left genuinely unpartitioned — `resize2fs`/
     `systemd-growfs` only ever grow a filesystem to fill its *existing*
     partition boundary, never the partition table itself, so neither had
     anything to grow into. Fixed in `resize-helper.sh`: extend the GPT
     partition (same start sector/GUIDs/name, only the end boundary
     moves, guarded to only ever act when `userfs` is genuinely the last
     partition with real free space after it — a safe no-op on eMMC,
     which is already sized to fill the disk at flash time) before
     calling `systemd-growfs`/`resize2fs`.
  2. **Why that fix didn't take effect at first**: `init-resize.sh` (the
     *earlier* initrd-stage resize script, patched previously to
     check/write a marker shared with `resize-helper.service`) always
     runs first and was unconditionally writing that marker after its
     own `resize2fs` attempt — regardless of whether that attempt
     actually grew anything (it can't, on SD card, without fix #1). By
     the time `resize-helper.service` ran later and checked the same
     marker, it saw "already done" and skipped its entire resize block,
     including the new extend logic — permanently losing the race on
     every single boot. Root-caused by adding a debug line to
     `resize-helper.service` printing marker state at its very first
     line (confirmed: already `1` on a completely fresh boot, before
     `resize-helper` had done anything) and by directly extracting the
     built `.wic` image's `userfs` partition region and reading it with
     `debugfs` (confirmed: the marker is not baked into the image
     itself — it's written live, this early, only by `init-resize.sh`).
     Fixed by no longer writing the marker from `init-resize.sh`; only
     `resize-helper.service` (the only script that can actually verify,
     and on SD card ensure, it's true) sets it now.

  **Verified on hardware, both DUTs**: a completely fresh SD card write
  now grows `userfs` from 200M to ~21GB automatically on first boot, no
  manual intervention — `"Extending /dev/mmcblk0p14 ... to use 46392421
  free sectors"` followed by the real incremental ext4 resize
  progression, both now visible in the boot log where before this fix
  neither ever ran.

This section reflects the state as of the most recent test session; keep
it in sync as further testing lands.
