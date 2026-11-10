#!/bin/bash
# Rebuild kernel + DTB + initramfs + recovery image.   usage: kernel/build.sh <out-image-name>   (e.g. recovery-new13.img)
set -e
P="$(cd "$(dirname "$0")/.." && pwd)"; K=$P/kernel/linux-6.12.114; N=$P/kernel/nk
BB=${BB:-$P/kernel/nk/busybox}
[ -f "$BB" ] || BB=$P/kernel/nk/busybox
aarch64-linux-gnu-gcc -static -O2 -o $N/init $N/init.c && aarch64-linux-gnu-strip -o $N/init.stripped $N/init
python3 -I $P/recovery-work/mkinitramfs.py $N/rd.cpio.gz $N/init.stripped $BB
cd $K
rm -f arch/arm64/boot/dts/amlogic/meson-gxl-s905x-mibox.dtb   # always recompile: the MAC patch below edits the file in place
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- amlogic/meson-gxl-s905x-mibox.dtb
[ -f "$P/kernel/macs.env" ] && . "$P/kernel/macs.env"
python3 -I - arch/arm64/boot/dts/amlogic/meson-gxl-s905x-mibox.dtb "${WIFI_MAC:-}" "${BT_MAC:-}" <<'PY'
import sys,re
p,w,b=sys.argv[1:4]
def mac(s,rev=False):
    if not s: return bytes(6)
    assert re.fullmatch(r'([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}',s), 'bad MAC '+s
    x=bytes.fromhex(s.replace(':','')); return x[::-1] if rev else x
d=bytearray(open(p,'rb').read())
for ph,val in ((bytes.fromhex('deadbeef0001'),mac(w)),(bytes.fromhex('deadbeef0002'),mac(b,True))):
    assert d.count(ph)==1, 'placeholder not found exactly once'
    i=d.index(ph); d[i:i+6]=val
open(p,'wb').write(d); print('DTB MACs: wifi',w or 'unset','bt',b or 'unset')
PY
cp arch/arm64/boot/dts/amlogic/meson-gxl-s905x-mibox.dtb arch/arm64/kernel/mibox.dtb
scripts/config --file .config --set-str INITRAMFS_SOURCE "$N/rd.cpio.gz"
scripts/config --file .config --set-str CMDLINE "console=tty0 earlycon=aml_uart,0xc81004c0 console=ttyS0,115200n8 clk_ignore_unused pd_ignore_unused panic=0 loglevel=7 printk.devkmsg=on systemd.log_target=kmsg systemd.log_level=info systemd.show_status=1 video=HDMI-A-1:1920x1080@60e usb-storage.quirks=13fe:6300:m usbcore.autosuspend=-1 blkdevparts=mmcblk1:5574230016@2243952640(linux)"
scripts/config --file .config --set-str LOCALVERSION "-ophub"   # match the Armbian/ophub modules dir (no MODVERSIONS/signing -> vermagic is the only check)
scripts/config --file .config -e SECURITY_LANDLOCK --set-str LSM "landlock,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor"   # pacman 7 sandbox needs Landlock
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig </dev/null
make -j12 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image </dev/null
gzip -9 -c arch/arm64/boot/Image > $N/Image.gz; cp .config $P/kernel/mibox.config
cd $P/recovery-work && python3 -I mkimg_new.py ../recovery-backup.img ../kernel/nk/Image.gz ../kernel/nk/rd.cpio.gz $K/arch/arm64/boot/dts/amlogic/meson-gxl-s905x-mibox.dtb "$1"
