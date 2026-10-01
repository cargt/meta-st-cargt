#!/bin/bash
# Continuous hawkBit-driven RAUC A/B update stress test.
# Cycles both DUTs sequentially: rebuild -> bundle -> push via hawkBit ->
# wait for the device to auto-install+reboot (post_update_reboot=true) ->
# verify it landed on the expected slot with a good boot status -> repeat.
# Every ROLLBACK_TEST_EVERY'th cycle for a machine is a rollback-safety test
# instead of a normal update: deliberately corrupt the inactive slot, force
# a boot into it, and confirm the platform's bootcount/watchdog logic
# automatically falls back to the previous good slot on its own (see
# rollback_test() below) - this exercises the A/B rollback-safety path, not
# just the happy-path update cycle.
# Meant to run for an extended, unattended period (e.g. a weekend) - stop
# any time with: touch <LOG_DIR>/STOP
#
# Fill in BUILD_DIR/DUT_IP/DUT_TOKEN below for your own setup (DUT_TOKEN
# values must match each board's config.conf auth_token - see
# ../rauc-ota-updates.md §5.2) before running.

# No -u: oe-init-build-env and bitbake's own downstream setup scripts
# reference unset/optional variables freely and are not nounset-safe -
# sourcing them under `set -u` makes them exit silently and instantly,
# with zero output, the moment they hit the first one.
set -o pipefail

BUILD_DIR=/path/to/your/yocto/build
OE_INIT=/path/to/your/yocto/layers/openembedded-core/oe-init-build-env
LOCAL_CONF=$BUILD_DIR/conf/local.conf
LOG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG=$LOG_DIR/weekend-stress-test.log
STOP_FILE=$LOG_DIR/STOP
HAWKBIT=http://localhost:8083
AUTH="admin:admin"
MAX_CONSEC_FAILURES=3
HAWKBIT_COMPOSE_DIR=$LOG_DIR
ARTIFACTREPO_RESET_THRESHOLD_KB=$((5 * 1024 * 1024))  # 5GB
ROLLBACK_TEST_EVERY=4
ROLLBACK_BOOT_TIMEOUT=600  # 10min - generous, since a working rollback may need several failed-boot/watchdog-reset attempts before bootcount falls back

declare -A DUT_IP=(
    [REPLACE_WITH_MACHINE_NAME_1]=REPLACE_WITH_IP_1
    [REPLACE_WITH_MACHINE_NAME_2]=REPLACE_WITH_IP_2
)
# Matches the auth_token already baked into each DUT's config.conf - a
# hawkBit reset (below) re-registers targets with these exact same values
# so the DUTs never need reconfiguring after a reset.
declare -A DUT_TOKEN=(
    [REPLACE_WITH_MACHINE_NAME_1]=REPLACE_WITH_TARGET_SECURITY_TOKEN_1
    [REPLACE_WITH_MACHINE_NAME_2]=REPLACE_WITH_TARGET_SECURITY_TOKEN_2
)
declare -A CONSEC_FAILURES=()
declare -A DISABLED=()
declare -A CYCLE_COUNT=()
for m in "${!DUT_IP[@]}"; do
    CONSEC_FAILURES[$m]=0
    DISABLED[$m]=0
    CYCLE_COUNT[$m]=0
done

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"
}

