#!/bin/sh
# Refresh config.conf's [device] section with values only knowable at
# runtime (the hostname - which already embeds this board's real MAC
# address, e.g. stm32mp25-cargt-00395-02-00365-00-08-ee-16-32-f2 - and the
# currently-booted build's version marker). These get sent to hawkBit as
# target attributes on every poll, giving each node a unique identifier
# and firmware version visible in the UI without a separate management
# API call. Idempotent: truncates at the first existing [device] line
# (from a prior boot, or this file's own build-time placeholder) and
# rewrites it fresh, so it's safe to run on every service start.
set -e

CONF=/etc/rauc-hawkbit-updater/config.conf
HOSTNAME=$(hostname)
FW_VERSION=$(cat /etc/ota-demo-version 2>/dev/null || echo unknown)

awk '/^\[device\]/{exit} {print}' "$CONF" > "$CONF.tmp"
{
    echo "[device]"
    echo "hostname   = $HOSTNAME"
    echo "fw_version = $FW_VERSION"
} >> "$CONF.tmp"
mv "$CONF.tmp" "$CONF"
