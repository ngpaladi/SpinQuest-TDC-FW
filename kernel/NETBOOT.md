# NetBooting the KrIO carrier

Verified end-to-end on 2026-08-05: U-Boot pulls the kernel, device tree, and
rootfs over Ethernet A and boots to a login prompt with both network interfaces
up at 1 Gbps under Linux.

## Boot image composition

The QSPI `BOOT.BIN` must be assembled from a mixed set of components, and this
is load-bearing:

| Partition | Source | Why |
|---|---|---|
| FSBL | this project's PetaLinux build | programs the KrIO pinmux (GEM1/GEM2, MDIO on MIO76/77). AMD's stock K26 FSBL programs the KV260 pinmux (GEM3) and kills MDIO entirely. |
| PMU FW, BL31 | this project's PetaLinux build | |
| DTB (`load=0x100000`) | this project's, with the PHY fixes below | U-Boot's control DTB — U-Boot reads it from 0x100000 |
| U-Boot | AMD `embpf-bootfw-update-tool` `u-boot.elf` | handles the shared-MDIO GEM topology correctly and keeps its console on the physical UART. The PetaLinux-built U-Boot honors `stdout-path = "serial1"` → `/dcc`, i.e. it runs fine but prints to the JTAG debug channel and looks dead. |

```
the_ROM_image:
{
    [bootloader, destination_cpu=a53-0] zynqmp_fsbl.elf      # PetaLinux
    [pmufw_image] pmufw.elf                                  # PetaLinux
    [destination_cpu=a53-0, exception_level=el-3, trustzone] bl31.elf
    [destination_cpu=a53-0, load=0x100000] system.dtb        # fixed DTB
    [destination_cpu=a53-0, exception_level=el-2] u-boot.elf # AMD tool
}
```

## Device tree requirements (both were silent failures)

1. `ti,rx-internal-delay` / `ti,tx-internal-delay` are **mandatory** with
   `phy-mode = "rgmii-id"`. `dp83867_of_init()` errors out without them,
   reporting only via `pr_debug()` — U-Boot then says `No ethernet found`.
   Value 8 (2.25 ns) was chosen by sweeping on hardware: 4..14 pass, 0..2 fail.
2. The compatible must list the PHY ID **first**:
   `compatible = "ethernet-phy-id2000.a231", "ti,dp83867";`
   Linux's `fwnode_get_phy_id()` only reads the first compatible string; with
   `"ti,dp83867"` first the node registers as a plain `mdio_device` and macb
   reports `Could not attach PHY (-19)`.

Both PHYs are DP83867 (not DP83869) at MDIO addresses 0 and 5 (not 1 — the
schematic annotation is wrong; confirmed by scan, by U-Boot probe, and by each
PHY's latched `STRAP_STS1[4:0]`). Both hang off GEM1's MDIO bus (MIO76/77).

## Server side

Any HTTP server on port 8080 works; no root needed. U-Boot's `wget` reads the
port from the `httpdstp` env var. Note the host must be on a **wired** path to
the board's switch — U-Boot's TCP does not survive a lossy WiFi hop on large
transfers (`wget: Fatal error, queue overrun!`).

```
cd <dir with Image, system.dtb, rootfs.cpio.gz.u-boot>
python3 -m http.server 8080
```

## U-Boot side

```
setenv ethact ethernet@ff0c0000
setenv ipaddr 192.168.0.180
setenv netmask 255.255.255.0
setenv serverip <host wired IP>
setenv httpdstp 8080
wget 0x18000000 ${serverip}:/Image
wget 0x14000000 ${serverip}:/system.dtb
wget 0x20000000 ${serverip}:/rootfs.cpio.gz.u-boot
setenv bootargs console=ttyPS1,115200 earlycon clk_ignore_unused cma=900M
booti 0x18000000 0x20000000 0x14000000
```

Do not `saveenv` — the U-Boot environment offset lives inside the BOOT.BIN
region of QSPI and writing it corrupts the boot image.