# hawkBit's Management REST API DELETE endpoints are soft-delete only (the
# DB row is hidden, but the uploaded artifact file is never actually freed
# from disk - confirmed: deleting a software module + distribution set left
# the container's /app/artifactrepo unchanged). Every cycle uploads a fresh
# bundle, so this grows without bound - confirmed as the real cause of a
# run that passed 24 consecutive clean cycles per DUT, then started
# hard-timing-out once ~20GB had piled up (JVM/H2/disk-I/O degradation, not
# anything wrong with either DUT). The in-memory H2 DB (targets, tokens,
# distribution sets) doesn't persist across a restart anyway, so instead of
# fighting the API, just recreate the whole stack and re-register both
# targets with the same fixed tokens the DUTs already have configured.
maybe_reset_hawkbit() {
    local repo_kb
    repo_kb=$(docker exec hawkbit du -sk /app/artifactrepo 2>/dev/null | awk '{print $1}')
    if [ -z "$repo_kb" ] || [ "$repo_kb" -lt "$ARTIFACTREPO_RESET_THRESHOLD_KB" ]; then
        return 0
    fi

    log "=== hawkBit artifactrepo at ${repo_kb}KB (>= ${ARTIFACTREPO_RESET_THRESHOLD_KB}KB threshold) - resetting stack ==="
    (cd "$HAWKBIT_COMPOSE_DIR" && docker compose down -v && docker compose up -d) >> "$LOG_DIR/hawkbit-resets.log" 2>&1

    local deadline=$(( $(date +%s) + 120 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -s -o /dev/null -w '' "$HAWKBIT/rest/v1/targets" -u "$AUTH" 2>/dev/null; then
            break
        fi
        sleep 5
    done

    curl -s -X PUT "$HAWKBIT/rest/v1/system/configs/authentication.targettoken.enabled" \
        -u "$AUTH" -H 'Content-Type: application/json' -d '{"value": true}' > /dev/null

    # Not "machine" - a bash for-loop variable isn't automatically function-
    # local, so reusing the main loop's own variable name here would silently
    # clobber it as a side effect the moment this function returns, leaving
    # the caller's next run_cycle/rollback_test call operating on whichever
    # DUT this loop last iterated to instead of the one it actually meant to
    # process next. Confirmed the hard way: this exact collision caused the
    # main loop to get stuck reprocessing one DUT every time a reset fired,
    # silently starving the other one of cycles for hours.
    local reset_machine
    for reset_machine in "${!DUT_TOKEN[@]}"; do
        curl -s -X POST "$HAWKBIT/rest/v1/targets" -u "$AUTH" -H 'Content-Type: application/json' \
            -d "[{\"controllerId\": \"$reset_machine\", \"name\": \"$reset_machine\", \"securityToken\": \"${DUT_TOKEN[$reset_machine]}\"}]" > /dev/null
    done
    log "=== hawkBit stack reset complete, targets re-registered ==="
}

ssh_dut() {
    local ip=$1; shift
    # UserKnownHostsFile=/dev/null + StrictHostKeyChecking=no, not
    # accept-new: every reboot in this project generates a fresh SSH host
    # key for whichever bank just booted (documented, expected behavior -
    # not a security concern on trusted local test hardware), and
    # accept-new only auto-accepts a genuinely new/unknown host - it still
    # refuses a CHANGED key for an IP already in known_hosts. Since this
    # test reboots both DUTs constantly, that's every single cycle after
    # the first, not a rare edge case.
    ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes root@"$ip" "$@" 2>/dev/null
}

# A single failed SSH attempt can be a transient blip (this machine's own
# network, a brief DHCP renewal, a moment of LAN congestion) rather than a
# real problem with the DUT. Retry with backoff before treating a
# reachability check as a real failure.
ssh_dut_retry() {
    local ip=$1; shift
    local attempt out
    for attempt in 1 2 3 4 5 6; do
        out=$(ssh_dut "$ip" "$@")
        if [ $? -eq 0 ] && [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
        sleep $((attempt * 10))
    done
    return 1
}

# Wait (up to $1 seconds) for the DUT to respond to SSH at all - used after
# a reboot where we don't yet know which slot (if any) it'll come back on.
wait_for_ssh() {
    local ip=$1 timeout=$2
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ssh_dut "$ip" "echo UP" 2>/dev/null | grep -q UP; then
            return 0
        fi
        sleep 10
    done
    return 1
}

run_cycle() {
    local machine=$1
    local ip=${DUT_IP[$machine]}
    local cycle=${CYCLE_COUNT[$machine]}

    log "=== $machine cycle $cycle: starting (normal update) ==="

    # 1. Record which slot/marker it's on now, so we know what "changed"
    #    actually means once the wait loop below starts polling again.
    local before before_marker
    before=$(ssh_dut_retry "$ip" "rauc status 2>&1 | grep 'Booted from'")
    if [ $? -ne 0 ]; then
        log "$machine cycle $cycle: FAIL - could not reach DUT to check current slot (retried over ~2min)"
        return 1
    fi
    before_marker=$(ssh_dut_retry "$ip" "cat /etc/ota-demo-version 2>/dev/null")
    log "$machine cycle $cycle: currently $before (marker: $before_marker)"

    # 2. Rebuild image + bundle for this machine.
    sed -i "s/^MACHINE = .*/MACHINE = \"$machine\"/" "$LOCAL_CONF"
    (
        cd "$BUILD_DIR" || exit 1
        # shellcheck disable=SC1090
        source "$OE_INIT" "$BUILD_DIR" > /dev/null 2>&1
        bitbake cargt-image-dev "update-st-bundle-$machine"
    ) > "$LOG_DIR/build-$machine-cycle$cycle.log" 2>&1
    if grep -q "^ERROR:" "$LOG_DIR/build-$machine-cycle$cycle.log" \
       || ! grep -qE "^NOTE: Tasks Summary: Attempted [0-9]+ tasks of which [0-9]+ didn't need to be rerun and all succeeded" "$LOG_DIR/build-$machine-cycle$cycle.log"; then
        log "$machine cycle $cycle: FAIL - build error, see build-$machine-cycle$cycle.log"
        return 1
    fi

    # 3. Upload bundle + create distribution set + assign.
    local bundle version sm_id ds_id
    bundle=$(readlink -f "$BUILD_DIR/tmp-glibc/deploy/images/$machine/update-st-bundle-$machine-$machine.raucb")
    version=$(basename "$bundle" | sed -E "s/.*-$machine-([0-9]+)\.raucb/\1/")
    if [ ! -f "$bundle" ]; then
        log "$machine cycle $cycle: FAIL - bundle not found after build"
        return 1
    fi

    sm_id=$(curl -s -X POST "$HAWKBIT/rest/v1/softwaremodules" -u "$AUTH" -H 'Content-Type: application/json' \
        -d "[{\"name\": \"cargt-image-dev\", \"version\": \"$version\", \"type\": \"os\"}]" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)
    if [ -z "$sm_id" ]; then
        log "$machine cycle $cycle: FAIL - could not create software module"
        return 1
    fi

    curl -s -X POST "$HAWKBIT/rest/v1/softwaremodules/$sm_id/artifacts" -u "$AUTH" \
        -F "file=@${bundle};filename=bundle.raucb" > /dev/null

    ds_id=$(curl -s -X POST "$HAWKBIT/rest/v1/distributionsets" -u "$AUTH" -H 'Content-Type: application/json' \
        -d "[{\"name\": \"stress-$machine\", \"version\": \"$version\", \"type\": \"os\", \"modules\": [{\"id\": $sm_id}]}]" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)
    if [ -z "$ds_id" ]; then
        log "$machine cycle $cycle: FAIL - could not create distribution set"
        return 1
    fi

    curl -s -X POST "$HAWKBIT/rest/v1/distributionsets/$ds_id/assignedTargets" -u "$AUTH" -H 'Content-Type: application/json' \
        -d "[{\"id\": \"$machine\"}]" > /dev/null
    log "$machine cycle $cycle: assigned version $version, waiting for install+reboot"

    # 4. Wait for it to come back with a NEW ota-demo-version marker
    #    (proves it actually rebooted into the freshly-installed slot, not
    #    just that the DDI action was marked finished).
    local deadline=$(( $(date +%s) + 1500 ))
    local after=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 15
        local marker
        marker=$(ssh_dut "$ip" "cat /etc/ota-demo-version 2>/dev/null")
        if [ $? -eq 0 ] && [ -n "$marker" ] && [ "$marker" != "$before_marker" ]; then
            after=$(ssh_dut "$ip" "rauc status 2>&1 | grep -E 'Booted from|boot status'")
            local before_slot after_slot
            before_slot=$(echo "$before" | grep -oE '\([AB]\)')
            after_slot=$(echo "$after" | grep -oE '\([AB]\)' | head -1)
            if [ -n "$after_slot" ] && [ "$after_slot" != "$before_slot" ]; then
                if echo "$after" | grep -q "boot status:.*good"; then
                    log "$machine cycle $cycle: PASS - now $after (marker: $marker)"
                    return 0
                else
                    log "$machine cycle $cycle: FAIL - switched slot but boot status not good: $after"
                    return 1
                fi
            fi
        fi
    done

    log "$machine cycle $cycle: FAIL - timed out waiting for install+reboot (25min)"
    return 1
}

# Deliberately break the currently-INACTIVE slot's ability to boot to
# userspace, then reboot into it, and confirm the platform's bootcount /
# watchdog rollback logic automatically falls back to the previous good
# slot on its own - without any RAUC involvement, since this bypasses RAUC
# entirely (we're not doing a new install here, just corrupting whatever
# content is already sitting in the inactive slot from the last normal
# cycle, then forcing a boot attempt into it via RAUC's own bootloader
# backend, the same one a real install uses).
#
# Deliberately NOT repaired afterwards if it fails to roll back: the next
# normal run_cycle() for this machine installs fresh content into whichever
# slot is inactive anyway, so a corrupted-but-inactive slot self-heals on
# the next normal cycle. The only real risk is the rollback itself not
# happening - if the DUT doesn't come back within ROLLBACK_BOOT_TIMEOUT,
# stop immediately and flag it; don't attempt any further remote recovery.
rollback_test() {
    local machine=$1
    local ip=${DUT_IP[$machine]}
    local cycle=${CYCLE_COUNT[$machine]}

    log "=== $machine cycle $cycle: starting (ROLLBACK-SAFETY TEST) ==="

    local before before_slot inactive_slot inactive_letter
    before=$(ssh_dut_retry "$ip" "rauc status 2>&1 | grep 'Booted from'")
    if [ $? -ne 0 ]; then
        log "$machine cycle $cycle: FAIL - could not reach DUT to check current slot before rollback test"
        return 1
    fi
    before_slot=$(echo "$before" | grep -oE '\([AB]\)' | tr -d '()')
    if [ "$before_slot" = "A" ]; then
        inactive_letter=b
    elif [ "$before_slot" = "B" ]; then
        inactive_letter=a
    else
        log "$machine cycle $cycle: FAIL - could not determine current slot from '$before'"
        return 1
    fi
    log "$machine cycle $cycle: currently booted from slot $before_slot; will corrupt+boot inactive slot $inactive_letter"

    # Corrupt init (both traditional and systemd's own binary, so this
    # can't quietly fall through to whichever one the image actually
    # uses) in the inactive slot's rootfs, directly via its partition
    # symlink - not through RAUC, since we want last cycle's already-
    # installed content there, not a fresh install. If the slot has no
    # valid filesystem at all (e.g. never written by a real cycle yet),
    # that's already an unbootable state on its own - don't treat the
    # mount failure as a script error, just proceed to the reboot with
    # a note in the log.
    local corrupt_out
    corrupt_out=$(ssh_dut_retry "$ip" "
        mkdir -p /mnt/rollback-test
        if mount /run/cargt-part/rootfs-$inactive_letter /mnt/rollback-test 2>&1; then
            mv /mnt/rollback-test/sbin/init /mnt/rollback-test/sbin/init.rollback-test-disabled 2>/dev/null || true
            rm -f /mnt/rollback-test/usr/lib/systemd/systemd
            sync
            umount /mnt/rollback-test
            echo corrupted
        else
            echo already-invalid-filesystem
        fi
    ")
    if [ $? -ne 0 ]; then
        log "$machine cycle $cycle: FAIL - could not reach DUT to corrupt inactive slot $inactive_letter"
        return 1
    fi
    log "$machine cycle $cycle: inactive slot $inactive_letter state before reboot: $corrupt_out"

    # Make the corrupted slot the one that boots next, then reboot into
    # it - using RAUC's own bootloader backend (the same one a real
    # install uses), not a raw U-Boot env write, so this exercises the
    # actual production activation path. "other" = the inactive slot,
    # i.e. exactly the one we just corrupted.
    ssh_dut_retry "$ip" "rauc status mark-active other" > /dev/null
    if [ $? -ne 0 ]; then
        log "$machine cycle $cycle: FAIL - 'rauc status mark-active' failed, aborting before reboot"
        return 1
    fi
    ssh_dut "$ip" "reboot" > /dev/null 2>&1
    log "$machine cycle $cycle: rebooted into deliberately-broken slot $inactive_letter, waiting up to ${ROLLBACK_BOOT_TIMEOUT}s for rollback"

    if ! wait_for_ssh "$ip" "$ROLLBACK_BOOT_TIMEOUT"; then
        log "$machine cycle $cycle: CRITICAL FAIL - DUT did not come back within ${ROLLBACK_BOOT_TIMEOUT}s. Rollback-safety logic may not be working, or the board is stuck (e.g. boot-looping the bad slot, or held at a bootloader prompt). NOT attempting further remote recovery - needs physical/serial-console attention."
        return 2
    fi

    local after after_slot
    after=$(ssh_dut_retry "$ip" "rauc status 2>&1 | grep -E 'Booted from|boot status'")
    after_slot=$(echo "$after" | grep -oE '\([AB]\)' | head -1 | tr -d '()')
    if [ "$after_slot" = "$before_slot" ]; then
        log "$machine cycle $cycle: PASS - automatically rolled back to previous good slot $before_slot after broken slot $inactive_letter failed to boot ($after)"
        return 0
    elif [ "$after_slot" = "$(echo $inactive_letter | tr 'ab' 'AB')" ]; then
        log "$machine cycle $cycle: CRITICAL FAIL - DUT came back but is somehow STILL on the deliberately-broken slot $inactive_letter ($after) - corruption may not have actually prevented boot, or rollback logic chose wrong slot. Needs investigation."
        return 1
    else
        log "$machine cycle $cycle: FAIL - DUT came back but slot state is unclear: $after"
        return 1
    fi
}

log "=== weekend stress test starting (PID $$) - rollback-safety test every $ROLLBACK_TEST_EVERY cycles ==="
log "Stop any time with: touch $STOP_FILE"

while true; do
    if [ -f "$STOP_FILE" ]; then
        log "=== stop file present, exiting ==="
        rm -f "$STOP_FILE"
        break
    fi

    all_disabled=1
    for machine in "${!DUT_IP[@]}"; do
        if [ "${DISABLED[$machine]}" = "1" ]; then
            continue
        fi
        all_disabled=0

        CYCLE_COUNT[$machine]=$((CYCLE_COUNT[$machine] + 1))
        cycle_result=0
        if [ $(( CYCLE_COUNT[$machine] % ROLLBACK_TEST_EVERY )) -eq 0 ]; then
            rollback_test "$machine"
            cycle_result=$?
            if [ "$cycle_result" = "2" ]; then
                log "$machine: CRITICAL rollback-safety failure - DISABLING further cycles for this DUT immediately. Needs physical attention, do not attempt further automated recovery."
                DISABLED[$machine]=1
                continue
            fi
        else
            maybe_reset_hawkbit
            run_cycle "$machine"
            cycle_result=$?
        fi

        if [ "$cycle_result" = "0" ]; then
            CONSEC_FAILURES[$machine]=0
        else
            CONSEC_FAILURES[$machine]=$((CONSEC_FAILURES[$machine] + 1))
            log "$machine: ${CONSEC_FAILURES[$machine]} consecutive failure(s)"
            if [ "${CONSEC_FAILURES[$machine]}" -ge "$MAX_CONSEC_FAILURES" ]; then
                log "$machine: $MAX_CONSEC_FAILURES consecutive failures - DISABLING further cycles for this DUT. Needs manual investigation."
                DISABLED[$machine]=1
            fi
        fi

        if [ -f "$STOP_FILE" ]; then
            break
        fi
    done

    if [ "$all_disabled" = "1" ]; then
        log "=== all DUTs disabled after repeated failures - stopping ==="
        break
    fi
done

log "=== weekend stress test stopped ==="
