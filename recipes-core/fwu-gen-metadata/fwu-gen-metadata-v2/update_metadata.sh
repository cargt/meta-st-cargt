#!/bin/bash
# Write FWU metadata (v2 format) according to the given parameters.
# To stop bootcount, active_index and previous_active_index must be equal.

# fip-a / fip-b type + partition UUIDs and the FWU metadata type UUID are
# fixed platform-wide constants on STM32MP2 (same values already used for
# fip-a/fip-b in the board's .wks.in), not per-board.
UUID_LIST="8a7a84a0-8387-40f6-ab41-a8b9a5a60d23,19d5df83-11b0-457b-be2c-7559c13142a5,4fd84c93-54ef-463f-a7ef-ae25ff887087,09c54952-d5bf-45af-acee-335303766fb3"
OPTIONS="-g -i 1 -b 2 -v 2"

if test ! $# -eq 3
then
    echo "arg1: active partition number: 0 (rauc.slot=A) or 1 (rauc.slot=B)"
    echo "arg2: previous partition number: 0 (rauc.slot=A) or 1 (rauc.slot=B)"
    echo "      Should be different from active partition number"
    echo "arg3: active partition acceptation: accept (trial mode OFF) or refuse (trial mode ON)"
    exit 1
fi

# metadata v2:
# A (Accepted) : partition is accepted : normal boot
# V (Valid)    : partition not yet accepted : bootcount is enabled (trial mode)
# I (Invalid)  : invalid partition : not possible to boot on it (not managed here)
if test $3 == "refuse"
then
    if test $1 -eq 0
    then
        # current partition 0 is Valid (trial), partition 1 stays Accepted
        bank_state="V,A"
    else
        bank_state="A,V"
    fi
else
    # both partitions accepted
    bank_state="A,A"
fi

echo "writing metadata partitions...."
CMD="mkfwumdata ${OPTIONS} -s ${bank_state} -a $1 -p $2 ${UUID_LIST}"
echo ${CMD}
# /run/cargt-part/<name>, not /dev/disk/by-partlabel/<name>: eMMC and SD
# card both carry "metadata1"/"metadata2" partitions, so the system-wide
# by-partlabel symlink is ambiguous whenever both are present.
# cargt-device-symlinks.service resolves these scoped to whichever device
# root is actually mounted from.
${CMD} /run/cargt-part/metadata1
${CMD} /run/cargt-part/metadata2
sync

if test $1 -eq 0
then
    echo "active boot is A"
else
    echo "active boot is B"
fi

if test $3 == "refuse"
then
    echo "boot count is enabled"
fi
