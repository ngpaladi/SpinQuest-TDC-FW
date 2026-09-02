#!/bin/bash
# Flash the KrIO/K26 onboard eMMC with the current PetaLinux build, over SSH,
# turning the netbooted board into a standalone eMMC-booting system.
#
# Layout written to /dev/mmcblk0 (~14.8 GB):
#   p1  512M  FAT32  Image, system.dtb, boot.scr   (U-Boot distro-boot finds it)
#   p2  4G    ext4   root filesystem (persistent)
#
# Boot flow afterward: QSPI FSBL/U-Boot (BOOT-netboot2.BIN) -> scans mmc0:1 ->
# boot.scr -> kernel+dtb from p1, root=/dev/mmcblk0p2. No network needed.
#
# Prereqs: board is up and SSH-able (netboot it first if not: ./netboot.sh),
# host has e2fsprogs and mkimage (petalinux tools), paramiko in miniforge.
#
# Usage: ./flash_emmc.sh [board-ip]     (default 192.168.0.69)
set -e
BOARD=${1:-192.168.0.69}
PW=${KRIO_PW:-Krio.daq.2026!}
D=/home/npaladin/git/SpinQuest-TDC-FW/kernel/zynq_build/.emmc/build/tmp/deploy/images/zynqmp-generic-xck26
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
PY=/home/npaladin/miniforge3/bin/python3

echo "== 1/5 prepare artifacts =="
cp -L "$D/petalinux-image-minimal-zynqmp-generic-xck26.ext4" $WORK/rootfs.ext4
/usr/sbin/e2fsck -fy $WORK/rootfs.ext4 >/dev/null
/usr/sbin/resize2fs -f $WORK/rootfs.ext4 4G >/dev/null 2>&1
cp -L "$D/Image" "$D/devicetree/system-top.dtb" $WORK/
mv $WORK/system-top.dtb $WORK/system.dtb
cat > $WORK/boot.cmd <<'EOS'
load mmc 0:1 0x18000000 Image
load mmc 0:1 0x14000000 system.dtb
setenv bootargs console=ttyPS1,115200 earlycon clk_ignore_unused cma=900M root=/dev/mmcblk0p2 rw rootwait
booti 0x18000000 - 0x14000000
EOS
source /home/npaladin/Xilinx/petalinux/settings.sh >/dev/null 2>&1
mkimage -A arm64 -T script -C none -d $WORK/boot.cmd $WORK/boot.scr >/dev/null

echo "== 2/5 partition + format p1 on target =="
BOARD=$BOARD PW=$PW $PY - <<'PYEOF'
import paramiko, os, time
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(os.environ['BOARD'], username='petalinux', password=os.environ['PW'], timeout=10)
def sudo(cmd, w=60):
    _,o,e = c.exec_command(f"echo '{os.environ['PW']}' | sudo -S sh -c \"{cmd}\"", timeout=w)
    out, err = o.read().decode(), e.read().decode()
    rc = o.channel.recv_exit_status()
    if rc != 0: raise SystemExit(f"FAILED ({rc}): {cmd}\n{out}{err}")
    return out
# wipe any old table, then: p1 512M type 0c bootable, p2 rest type 83
sudo("dd if=/dev/zero of=/dev/mmcblk0 bs=1M count=1; sync")
sudo("printf 'o\\nn\\np\\n1\\n\\n+512M\\nt\\nc\\nn\\np\\n2\\n\\n\\na\\n1\\nw\\n' | busybox fdisk /dev/mmcblk0 || true")
time.sleep(2)
sudo("busybox mdev -s || true; [ -e /dev/mmcblk0p1 ] || { mknod /dev/mmcblk0p1 b 179 1; mknod /dev/mmcblk0p2 b 179 2; }; ls /dev/mmcblk0p1 /dev/mmcblk0p2")
sudo("busybox mkfs.vfat -n BOOT /dev/mmcblk0p1")
print(sudo("busybox fdisk -l /dev/mmcblk0 | tail -4"))
c.close()
PYEOF

