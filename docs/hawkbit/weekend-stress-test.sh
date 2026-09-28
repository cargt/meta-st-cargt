#!/bin/bash
# Continuous hawkBit-driven RAUC A/B update stress test.
# Cycles both DUTs sequentially: rebuild -> bundle -> push via hawkBit ->
# wait for the device to auto-install+reboot (post_update_reboot=true) ->
# verify it landed on the expected slot with a good boot status -> repeat.
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

    for machine in "${!DUT_TOKEN[@]}"; do
        curl -s -X POST "$HAWKBIT/rest/v1/targets" -u "$AUTH" -H 'Content-Type: application/json' \
            -d "[{\"controllerId\": \"$machine\", \"name\": \"$machine\", \"securityToken\": \"${DUT_TOKEN[$machine]}\"}]" > /dev/null
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

run_cycle() {
    local machine=$1
    local ip=${DUT_IP[$machine]}
    local cycle=${CYCLE_COUNT[$machine]}

    log "=== $machine cycle $cycle: starting ==="

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

log "=== weekend stress test starting (PID $$) ==="
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

        maybe_reset_hawkbit
        CYCLE_COUNT[$machine]=$((CYCLE_COUNT[$machine] + 1))
        if run_cycle "$machine"; then
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
