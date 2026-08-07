#!/bin/sh
# Revert bond0 back to independent eth0/eth1. Safe to run from the serial
# console when a bond has made the network unreachable.
set -e
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
if [ -d /sys/class/net/bond0 ]; then
    ip link set bond0 down 2>/dev/null || true
    ip link set eth0 nomaster 2>/dev/null || true
    ip link set eth1 nomaster 2>/dev/null || true
    ip link del bond0 2>/dev/null || true
fi
ip addr flush dev eth0; ip addr flush dev eth1
ip link set eth0 up; ip link set eth1 up
udhcpc -i eth0 -n -q 2>/dev/null || dhclient eth0 2>/dev/null || true
ip -br addr | grep -E 'eth|bond'