echo "== 3/5 copy boot files to p1 =="
BOARD=$BOARD PW=$PW WORK=$WORK $PY - <<'PYEOF'
import paramiko, os
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(os.environ['BOARD'], username='petalinux', password=os.environ['PW'], timeout=10)
w = os.environ['WORK']
t = c.get_transport()
for f in ('Image','system.dtb','boot.scr'):
    # no sftp on dropbear: stream through cat
    chan = t.open_session(timeout=30)
    chan.exec_command(f'cat > /tmp/{f}')
    with open(f'{w}/{f}','rb') as fh:
        while True:
            buf = fh.read(1<<20)
            if not buf: break
            chan.sendall(buf)
    chan.shutdown_write()
    import time as _t
    while not chan.exit_status_ready(): _t.sleep(0.2)
    assert chan.recv_exit_status() == 0, f
    print(f"  sent {f}")
def sudo(cmd, w=120):
    _,o,e = c.exec_command(f"echo '{os.environ['PW']}' | sudo -S sh -c \"{cmd}\"", timeout=w)
    rc = o.channel.recv_exit_status()
    if rc != 0: raise SystemExit(f"FAILED: {cmd}\n{e.read().decode()}")
sudo("mkdir -p /mnt/p1 && mount /dev/mmcblk0p1 /mnt/p1")
sudo("cp /tmp/Image /tmp/system.dtb /tmp/boot.scr /mnt/p1/ && sync")
sudo("umount /mnt/p1")
c.close()
PYEOF

echo "== 4/5 stream rootfs to p2 (gzip over ssh, ~4GB written) =="
BOARD=$BOARD PW=$PW WORK=$WORK $PY - <<'PYEOF'
import paramiko, os, gzip, io, time
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(os.environ['BOARD'], username='petalinux', password=os.environ['PW'], timeout=10)
t = c.get_transport(); t.set_keepalive(15)
# sudo -S would eat the stdin pipe (gunzip would see EOF), so open the
# device to this user first, stream unprivileged, then restore perms.
_,o,_ = c.exec_command(f"echo '{os.environ['PW']}' | sudo -S chmod 666 /dev/mmcblk0p2")
o.channel.recv_exit_status()
chan = t.open_session(timeout=30)
chan.exec_command("sh -c 'gunzip -c | dd of=/dev/mmcblk0p2 bs=1M; sync'")
src = open(os.environ['WORK'] + '/rootfs.ext4','rb')
gz = gzip.GzipFile(fileobj=io.BytesIO(), mode='wb')  # placeholder, we stream manually
import zlib
comp = zlib.compressobj(6, wbits=31)   # gzip container
sent = 0; t0=time.time()
while True:
    buf = src.read(1<<20)
    if not buf: break
    data = comp.compress(buf)
    if data: chan.sendall(data)
    sent += len(buf)
    if sent % (512<<20) == 0:
        print(f"  {sent>>20} MB in, {time.time()-t0:.0f}s", flush=True)
chan.sendall(comp.flush()); chan.shutdown_write()
while not chan.exit_status_ready(): time.sleep(1)
rc = chan.recv_exit_status()
print(f"  dd exit {rc}, {sent>>20} MB source, {time.time()-t0:.0f}s total")
_,o,_ = c.exec_command(f"echo '{os.environ['PW']}' | sudo -S chmod 660 /dev/mmcblk0p2")
o.channel.recv_exit_status()
if rc != 0: raise SystemExit("rootfs write FAILED")
c.close()
PYEOF

echo "== 5/5 verify =="
BOARD=$BOARD PW=$PW $PY - <<'PYEOF'
import paramiko, os
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(os.environ['BOARD'], username='petalinux', password=os.environ['PW'], timeout=10)
def sudo(cmd, w=60):
    _,o,e = c.exec_command(f"echo '{os.environ['PW']}' | sudo -S sh -c \"{cmd}\"", timeout=w)
    out = o.read().decode(); rc = o.channel.recv_exit_status()
    if rc != 0: raise SystemExit(f"FAILED: {cmd}\n{e.read().decode()}")
    return out
print(sudo("mount /dev/mmcblk0p1 /mnt/p1 && ls -l /mnt/p1 && umount /mnt/p1"))
print(sudo("mkdir -p /mnt/p2 && mount /dev/mmcblk0p2 /mnt/p2 && ls /mnt/p2 | head -8 && df -h /mnt/p2 | tail -1 && umount /mnt/p2"))
c.close()
PYEOF
echo "== DONE — power cycle to boot standalone from eMMC =="
