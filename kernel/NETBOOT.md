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

## Flashing to eMMC (standalone boot)

Once netbooted, `kernel/flash_emmc.sh <board-ip>` partitions the K26's onboard
eMMC over SSH and installs the current build: p1 (512M FAT32) gets `Image`,
`system.dtb`, and a `boot.scr`; p2 (rest, ext4) gets the rootfs, resized to 4G
on the host and streamed gzip-compressed into the partition (the target has no
`mkfs.ext4`, so the filesystem image is written whole). After that the board
cold-boots from eMMC with no network and no interaction:
U-Boot's distro-boot finds `/boot.scr` on mmc 0:1 and boots with
`root=/dev/mmcblk0p2 rw rootwait`.

Two target-side quirks the script works around: busybox applets are not
symlinked into root's PATH (`busybox fdisk`, `busybox mkfs.vfat`), and
dropbear has no SFTP, so files stream through `cat` over exec channels. Also
`echo pw | sudo -S cmd` eats stdin, so anything that pipes data through sudo
must open device permissions first and write unprivileged.

For unattended boot the QSPI U-Boot needs its default env patched to
`bootdelay=-2` (skip the abort check entirely, not just zero the delay):
power-on line noise otherwise lands in the UART FIFO and aborts autoboot.
The byte for the longer string comes from truncating the unused
`bootcmd_usb4` entry — see BOOT-emmc.BIN in the bench notes.

## FPGA gateware + final image composition (updated)

The shipped QSPI image (`BOOT-final.BIN`) includes the PL bitstream: the FSBL
programs `TDC_64ch_2BRAM.bit` (extracted from the project XSA) into the fabric
on every boot, before U-Boot runs. Verified from Linux by write/read of the TDC
BRAM at 0xa0000000 via devmem.

Two corrections to the composition table above, learned the hard way:

- **U-Boot comes from the original working image** (the u-boot partition
  extracted from `BOOT-v3.BIN`, repackaged as a raw `load=0x8000000` partition),
  not from AMD's embpf tool. The AMD build's `sf` layer is broken on this DT
  ("Invalid chip select 0:0"), which also breaks env load; the extracted build
  has working `sf`, working Ethernet, and mmc distro-boot.
- **JTAG flashing does not work above ~2 MB** in QSPI boot mode: both Vivado
  `program_hw_cfgmem` and `program_flash` hang indefinitely on a 9.5 MB image
  (program_flash even warns the boot mode is unsupported). The working path is
  the board flashing itself:

```
# host: docker cp BOOT-final.BIN netboot:/srv/tftpboot/
# board (U-Boot prompt — temporarily move boot.scr off eMMC p1 to get one):
tftpboot 0x10000000 BOOT-final.BIN
sf probe
sf update 0x10000000 0 ${filesize}
```

9.5 MB flashes in ~70 s. The `netboot` docker container (built from
`kernel/netboot/`) is the TFTP server on port 69 and the intended home for
boot artifacts.
