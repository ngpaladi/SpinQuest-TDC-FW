# eMMC boot script (mkimage -A arm64 -T script -C none -d boot.cmd boot.scr).
# env set -f: u-boot pre-sets a random write-protected ethaddr at net init, so
# plain setenv fails SILENTLY and the random MAC is what u-boot's fdt fixup
# writes into the kernel DT. -f forces the factory MACs.
env set -f ethaddr 00:0a:35:24:07:fd
env set -f eth1addr 00:0a:35:24:07:fe
load mmc 0:1 0x18000000 Image
load mmc 0:1 0x14000000 system.dtb
setenv bootargs console=ttyPS1,115200 earlycon clk_ignore_unused uio_pdrv_genirq.of_id=generic-uio,ui_pdrv cma=900M root=/dev/mmcblk0p2 rw rootwait
booti 0x18000000 - 0x14000000
