# Mainline Linux (Arch Linux ARM) on the Xiaomi Mi Box S (MDZ-22-AB, S905X)

Replaces Android with a minimal **Arch Linux ARM** that boots from the box's own eMMC, with a **mainline 6.12 kernel**,
HDMI console, **Wi-Fi (BCM43456)**, **Bluetooth (BCM4345C5)**, SSH and working `pacman`. No bootloader is modified.

Tested on one unit (Android 12 build STTC.230106.001 / 4560, secure boot on). Full engineering history: [`docs/ENGINEERING-LOG.md`](docs/ENGINEERING-LOG.md).

> **This removes Android** (its `userdata` partition is overwritten and `misc` is set so the box always boots Linux).
> It can be undone from a backup (section 9) and burn mode always works as a rescue. **Do the backup first.**
> You do everything at your own risk. The bootloader chain (`bootloader`, `env`, `boot0`, `boot1`) is never written by any script here.

## How it works (short)

* The box's bootloader is signed and U-Boot only loads Android-style images from flash. The `recovery` partition is **not**
  signature-checked, so our kernel lives there: a boot image with the mainline kernel, a tiny initramfs and an **embedded device tree**
  (U-Boot always hands the kernel its own vendor DTB on this path, so the kernel ignores it and uses the built-in one).
* `misc` carries a `boot-recovery` flag, so U-Boot boots that image on every power-up (no remote buttons needed).
* The initramfs `/init` mounts the eMMC partition `userdata` (exposed as `/dev/mmcblk1p1` through `blkdevparts=`) and `switch_root`s into Arch.
* The real Wi-Fi/Bluetooth MAC addresses are patched into the device tree at build time.
* Everything is written over **USB burn mode** with signed bootloader pieces loaded into RAM (no bootloader flash).

## What you need

