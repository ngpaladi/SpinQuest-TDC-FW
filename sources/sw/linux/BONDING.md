# Link aggregation on the KrIO carrier

Target topology: each board LACP-bonds its two GEMs to a smart switch; the switch
aggregates several boards into one fast uplink to the DAQ server.

## Measured baseline

A single GEM sustains **0.94 Gbps** TCP (board → host, 64 KB writes, 8 s).
So the SoC is not the limit — line rate per port, ~1.88 Gbps theoretical per board.

## Two things that cap you at 1 Gbps if you get them wrong

**1. Per-flow hashing.** 802.3ad assigns each *flow* to one slave. One TCP
connection therefore never exceeds one link's rate, however the switch is set up.
`daemon.c` opens **two connections, one per BRAM**, which gives the hash something
to spread — the PL already ping-pongs between BRAMs, so the mapping is free.

**2. Hash policy.** The default `layer2` hashes on MAC addresses only. Every flow
to the same server has the same MAC pair, so they all land on the same slave and
the second port carries nothing. Use **`layer3+4`** (IP + port), which is what
`bond-setup.sh` sets. The default `lacp_rate slow` (30 s LACPDUs) is also changed
to `fast` (1 s) for quicker failover.

Note both of these are silently ignored when passed as `ip link add` options on
this kernel — they fall back to the defaults. `bond-setup.sh` writes them through
sysfs and prints them back so you can see they took.

## Do not bond against an unconfigured switch

Verified on this hardware: with no LACP partner the bond comes up and passes
*some* traffic, but both slaves transmit with the bond's MAC on two switch ports.
The switch sees the same MAC flapping between ports and starts dropping — we could
ping outward from the board but not reach it inbound, and SSH connected once then
died. This is worse than no bond. Confirm the partner before relying on it:

    grep -E 'Partner Mac|Number of ports' /proc/net/bonding/bond0

Healthy: a non-zero partner MAC and `Number of ports: 2`. `bond-setup.sh` checks
this for you and exits non-zero with a warning if there is no partner.

## Board side

    ./bond-setup.sh                 # DHCP
    ./bond-setup.sh 192.168.0.180/24
    ./bond-teardown.sh              # revert to eth0/eth1 (works over serial)

The bond keeps eth0's factory MAC (`00:0a:35:24:07:fd`) rather than the random one
the kernel picks by default, so DHCP reservations stay valid.

This is deliberately **not** enabled at boot. A board that auto-bonds into a switch
without a matching port-channel strands itself on the network, and these boards get
deployed one at a time. Enable it per board once the switch side is ready.

## Switch side

Each board needs its own port-channel — two boards must not share one. Configure
LACP `active`, and set the switch's own hash to include L3/L4 so its uplink
spreads too.

Cisco IOS:

    interface range GigabitEthernet1/0/1-2
     channel-group 1 mode active
    port-channel load-balance src-dst-mixed-ip-port

Arista EOS:

    interface Ethernet1-2
     channel-group 1 mode active
    port-channel load-balance ethernet destination-ip-port

MikroTik / RouterOS:

    /interface bonding add slaves=ether1,ether2 mode=802.3ad \
        transmit-hash-policy=layer-3-and-4 lacp-rate=1sec

UniFi / TP-Link / Netgear smart switches: create a LAG, set type **LACP** (not
static), and pick the "IP + port" or "layer 3+4" hash if offered.

## Ceiling

Per board: ~1.88 Gbps with both links busy. Across N boards the switch uplink must
carry N × that — four boards saturate a 10 GbE uplink at about 75%.
