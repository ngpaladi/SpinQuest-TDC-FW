#!/bin/sh
# Bring up bond0 across the two GEMs for 802.3ad (LACP) link aggregation.
#
# READ THIS FIRST: the switch ports MUST be configured as an LACP port-channel
# before you run this. With no LACP partner the bond still "comes up" and passes
# some traffic, but both slaves transmit with the same MAC on two switch ports,
# the switch sees that MAC flapping, and connectivity becomes unreliable —
# measurably worse than not bonding at all. Verified on this hardware.
#
# Check for a partner after running:
#   grep -E 'Partner Mac|Number of ports' /proc/net/bonding/bond0
# Healthy looks like a non-zero partner MAC and "Number of ports: 2".
#
# Usage:  bond-setup.sh [CIDR-address | dhcp]      default: dhcp
#         bond-setup.sh 192.168.0.180/24
set -e
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
ADDR="${1:-dhcp}"
SLAVES="eth0 eth1"
MAC=$(cat /sys/class/net/eth0/address)   # keep the factory MAC, not a random one

modprobe bonding 2>/dev/null || true     # no-op when built in (CONFIG_BONDING=y)

# Tear down anything previous
if [ -d /sys/class/net/bond0 ]; then
    ip link set bond0 down 2>/dev/null || true
    for s in $SLAVES; do ip link set "$s" nomaster 2>/dev/null || true; done
    ip link del bond0 2>/dev/null || true
fi

for s in $SLAVES; do ip link set "$s" down; ip addr flush dev "$s"; done

# Create the master. Note: passing these as `ip link add` options is unreliable
# on this kernel — they silently fall back to defaults (layer2 / slow), which
# would pin every flow to one slave. Set them through sysfs and verify.
ip link add bond0 type bond
echo 802.3ad   > /sys/class/net/bond0/bonding/mode
echo 100       > /sys/class/net/bond0/bonding/miimon
echo fast      > /sys/class/net/bond0/bonding/lacp_rate
echo layer3+4  > /sys/class/net/bond0/bonding/xmit_hash_policy
ip link set bond0 address "$MAC"

for s in $SLAVES; do ip link set "$s" master bond0; done
ip link set bond0 up
for s in $SLAVES; do ip link set "$s" up; done

# Confirm the options actually took
echo "mode:        $(cat /sys/class/net/bond0/bonding/mode)"
echo "hash policy: $(cat /sys/class/net/bond0/bonding/xmit_hash_policy)"
echo "lacp rate:   $(cat /sys/class/net/bond0/bonding/lacp_rate)"

case "$ADDR" in
    dhcp) udhcpc -i bond0 -n -q 2>/dev/null || dhclient bond0 2>/dev/null || true ;;
    *)    ip addr add "$ADDR" dev bond0 ;;
esac

echo "waiting for LACP negotiation..."
sleep 6
PARTNER=$(awk '/Partner Mac Address/ {print $4; exit}' /proc/net/bonding/bond0)
PORTS=$(awk '/Number of ports/ {print $4; exit}' /proc/net/bonding/bond0)
echo "partner MAC: ${PARTNER:-none}   ports in aggregator: ${PORTS:-0}"
if [ "$PARTNER" = "00:00:00:00:00:00" ] || [ -z "$PARTNER" ]; then
    echo "WARNING: no LACP partner — the switch is not configured for this bond."
    echo "         Expect unstable connectivity. Run bond-teardown.sh to revert."
    exit 2
fi
echo "bond0 up with $PORTS ports aggregated"
ip -br addr show bond0