* The Mi Box S, a **USB A-to-A (male-male) data cable** (single USB port is used for flashing), HDMI display, a USB keyboard for first login.
* An **Arch-based PC** (the image build uses the host's `pacman --root`, no chroot/qemu), with: `aarch64-linux-gnu-gcc`, `bc`, `flex`, `bison`,
  `libarchive` (`bsdtar`), `e2fsprogs`, `openssl`, `python`, `curl`, `fakeroot` (optional), `libusb-compat`, `adb`, `zstd`, and about **30 GB free** (backup + build).
* Files you must obtain yourself (not redistributed here):
  * `ota-bootloader.img` (repo root) — `bootloader.img` (1,442,304 bytes) taken from the official Xiaomi **Android 12** OTA package of this box. `stage1.py` splits it (bl2 = first 49152 bytes, rest = tpl) and loads it into RAM; it is never written to flash. The Android 11 `r363` loaders crash in DDR init on this board (see `docs/ENGINEERING-LOG.md`, "Loading U-Boot into RAM").
  * `password/password.bin` (repo root) — the Amlogic burn-mode unlock password file for this box (community file from AndroidPC; sent to the box at the start of every burn session).
  * `recovery-backup.img` — **your own** stock `recovery` partition dump (section 1). The recovery image is built by swapping kernel/ramdisk/DTB into it.

## 0. Get the project ready

```
git clone <this repo> mibox-root && cd mibox-root
python3 -m venv .venv && .venv/bin/pip install pyusb pillow
flash-tools/setup.sh        # fetches pyamlboot + Khadas aml-flash-tool at the commits we used
```

Burn mode: connect the A-A cable from the PC to the box's USB port, then put the box in Amlogic USB burn mode so that
`lsusb` shows **`1b8e:c003`**. <!-- TODO(author): describe exactly how you enter burn mode on this unit --> A fresh burn-mode session is needed for **every** flash operation
(the loader only survives one write).

## 1. Back up everything first

In burn mode you can read the partitions. At a minimum save `recovery`, `misc`, `logo`, `userdata`; the full-eMMC procedure we used is in
`docs/ENGINEERING-LOG.md` (Part 8). Per partition (box in burn mode, after the `password` + `stage1.py` + `disk_initial 0` steps of `flash-tools/flash-part.sh`):

```
update mread store <partition> normal <size-in-bytes> <file>
```

Partition offsets/sizes of this box: `logo` 0x18400000 (8 MiB), `recovery` 0x19400000 (24 MiB), `misc` 0x1b400000 (8 MiB),
`super` 0x22c00000 (0x62800000), `userdata` 0x85c00000 (0x14c400000 = 5574230016 B, up to the end of the 7.28 GiB eMMC). Keep `recovery` as `recovery-backup.img` in the project root.

## 2. Get your MAC addresses (Wi-Fi and Bluetooth)

While Android still runs (adb enabled): `adb shell getprop ro.boot.wifimac` and `adb shell getprop ro.boot.btmacaddr`. Then:

```
cp kernel/macs.env.example kernel/macs.env     # then edit: WIFI_MAC=..., BT_MAC=...
```

(Without it Wi-Fi gets a random MAC every boot and the Bluetooth controller stays unconfigured/invisible.)

## 3. Download the userspace parts

```
arch-work/fetch.sh
```

Downloads and checks the Arch Linux ARM aarch64 tarball (md5), the BCM43456 Wi-Fi firmware and the BCM4345C5 Bluetooth patch file.

## 4. Build the kernel + recovery image

```
tar -xf kernel/linux-6.12.114.tar.xz -C kernel          # sha256 in kernel/dl.sha
patch -d kernel/linux-6.12.114 -p1 < kernel/patches/mibox-6.12.114.patch
cp kernel/mibox.config kernel/linux-6.12.114/.config
nohup kernel/build.sh recovery-work/recovery-mine.img > kernel/build.log 2>&1 &     # ~10-20 min cold; build.sh must run non-interactively
make -C kernel/linux-6.12.114 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules && kernel/make-modroot.sh   # modules into kernel/modroot (release 6.12.114-ophub)
```

What the patch contains: embedded-DTB hook (`setup.c`, `mibox_dtb.S`), the board DTS (`meson-gxl-s905x-mibox.dts`: p212 base + Mi Box specifics, ramoops
matching the vendor layout, USB role/VBUS, MAC placeholders) and a fix in `net/socket.c` (this tree has L2CAP on `->getsockopt_iter` but no
dispatcher, which makes `bluetoothd` fail with "getsockopt(L2CAP_OPTIONS): Operation not supported"). `build.sh` also enables Landlock (needed by pacman 7's
download sandbox), sets the command line (1080p forced, `blkdevparts` for `userdata`, USB-stick quirk) and patches your MACs into the DTB.

## 5. Build the Arch root image

```
sudo bash stick-setup/build-arch-userdata.sh        # asks hostname, root password, Wi-Fi SSID/passphrase (typed silently)
```

Non-interactive: `HN=mibox ROOTPW=... WIFI_SSID=... WIFI_PSK=... sudo -E bash stick-setup/build-arch-userdata.sh`. Extra packages: `PKGS="iwd bluez bluez-utils vim" ...`.
Output: `userdata-work/userdata-arch.img` (2 GiB ext4, UUID fixed, label ALARM). It contains the extracted tarball, `iwd` (Wi-Fi association + profile) with `systemd-networkd` doing DHCP, `bluez`/`bluez-utils`
(service enabled), `sshd` (root login with password enabled), `systemd-resolved`, `systemd-timesyncd`, the Broadcom firmware, our modules, and a first-boot pacman keyring init.
One `call to execv failed (Exec format error)` near the end is pacman trying to run the aarch64 `ldconfig` on the PC and is harmless.

## 6. Flash (three burn-mode sessions)

Each command needs the box freshly in burn mode (`lsusb` shows `1b8e:c003`); each one verifies by reading the partition back and comparing byte for byte.

```
flash-tools/flash-part.sh userdata userdata-work/userdata-arch.img      # session 1: root filesystem
flash-tools/flash-recovery.sh recovery-work/recovery-mine.img           # session 2: kernel
mkdir -p misc-work   # (see below how to create the image)
flash-tools/flash-part.sh misc misc-work/misc-boot-recovery.img         # session 3: always boot Linux (misc = stock misc + "boot-recovery")
```

`flash-part.sh` whitelists `recovery`, `logo`, `misc`, `userdata` only. (`misc-boot-recovery.img` = **your own** backed-up `misc` (8 MiB) with `boot-recovery\0` written at offset 0:
`cp backup-emmc/parts/misc.img misc-work/misc-boot-recovery.img && printf 'boot-recovery\0' | dd of=misc-work/misc-boot-recovery.img conv=notrunc`.
Until `misc` is set you can still boot the Linux recovery manually with Back+Center on the remote at power-on.) Optional: `logo` (see `logo-work/make_logo.py`) for a custom boot logo.

## 7. First boot

Power-cycle. HDMI shows the boot log and a login prompt (root + the password you set); Wi-Fi joins by itself, so try `ssh root@<ip>` (find the IP in your router, or `ip a` on the box). Then:

```
resize2fs /dev/mmcblk1p1          # grow the 2 GiB image to the full 5.2 GiB partition
pacman -Syu                       # the keyring is initialised on first boot (needs the clock; timesyncd sets it once online)
bluetoothctl                      # power on / scan on
```

## 8. Troubleshooting

* **Wi-Fi: no `wlan0`:** `dmesg | grep brcmfmac`; the log should name `brcm/brcmfmac43456-sdio.*` firmware; it must exist in `/usr/lib/firmware/brcm/`.
* **Bluetooth: `bluetoothctl list` empty:** `dmesg | grep hci0`; needs `BCM4345C5.hcd` and a real address (macs.env). `strace -f -o /tmp/t bluetoothd -n` shows the failing syscall.
* **Clock wrong / TLS errors:** there is no RTC; `timesyncd` sets the time once `networkd` reports the network online (`grep ONLINE /run/systemd/netif/state`, `timedatectl timesync-status`). Wi-Fi DHCP must be done by networkd (`20-wlan.network`), not by iwd.
* **pacman: Landlock error:** kernel without `CONFIG_SECURITY_LANDLOCK`; temporary workaround `pacman --disable-sandbox`.
* **`pacman -Syu` and the kernel:** `linux-aarch64` is on `IgnorePkg`; the kernel is the `recovery` partition image, not a package. Never `pacman -S linux-aarch64`.
* **Nothing on screen / wrong mode:** command line forces `video=HDMI-A-1:1920x1080@60e` (edit in `kernel/build.sh`).
* **A USB stick is slow/unreliable on this kernel** (quirk `usb-storage.quirks=13fe:6300:m` is for one Phison stick); the rootfs lives on eMMC, so that doesn't matter for normal use.
* Boot-time kernel log survives a reboot via ramoops (vendor layout), readable under Android with `adb shell su -c cat /sys/fs/pstore/console-ramoops-0`.

## 9. Restore / rescue

Burn mode is always available (it is in the boot ROM; nothing here touches it).

```
flash-tools/flash-part.sh userdata backup-emmc/parts/userdata.img     # session 1: your backed-up userdata
flash-tools/flash-part.sh misc backup-emmc/parts/misc.img             # session 2: remove the boot-recovery flag
flash-tools/flash-recovery.sh recovery-backup.img                     # session 3: stock recovery
```

(`logo` likewise from your `logo.img` backup.) If you also flashed a custom `super`, restore it the same way (`update partition super <file> normal`) — we never touched `super`.

## Files

| Path | What |
|---|---|
| `arch-work/fetch.sh` | downloads/verifies tarball + firmware |
| `flash-tools/setup.sh` | fetches third-party burn tools (pyamlboot, Khadas utils) |
| `logo-work/make_logo.py` | optional custom boot logo (`logo` partition) |
| `docs/ENGINEERING-LOG.md` | engineering log (research, dead ends) |
| `kernel/build.sh`, `kernel/patches/`, `kernel/mibox.config`, `kernel/macs.env`, `kernel/nk/` | kernel build, patch, config, per-box MACs, initramfs `/init` source |
| `recovery-work/mkimg_new.py`, `mkinitramfs.py` | assembles the boot image from your stock recovery |
| `stick-setup/build-arch-userdata.sh` | builds the Arch `userdata` image |
| `flash-tools/` | burn-mode flashing (`flash-part.sh`, `flash-recovery.sh`, `stage1.py`) with read-back verification |
| `docs/ENGINEERING-LOG.md` | full engineering log (dead ends included) |
