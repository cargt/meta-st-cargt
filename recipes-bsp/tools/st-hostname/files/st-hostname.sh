#!/bin/sh -

# get mac-adress of end0
# Cargt: colons stripped entirely rather than turned into dashes - with the
# machine-name/MAC separator dash already in place, the internal dashes
# only added length without adding any readability of their own.
MAC=$(ip link show end0 | grep "link/ether"| awk '{print $2;}'| sed "s|00:80:e1||" | sed "s|10:e7:7a||" | tr -d ':')
# Cargt: drop the "stm32mp25-" prefix baked into MACHINE - it's redundant
# once the SOM part number (00395/00378) is visible later in the same
# name, and dropping it makes the whole hostname noticeably shorter.
PREVIOUS_HOST=$(cat /etc/hostname | sed "s/^stm32mp25-//")

if [ -z $MAC ]; then
    MAC=unknown
fi
if $(cat /etc/hostname | grep -qe "unknown"); then
    # reset hostname
    sed -i "s/unknown//" /etc/hostname
fi
if $(cat /etc/hostname | grep -qe "$MAC"); then
    #echo "[DEBUG] mac address already present"
    :
    # mac address already present on hostname
else
    #echo "[DEBUG] mac address NOT present"
    # Cargt: separator ("-") added between MACHINE name and MAC so the
    # boundary is readable - the upstream script joined them with no
    # separator at all (${PREVIOUS_HOST}${MAC}), which is genuinely
    # ambiguous whenever MACHINE ends in a digit right before the MAC's
    # own leading digit (e.g. "...00365" + "00-08-..." reads as one
    # unbroken run of digits: "...0036500-08-...").
    echo ${PREVIOUS_HOST}-${MAC} > /etc/hostname
    hostnamectl hostname ${PREVIOUS_HOST}-${MAC}
    hostnamectl --transient hostname ${PREVIOUS_HOST}-${MAC}
    if $(grep -q SendHostname /usr/lib/systemd/network/80-wired.network) ; then
        sed -i "s|Hostname=.*$|Hostname=${PREVIOUS_HOST}-${MAC}|" /usr/lib/systemd/network/80-wired.network
    else
        echo "SendHostname=true" >> /usr/lib/systemd/network/80-wired.network
        echo "Hostname=${PREVIOUS_HOST}-${MAC}" >> /usr/lib/systemd/network/80-wired.network
    fi
fi
