# Mi Box S (MDZ-22-AB) – full history of the recovery + dual-boot effort

Hardware: Xiaomi Mi Box S, Amlogic S905X-H (GXL), secure boot, 2 GB RAM, 8 GB eMMC, one USB-A port (OTG).
Host: Arch Linux PC, project dir `<project>` (moved from `<old-windows-project>`, which no longer exists).
Scratchpad (temporary files, lost between sessions): `<scratch>` (called `$S` below). **The old scratchpad (custom 6.12 kernel source, `mibox.dtb`, `recovery-new1..9.img`, pyamlboot, `stage1.py`) is gone.** Keep anything that matters in the project dir (`recovery-work/`, `flash-tools/`).

**Hard rules we kept all the time**
- Never write the bootloader, never erase/wipe anything (user fear: losing Netflix DRM certificates).
- Only the `recovery` partition was written after the box was restored. Every write is read back and compared byte for byte.
- `misc` is never set to `boot-recovery`. Normal power-on always boots Android. Recovery is entered with Back+Center on the remote.
- Stock `recovery` backup: `recovery-backup.img` (byte-identical to the one in the Android 12 OTA). Clean `misc`: `misc-backup.img`.

---

## Part 1 – The brick and the rescue (DONE, box works)

**Start.** User flashed a Linux image into the `recovery` partition from rooted Android 12, and the box got stuck on the Mi logo. They wanted to restore old Android (r363 "orange point" image) from Linux, using the image and `password/password.bin` in the project dir.

**Real cause of the brick.** The box was never bricked at bootloader level:
- `misc` held a `boot-recovery` flag, so every boot went into `recovery`.
- `recovery` held a Linux image that never booted. Result: infinite Mi logo, and no way to clear the flag from Android.

**Tooling.**
- USB burn mode shows up as `1b8e:c003`. Entered by the user via power-cycle into burn mode.
- Khadas prebuilt `update` tool (`$S/khadas/utils/aml-flash-tool/tools/linux-x86/update`), plus a cloned pyamlboot (`$S/pyaml`) for a Python loader stage (`$S/stage1.py`).
- Needed `libusb-0.1` and a udev rule (user ran pacman/udev commands).
- The permission classifier blocked running downloaded binaries. User approved and added allow rules in `.claude/settings.local.json` (offered to delete it later).

**Loading U-Boot into RAM (what finally worked).**
- Box is secure-boot: only signed `_ENC` loaders run. `rreg 4 0xc8100228` = 0xbdfd71be, bit 0x10 set.
- The r363 `DDR_ENC.USB` / `UBOOT_ENC.USB` crash in DDR init on this board.
- Fix: split the Android 12 OTA `bootloader.img` (1442304 bytes) at 49152: first 49152 = bl2, rest = tpl. This works as USB loader (`stage1.py ota`).
- Flow: `update password password.bin` (every power cycle) → identify → write bl2 to 0xd9000000 → write ddrinit params to 0xd900c000 → run → (stage 8 → run 0xd900c000) → write bl2/fip params/u-boot (0x200c000) → run. Then U-Boot answers `bulkcmd`.
- `bulkcmd "disk_initial 0"` initialises storage without wiping. After that `mread store <part> normal <size> <file>` and `partition <name> <file> normal` work.

**Rescue steps.**
1. Dumped `misc` (had `boot-recovery`) and the broken `recovery` into `backup-from-box/`.
2. Wrote the stock `recovery` back (verified) and a clean `misc` (verified). Bootloader/DRM areas untouched.
3. User confirmed: Android 12 boots, "everything's fine".

**Mistakes / lessons from this phase**
- My USB reset script made the box vanish (xhci -71); only a power cycle into burn mode recovered it.
- `pkill -f` killed my own shell; truncating output with `tail` lost which step failed → log to files.
- `update bulkcmd` strings: a long `setenv bootargs` crashed the burn-mode U-Boot (box dropped off USB). I first blamed a 64-byte buffer, but even a 53-char `setenv` later reset the box: the burn-mode U-Boot dies on `setenv`/`hdmitx` commands. Do not use them.

---

## Part 2 – Dual boot idea

User asked for something like GRUB: Linux on a USB drive, with a boot-time choice. The stock bootloader can't be changed (DRM!), so the chosen plan: put a small Linux (kernel + DTB + initramfs with a busybox menu) in the `recovery` partition, rootfs on a USB drive (Armbian `armbian-s905x.img`, partition 2 ext4 UUID `d1822960-1a0a-4525-8be2-cbe35efcfc59`), menu: Linux (USB) / Android (reboot) / shell. Normal boot stays Android.

Why the earlier Armbian-in-recovery image likely failed: it had no initramfs (needs `root=UUID=`), and, as found much later, the DTB wasn't picked up and USB/eMMC didn't come up.

### RAM-boot tests in burn mode (all failed to show anything)
- Loaded DTB (0x1000000), initramfs (0x13000000) and the decompressed ophub Image (0x1080000) with `mwrite ... mem <addr> normal`, then `booti`.
- `booti ... <initrd:size>` was rejected. Putting `linux,initrd-start/end` into the DTB with `fdt set` made `booti` launch (box dropped off USB), then the box rebooted into Android, no output visible.
- Conclusion: burn-mode U-Boot has no display init (`hdmitx hpd` crashes it), so RAM tests are blind. Moved to flashing `recovery` and booting with Back+Center.

---

## Part 3 – Flashing recovery images and learning the boot format

Flash procedure used every time: burn mode → `password` → `stage1.py ota` → `bulkcmd "echo 12345"` → `bulkcmd "disk_initial 0"` → `partition recovery <img> normal` → `mread store recovery normal 25165824 <file>` → `cmp`.

Findings, in order:
1. **Entry to recovery:** the box has no reset button. Back+Center on the remote at power-on enters recovery (works; confirmed with a stock image carrying a one-byte change).
2. **Signature check:** the stock image has an AVB footer, but a modified recovery boots fine (one byte changed in an unused header field booted normally). The box does not enforce AVB on `recovery`. `vbmeta` flags = 0 and does not mention `recovery`.
3. **Header layout:** stock recovery = Android boot image v2, page 2048: kernel (gzip, 9.8 MB) @ 0x1080000, ramdisk (gzip cpio), `second` = Amlogic multi-DTB container (180224 bytes), `recovery_dtbo` (438 bytes), `dtb` field = same container. Total equals AVB `orig_size` 21436416.
4. **Liveness test:** init that reboots after N seconds. Measured ~100 s with a 100 s timer and ~45 s with a 40 s timer → kernel and `/init` really run. (Earlier I wrongly suspected a watchdog.)
5. USB stick never got a log file; eMMC marker-region log never got written; USB gadget serial (`g_serial` via `insmod`) never appeared on the PC; display stayed on the Mi logo. All of these were symptoms of the wrong DTB (see below), not independent bugs.
6. DTB facts: the stock Android DTB uses `gpio-vbus-power = GPIOAO_4` (variants dcdc/usbwifi) or `GPIOAO_3` (pmic) for USB 5V. The ophub p212 DTB has no USB VBUS regulator.

### Marker region trick (still in every image)
Recovery images carry a 2 MiB region at offset 18 MiB with sectors tagged `MBLOG<sector#>` so `/init` could write a log into free space inside `recovery` and I could read it back in burn mode. It never worked because eMMC is not visible to the kernel with the wrong DTB. Read-back code: `mread store recovery`, take bytes 18 MiB..20 MiB.

---

## Part 4 – Custom kernel + ramoops

Reason: with no UART the ophub kernel can't leave a log. Built our own.
- Source: Linux 6.12.114 from cdn.kernel.org (sha256 `7a8589912bd7a8adb07fed074283652cf482a35facef8954554654f0154b4af3`), extracted to `$S/ksrc/linux-6.12.114`.
- Config: the ophub config embedded in its Image (IKCFG), plus `PSTORE_RAM`, `PSTORE_CONSOLE`, `PSTORE_PMSG`, `USB_G_SERIAL` built in, `LOCALVERSION=-mibox`, BTF off. Toolchain: `aarch64-linux-gnu-gcc` and `bc` installed by the user via pacman.
- DTB: `arch/arm64/boot/dts/amlogic/meson-gxl-s905x-mibox.dts` = p212 + `ramoops@7400000` (1 MiB, the same area the stock firmware reserves) + `regulator-usb-vbus` on `GPIOAO_4` (always on) + `max-reason = <4>`.
- Images and files live in `$S/nk/` (`Image`, `Image.gz`, `mibox.dtb`, `aml-container.bin`, `init`, `mkinitramfs.py`, `recovery-newN.img`).
- Android side: `adb` over USB works after authorising on the TV (user installed `android-tools`). Reading a log: `adb shell "su -c 'cat /sys/fs/pstore/console-ramoops-0'"`.

### Big finding (run 1/2, `recovery-new1/new2`)
The ramoops log of the first custom-kernel boot showed:
- `Machine model: Amlogic`, vendor reserved-memory nodes, and the **stock kernel command line** (`aml_dt=gxl_oneday`, `console=ttyS0`, `earlycon=aml_uart,...`, `logo=osd1,loaded,0x3d800000,2160p60hz`). So U-Boot loaded **its own vendor DTB** and ignored mine.
- Result with a vendor DTB: `gxbb-clkc ... failed to get HHI regmap`, no USB, no mmc, no drm. The kernel and `/init` ran fine (`MBOX: init started`, clean reboot at ~42 s).
- Android's pstore layout equals ours (console 256 KiB, record 128 KiB, ftrace 512 KiB, pmsg 128 KiB at 0x7400000), so that was not the problem.

### DTB container
Amlogic multi-DTB container format: header `AML_`, version 2, count 3; three 56-byte entries (three 16-byte names stored as byte-swapped words: `gxl`, `oneday`, variant `dcdc`/`pmic`/`usbwifi`; then 4-byte offset and 4-byte size), slots at 0x800, 0xf000, 0x1d800 of 0xe800 bytes each. I copy the stock container and put `mibox.dtb` in all three slots.
- `new2` (container only in `second`) → U-Boot still used the vendor DTB.
- `new3` and later (container in `second` **and** in the `dtb` field, plus the stock `recovery_dtbo`) → my DTB is used (the console log changed). Layout must match stock exactly.

### Log capture attempts with my DTB (all failed to give the log)
- `new3`–`new7`: console zone only contained the last line (`reboot: Restarting system`); no dmesg dump record even with `max-reason = <4>`; no pmsg file; no eMMC log; no USB log.
- `new6`: deliberate panic (`sysrq c`, `panic=1`) → box hung on the logo; quick power flick (about 1 s) lost the RAM.
- `new8`: wrote a colour-band calibration pattern into the U-Boot logo framebuffer (`0x3d800000`, 1920x1080x4) via `/dev/mem`. Nothing appeared on screen (cause unknown: wrong address, cache, or write failure).
- Conclusion: still blind. Decision: use a UART.

---

## Part 5 – UART (parked, pads not confirmed)

- User has an ESP32 dev board to use as a 3.3 V USB-serial adapter (EN/RST to GND so the ESP32 stays silent; ESP `RX` to box `TX`, ESP `TX` to box `RX`, GND to GND, no power lines).
- Pads on the Mi Box S: forum photo `mibox-photos/uart-location-from-forum.png` marks three round pads RX / TX / GND (plus a 4th, bigger, outlined pad) at the lower left of the board, left of the big plate, level with the plate's port-side edge, with ports at the bottom. In `mibox-photos/my-pcb.jpg` (ports on the right, protection plate removed, RAM shield visible) the same trio is a cluster of three orange pads near the port edge. When rotated to match, the cluster's diagonal looks mirrored against the forum photo, so the RX/TX/GND order is NOT confirmed. User measured 2.7 V, 0 V and 0.35 V on the three pads (which was which was not recorded). Never wired up yet. The row pads at the board edge (top edge in `my-pcb.jpg`) are probably not UART.
- Kernel rebuilt with `CONFIG_CMDLINE_FORCE` = `earlycon=meson,0xc81004c0 console=ttyAML0,115200n8 console=tty0 loglevel=8 ignore_loglevel no_console_suspend rdinit=/init`, because the stock U-Boot command line has `console=ttyS0` and `earlycon=aml_uart`, which mainline does not understand.
- Image ready, **not flashed yet**: `$S/nk/recovery-new9.img` (new kernel, same DTB container, `/init` starts a root shell on `/dev/ttyAML0` and `tty0`, self-reboot after 10 minutes).
- Next: user wires the ESP32 → I flash `recovery-new9.img` (burn mode) → user boots recovery (Back+Center) → I read `/dev/ttyUSB0` at 115200 and fix whatever the kernel log shows (USB, eMMC, display).

---

### ESP32 oscilloscope (parked)
- To identify the pads, user's ESP32 WROOM-32 was flashed with BojanJurca/Esp32_oscilloscope (clone in `esp32-oscilloscope/`, built with `arduino-cli` + ESP32 core 3.3.12 + libs `ESP32_Multitasking_Network_Suite`, `ThreadSafeFS`, `LightweightSTL`). Web UI at `http://<esp32-ip>/oscilloscope.html` (SSID `<ssid>`, password set by the user in `server_config.h`), probe on ADC1 pins GPIO 32-39 (use 34/35), 3.3 V max, shared GND.
- Page served from RAM (84 KB) gave `[httpConn] out of memory`; fixed by `USE_FILE_SYSTEM` + a LittleFS image (`mklittlefs`, `/var/www/html/oscilloscope.html`) flashed at 0x290000.
- User found it clunky; we dropped it for now and went for the stock-kernel route below.

## Part 6 - Stock recovery analysis and the stock-kernel route (CURRENT)

**Idea.** Stop fighting the blind mainline kernel; study what the stock recovery kernel does and reuse it. Unpacked `recovery-backup.img` with my own Python tools in `recovery-work/` (`unpack.py`, `cpio_x.py`, `patch_cpio.py`, `mkimg.py`); `mkimg.py` self-test reproduces the stock image byte for byte (first 21436416 bytes).

**Stock recovery facts.**
- Boot image v2, page 2048. Kernel = Amlogic vendor Linux **4.9.269** (Xiaomi, GCC 4.9, Oct 2023), embedded config saved as `recovery-work/stock-kernel.config`.
- Header cmdline: `androidboot.dynamic_partitions=true androidboot.dtbo_idx=0 androidboot.boot_devices=d0074000.emmc otg_device=1 buildvariant=user`.
- Ramdisk (21 MB) is a full Android ramdisk: `init` -> `/system/bin/init`, `recovery`, `adbd`, `fastbootd`, `systemcontrol_static`, `busybox`, `toybox` tools, `init.recovery.amlogic.rc` (USB gadget via configfs, `sys.usb.controller` = `c9100000.dwc2_a` from `vendor.usb.controller`), only 2 `.ko` (bt).
- Display: `AMLOGIC_VOUT`, `AMLOGIC_HDMITX`, `AMLOGIC_MEDIA_FB` (OSD fbdev, no DRM, no fbcon). HDMI mode is set by userspace `systemcontrol_static /sbin/mesondisplay.cfg` (`MBOX gxl 1080p`).
- USB: Amlogic dwc2 OTG at `c9100000.dwc2_a` (gadget), dwc3/xhci host, PHYs `usb2phy@d0078000`, `usb3phy@d0078080`; own `AMLOGIC_USB_DWC_OTG_HCD`; stick support FAT/exFAT/NTFS/ext4, `USB_STORAGE`, `BLK_DEV_SD`. eMMC = Amlogic MMC driver `emmc@d0074000`.
- No `CONFIG_KEXEC` (cannot kexec mainline from it). Has CGROUPS, NAMESPACES, OVERLAY_FS, PSTORE_RAM.

**Facts from the live dump (boot of a recovery image carrying `mibox-dump.sh`).**
- The box boots DTB variant **`gxl_oneday_pmic`** (`aml_dt=gxl_oneday_pmic`). In the pmic DTB the VBUS GPIO is **`GPIOAO_3`** (dcdc/usbwifi variants: AO_4). Our old mainline DTB used AO_4, which was wrong for this box.
- Display mode is 4K: `vout=2160p60hz hdmimode=2160p60hz hdmitx=,420,10bit logo=osd1,loaded,0x3d800000,2160p60hz`. The old framebuffer test assumed 1920x1080 (explains the missing pattern).
- Kernel cmdline from U-Boot also has `console=ttyS0,115200 earlycon=aml_uart,0xc81004c0`, `loglevel=1`, `androidboot.selinux=` empty (init ignores permissive).
- SELinux is enforcing in recovery. With `ro.debuggable=1`, `adbd` tries to switch to `--root_seclabel=u:r:su:s0`; policy denies `setcurrent`, `adbd` aborts (signal 6) and init restarts it every 5 s (`init.svc.adbd=restarting`). It never opens its FunctionFS endpoints, so the PC never sees a USB device. Root-domain reads of `/sys/class/udc/*/state` and `/config` are also denied for the `recovery` domain.

**Work done (all verified by read-back).**
- Rebuilt flashing tools in `flash-tools/`: Khadas `update` (`khadas/aml-flash-tool/tools/linux-x86/update`), pyamlboot clone (`pyaml/`), `stage1.py` (rewritten from this log, loads bl2+tpl from `ota-bootloader.img`), `flash-recovery.sh <image>` (burn mode -> password -> stage1 -> `bulkcmd` echo + `disk_initial 0` -> `partition recovery` -> `mread` read-back -> `cmp`; refuses non-25165824-byte images). Needs a venv with `pyusb` (was in the scratchpad: `python3 -m venv ... && pip install pyusb`). **Burn mode must be re-entered for every session**: a second `stage1.py` in the same session fails with a USB I/O error.
- The permission classifier blocks running the downloaded `update` binary until the user adds an allow rule (user did).
- `recovery-adb1.img`: stock kernel/DTB, ramdisk with `ro.secure=0`, `ro.adb.secure=0`, `ro.debuggable=1`, `sys.usb.controller=c9100000.dwc2_a`, `sys.usb.config=adb`. Flashed and booted, no adb on the PC (cause above).
- `recovery-dump*.img`: same plus `/sbin/mibox-dump.sh` started by a service at boot. It snapshots dmesg, /proc, kernel config, props, USB/UDC/gadget state, fb/HDMI, debugfs, then writes a tar.gz to the **tail of the recovery partition at 22 MiB** (header `MIBOXDMP` + 8-digit size; checked against partition size 25165824 before writing) and to a USB stick (`MIBOX-DUMP-<n>`; runs `run.sh` from the stick, output in `run.out`). A white band (ok) or stripes (bad) is drawn on fb0 at the end. Read-back in burn mode: `update mread store recovery normal 25165824 file`, take bytes from 22 MiB. `dump3` flashed, worked (no stick), box rebooted by itself.
- `recovery-adb2.img` (built, verified, **not flashed yet**): dump script (devicetree capture bug fixed, no auto-reboot unless the stick has a `reboot` file) plus `adbd` service line without `--root_seclabel`. Kernel, DTB container, `recovery_dtbo` byte-identical to stock; only the ramdisk differs. Attempt to flash failed (box was still in the post-loader state); needs a fresh burn-mode entry.

**Decision rationale.** Both the old mainline kernel and display problems point to missing/wrong hardware description (VBUS GPIO, 4K framebuffer, USB controller). The stock 4.9 kernel has working drivers; a vendor-kernel userspace boot or a corrected mainline DTB are the two ways forward. Building the 4.9 vendor tree needs a source release (Xiaomi GPL or CoreELEC `amlogic-4.9`) and an old GCC.

**ADB IN RECOVERY WORKS (`recovery-work/recovery-adb5.img`, flashed 2026-11-10).** `adb devices` -> `recovery`, `adb shell` is root, kernel 4.9.269. Root causes found, in order:
1. `adbd` aborted in a loop: with `ro.debuggable=1` it tried `--root_seclabel=u:r:su:s0` and SELinux denied `setcurrent`. Fix: removed `--root_seclabel` from the `adbd` line of `system/etc/init/hw/init.rc`.
2. SELinux still hid most of /proc, /sys, /config from the dump script. Fix: patched `/sepolicy` (v30 monolithic binary policy) with `recovery-work/patch_sepolicy.py`: sets the permissive bit for the types `recovery adbd init shell kernel ueventd charger fastbootd` (rewrites only the permissive_map ebitmap after the header; `getenforce` still says Enforcing, denials in those domains are logged with `permissive=1`).
3. The gadget was bound (`UDC=c9100000.dwc2_a`, FunctionFS ready) but the port stayed `not attached` and the box drove VBUS high (`gpio-504 (d0078080.usb3phy) out hi`). Android's `/vendor/etc/init/hw/init.amlogic.usb.rc` does `write /d/aml_reg/paddr "0xc883443c 0xFDFFFFFF"` for `sys.usb.config=adb` (register reads back 0xFDFFFFFF in Android; `0xFD7FFFFF` for config none); the stock recovery rc only does it for fastboot. Added the same write for adb in `init.recovery.amlogic.rc`. Result: UDC `configured`, VBUS GPIO low.
Comparison facts from Android (adb over the same A-to-A cable): UDC `configured/high-speed`, same `otg_device=1`, same `dwc_otg ... SLAVE`; Android also runs `vendor.usb-hal-1-0` (dual_role_usb) and `vendor.usb-gadget-hal-1-2` (configfs), neither touches VBUS. dwc_otg sysfs controls at `/sys/devices/platform/c9100000.dwc2_a/` (`mode busconnected buspower gotgctl gusbcfg peri_*`).
`recovery-adb5.img` keeps the dump service (tail dump at 22 MiB) and still has no auto-reboot. SECURITY NOTE: this recovery has unauthenticated root adb and a permissive-patched policy; it only runs when booted with Back+Center, normal power-on is Android.

### U-Boot USB boot path with the Armbian stick (tested, NOT working yet)
- U-Boot env read from `/dev/block/env` (2 copies): `bootcmd=run storeboot`; `update=run usb_burning; if usb start 0; then run recovery_from_udisk; fi; run recovery_from_flash;` `recovery_from_udisk` = fatload `aml_autoscript` (autoscr) / `recovery.img` + optional `dtb.img` at `loadaddr=1080000`, `dtb_mem_addr=0x1000000`, then `wipeisb; bootm`. `switch_bootmode` ends with `if monitor_bt_cmdline; then run update; fi;`. Other vars: `lock=10100000` (meaning unknown), `usb_burning=update 500 550`.
- Display vars: `fb_addr=0x3d800000 fb_width=1920 fb_height=1080 display_bpp=24 display_layer=osd1 hdmimode=2160p60hz`; stdout/stdin/stderr = serial. In the vendor recovery fb0 = 1920x1080 BGRA32, virtual 1920x2160, stride 7680; banner drawn with `dd` to `/dev/graphics/fb0` (works live).
- DANGER found: the Armbian/ophub `aml_autoscript` on the stick does `setenv bootcmd ...; saveenv; reboot`. Renamed to `aml_autoscript.off` (user approved) and replaced by a harmless probe script (`echo`, `osd open/clear`, `fatload usb 0 probe.bmp; bmp display`, `sleep 8`). Stick (BOOT, FAT32) also holds `recovery.img` (= `recovery-usbtest.img`: adb5 + magenta "BOOTED FROM USB STICK" banner loop + `ro.mibox.bootsrc=udisk` marker) and `probe.bmp`.
- Tests: (1) Back+Center with stick: normal flash recovery, no banner, no MIBOX-DUMP on stick. (2) .bmp probe: nothing shown. (3) `adb shell reboot update` with stick (U-Boot received `reboot_mode=update`, cmdline `androidboot.reboot_mode=update`): still the flash recovery, `ro.mibox.bootsrc` empty. Back+Center boot reason is `cold_boot` (bypasses `update`).
- In all cases the vendor kernel then enumerated the stick fine (`USB DISK 3.0`, Phison, usb-storage, 2.7 s), so hardware/port are OK. Candidates: U-Boot 2015.01 host doesn't enumerate this USB3 stick, `update` only means "flash recovery + OTA", or the files are rejected. Only one stick available, so no A/B test. To decide: read `update`/`recovery_from_udisk` handling from the bootloader image, or get UART.
- Bug: `mibox-dump.sh` band uses `/sbin/busybox tr` -> "Permission denied" (cpio entry not executable); this is why the done-band never showed.

## Part 7 - Mainline kernel again, with what the stock kernel taught us (CURRENT)
- Everything kernel-related now lives in the project (an earlier scratchpad copy in /tmp was lost): `kernel/linux-6.12.114/` (source + build objects, incremental rebuilds; tarball + `dl.sha` beside it), `kernel/mibox.config` (= ophub config from `armbian-recovery.img`'s embedded IKCFG + `PSTORE_RAM/CONSOLE/PMSG`, `USB_G_SERIAL=y`, `USB_DWC2_PERIPHERAL`, `CMDLINE_FORCE` with console=tty0/ttyS0, `clk_ignore_unused pd_ignore_unused`, ramoops params, BTF off, `LOCALVERSION=-mibox`), `kernel/nk/` (`init.c`, `rd.cpio.gz`, `Image.gz`).
- Build: `cd kernel/linux-6.12.114 && make -j12 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image amlogic/meson-gxl-s905x-mibox.dtb`; DTS = `arch/arm64/boot/dts/amlogic/meson-gxl-s905x-mibox.dts` (p212 + ramoops@7400000 + framebuffer reservation + simple-framebuffer 1920x1080 a8r8g8b8 stride 7680 @0x3d800000, hdmi_tx/vpu/cec disabled so nothing takes over U-Boot's display, usb/dwc2 = peripheral, dwc3 disabled).
- Image: `recovery-work/mkimg_new.py ../recovery-backup.img Image.gz rd.cpio.gz mibox.dtb out.img` (stock image layout, DTB in all 3 container slots in `second` and `dtb`), `mkinitramfs.py` (newc cpio: `/init`, static 32-bit ARM busybox from the stock recovery + symlinks).
- Why the old attempts were blind (found via the stock kernel): (1) my old `new8` pattern used `/dev/mem`, which the old kernel config may not have given a usable path to; (2) USB needs the Android write `0xFDFFFFFF` to `0xc883443c` and VBUS is GPIOAO_3 (not AO_4); (3) vendor fb0 is BGRA32 stride 7680; U-Boot env says `display_bpp=24` so the U-Boot scanout format is still unverified.
- `/init` (static aarch64): mounts proc/sys/dev/pstore, `/dev/mem` write of `0xFDFFFFFF` to `0xc883443c` (at start and again after 5 s), paints red/green/blue/white bands (top to bottom) at `0x3d800000`, starts busybox shells on `/dev/ttyGS0` (USB gadget serial) and `/dev/tty0`, logs `MIBOX:` lines to kmsg (ramoops), reboots after 1 h.
- `recovery-work/recovery-new10.img` built and flashed (see results below).
- RESULTS new10/new11: new10 = Mi logo hangs, no log (ramoops layout mismatch: my DTB had `ftrace-size 0`, stock/Android reads 128K dump + 256K console + 512K ftrace + 128K pmsg). new11 (stock layout, `/init` reboots after 20 s into Android; read with `adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0'`) gave a FULL boot log: kernel boots, `/init` runs, paints 0x3d800000, USB reg `0xc883443c` reads `ff7fffff` -> written `fdffffff`; nothing visible on screen. BUT the kernel ran with the **vendor DTB** (`Machine model: Amlogic`, vendor reserved-memory, `gxbb-clkc: failed to get HHI regmap`, `g_serial: couldn't find an available UDC`). Vendor DTBs carry `amlogic-dt-id = "gxl_oneday_pmic"` in the root node; mine lacked it -> U-Boot apparently falls back to its own DTB. new12 adds the property (and keeps the 20->40 s on-screen time).
- new12 (added `amlogic-dt-id`): still vendor DTB. `recovery-dtprobe.img` (adb5 with the `model` string of all 6 container slots changed to `AmlTst0/1/2`) still booted with model `Amlogic` -> on the flash-recovery path U-Boot's `bootm` takes its DTB from elsewhere (no `dtb` partition exists; probably Amlogic reserved storage / U-Boot) and ignores the boot-image container. We never write those, so: **the kernel embeds its own DTB** (`arch/arm64/kernel/setup.c`: `setup_machine_fdt()` uses `mibox_dtb_start` from `arch/arm64/kernel/mibox_dtb.S` (`.incbin mibox.dtb`)), and the initramfs is embedded too (`INITRAMFS_SOURCE`, since U-Boot would pass the initrd via its own DTB). Build everything with `kernel/build.sh <out.img>` (copies the DTB, rebuilds, assembles image; non-interactive: `olddefconfig </dev/null`).
- new13 (embedded DTB): log shows `Machine model: Xiaomi Mi Box S`, clkc fine, eMMC `mmcblk1` 7.28 GiB HS200, SDIO Wi-Fi card on mmc2, dwc2 `c9100000` bound `g_serial`, PC enumerated "Gadget Serial v2.4" (`0525:a4a7`, `/dev/ttyACM0`). simplefb painting at 0x3d800000 was never visible.
- **new14 = MILESTONE**: DRM/HDMI enabled in the DTB (p212 base: `hdmi_tx`, `vpu`, `cec_AO`; simplefb removed) -> **fbcon penguins on the TV**, `/dev/dri/card0`, `/dev/fb0` (`mesondrmfb`), ethernet `meson8b-dwmac` present, and `/init` keeps a respawning busybox shell on `/dev/ttyGS0` -> PC: `/dev/ttyACM0` (helper: scratchpad `ser.py "cmd" [wait]`; set `PATH=/bin` first). No UART needed any more. USB is currently gadget-only (`dr_mode = "peripheral"`).
- Next: host mode on the single port (VBUS GPIOAO_3), mount the Armbian stick's ext4 ROOTFS and `switch_root`/`pivot` into it (mainline kernel + Armbian userspace); network over ethernet for ssh.

- Reading the previous boot's log: after a self-reboot to Android (`reboot` with no key held), pstore is in `/sys/fs/pstore/console-ramoops-0`, needs `su`.

## Part 8 - Full eMMC backup (DONE, verified)
- Taken on 2026-11-10 from the adb recovery (`recovery-adb5.img`), read-only, into `backup-emmc/` (1.8 GB on the Data drive): `mmcblk0.img.zst` (raw 7,818,182,656-byte image of the whole user area, zstd -3; `zstd -t` passes; raw SHA-256 in `mmcblk0.raw.sha256`), `mmcblk0boot0.img` / `mmcblk0boot1.img` (4 MiB each, identical to each other: bootloader copies), `manifest.txt` (partition names/offsets/sizes from the vendor kernel log + `by-name`), `segments.txt` (35 segments = partitions + gaps), `parts/*.img` (bootloader, reserved, cache, env, tee, metadata, vbmeta, logo, recovery, misc, dtbo, cri_data, param, boot, rsv) and `SHA256SUMS`.
- Verification: per-segment SHA-256 computed from the dump on the PC and again on the box afterwards: 34 of 35 segments identical (incl. super, system_ext, userdata, cache, env, boot, vbmeta, tee, misc, gaps). Only `recovery` differs, and only in the tail at 0x1600000-0x1651fff (the adb image's own dump-service log); first 22 MiB equals `recovery-adb5.img`. So the whole-disk SHA from the box differs from the PC's for that reason only. The stock recovery is `recovery-backup.img` (the dump's `recovery` is adb5, not stock).
- Not dumped: `rpmb` (hardware-protected, cannot be restored anyway), big partitions as separate files (`system_ext`, `super`, `userdata` can be sliced from the raw image by offset: `zstd -d -c mmcblk0.img.zst | dd iflag=fullblock bs=1M skip=<off MiB> count=<size MiB>`; use `iflag=fullblock`, plain dd on a pipe returns short reads).
- Earlier 1 MiB backups in `backup-from-box/` match for `dtbo` and `logo`; `tee` (9 bytes differ from byte 1069), `param` (35 bytes) and `misc` changed since (normal runtime state; we never wrote tee/param).
- Restore plan: burn mode + `partition <name> <file> normal` per partition (the proven path used for `recovery`); never write `bootloader`/`env`/boot0/boot1. Write path for non-recovery partitions has NOT been tested yet.
- Layout facts: eMMC user area 7.28 GiB; `super` 0x22c00000 size 0x62800000 (1.6 GB), `userdata` 0x85c00000 size 0x14c400000 (5.3 GB), `recovery` 0x19400000 (24 MiB), `system_ext` 0xeb00000 (152 MiB), `cache` 0x6c00000 (50 MiB).

## Part 9 - Custom boot logo (DONE, works)
- `logo` partition (8 MiB at 0x18400000) = Amlogic resource package: header (CRC-32, init 0xffffffff, no final xor, over bytes 4..size), magic `AML_RES!`, size, item count 9, then a 64-byte U-Boot-style entry per item (little-endian; +8 = item size, +12 = item offset) and the data: `upgrade_fail`, `factory`, `bootup` (the boot logo: 1920x1080 24-bit BMP, gzip), `upgrade_unfocus`, `upgrade_logo`, `upgrade_upgrading`, `upgrade_error`, `upgrade_bar`, `upgrade_success` (300x300 BMPs, 4x14 bars).
- `logo-work/make_logo.py stock.img wallpaper.png out.img [preview]` replaces only `bootup` (new gzip BMP appended after the last item, table/size/CRC updated, other 8 items byte-identical, file stays 8 MiB). `logo-work/logo-tux.img` = Tux (Wikimedia `Tux.svg`, `logo-work/tux.png`) on a dark gradient.
- Flashed with `flash-tools/flash-part.sh logo logo-work/logo-tux.img` (whitelist: `recovery`, `logo` only; refuses anything else; readback compare VERIFIED). User confirmed: Tux shows at boot instead of the Mi logo, Android boots normally.
- Restore stock logo: `flash-tools/flash-part.sh logo backup-emmc/parts/logo.img`. User explicitly authorised writing `logo` (the `recovery`-only rule otherwise still stands).

## Open questions
- Which exact fixes does mainline need on top of the p212 DTB for the Mi Box S (USB: which of dwc2 `c9100000` / dwc3 `c9000000` drives the single port, VBUS GPIO, HDMI/DRM, eMMC)?
- ANSWERED: VBUS GPIO for this box (pmic variant) is `GPIOAO_3`, not `GPIOAO_4`.
- ANSWERED (likely): the framebuffer calibration pattern assumed 1080p, but U-Boot runs 2160p60hz.
- ANSWERED: adb works in recovery with `recovery-adb5.img` (see Part 6). Next: use the live vendor-kernel shell to learn how USB host (stick), eMMC, HDMI/fb work, and to build the Linux-from-USB boot.
- Which UART pad is TX/RX/GND (forum labels may be mirrored)?

## Current state of the box (update this)
- `recovery` partition: `recovery-adb5.img` (stock kernel+DTB, modified ramdisk: adb root, permissive policy patch, dump service). Android boots normally from power-on. Back+Center boots it, writes a dump to the partition tail and stays up (adb root). Power-cycle to leave. Now flashed: `recovery-work/recovery-adb5.img` (adb root over the A-to-A cable works).
- To restore stock recovery: burn mode → `partition recovery recovery-backup.img normal` → read back and compare.

## Event log (newest last; one line per poke at the box)
- (earlier) misc/recovery rescue done, Android 12 restored and confirmed.
- RAM-boot tests (burn-mode U-Boot): no output; `setenv`/`hdmitx` crash burn-mode U-Boot.
- Flashed `recovery-linux*.img` v1–v10 (ophub kernel); liveness proven by timers; USB/eMMC/gadget/display silent.
- Stock recovery + 1 byte changed: boots → no AVB enforcement, Back+Center works.
- Built custom 6.12.114 kernel; `new1`/`new2` flashed → ramoops log shows vendor DTB in use.
- `new3`–`new5` flashed: container in `second`+`dtb` → my DTB used; log still not readable.
- `new6` panic image: box hung; `new7` (`max-reason`): no dump.
- `new8` framebuffer pattern: nothing visible.
- Kernel rebuilt with forced UART cmdline; `new9` built, waiting for the ESP32 wiring.
- (new session, project moved to `Data/Dev/mibox-root`) Found UART location photo; measured pads 2.7 V / 0 V / 0.35 V; ESP32 oscilloscope firmware built and flashed, parked.
- Unpacked stock recovery (kernel 4.9.269 + full Android ramdisk); rebuilt flashing tools; flashed `recovery-adb1.img` (booted, no adb), `recovery-dump3.img` (dump read back from partition tail: adbd crash loop from SELinux `setcurrent` denial, pmic variant, 4K display); built `recovery-adb2.img`, flash pending a fresh burn-mode entry.
- Built/flashed adb2..adb5 (adbd fix, dump in init domain failed, sepolicy permissive patch, Android USB register write). `adb5`: adb root shell in recovery works.
- Armbian stick prepared (safe probe script, `recovery.img`, `probe.bmp`; original autoscript renamed `.off`); Back+Center test, .bmp probe test and `reboot update` test all booted the flash recovery with no sign of U-Boot reading the stick. Vendor kernel does see the stick. Next: research via adb (vendor kernel/DTB/driver facts for the Linux-from-USB build).

## Part 10 — Arch Linux ARM on eMMC `userdata` (2026-11-10)
- misc = boot-recovery (user-approved) so the box always boots our recovery-partition kernel; `userdata` (user-approved) now holds a minimal Arch Linux ARM root. `super` untouched. Android no longer boots; restore = `flash-part.sh userdata backup-emmc/parts/userdata.img` + `flash-part.sh misc backup-emmc/parts/misc.img`.
- Kernel exposes userdata as /dev/mmcblk1p1 via `blkdevparts=mmcblk1:5574230016@2243952640(linux)`; init (recovery-new19.img) mounts it and switch_roots to systemd. Boots fast.
- Pipeline: `arch-work/fetch.sh` (tarball, iwd+ell, BCM43456 firmware) -> `sudo bash stick-setup/build-arch-userdata.sh` (2 GiB ext4 image, no chroot; env HN/ROOTPW/WIFI_SSID/WIFI_PSK for non-interactive) -> `flash-tools/flash-part.sh userdata userdata-work/userdata-arch.img` (now accepts smaller images). Grow later: `resize2fs /dev/mmcblk1p1`.
- Wi-Fi: SDIO 02d0:4345 = BCM43456 (AP6256-class), NOT Realtek (rtkbt is only Bluetooth). Arch's linux-firmware lacks 43456 files -> taken from Armbian's firmware repo. iwd does DHCP; DNS via systemd-resolved. Wi-Fi works (verified).
- Earlier findings: Armbian-on-stick attempts hit slow USB stick (~0.2 MB/s) and ophub module ABI mismatch (fixed with own modules, release 6.12.114-ophub).

### Part 10b — Bluetooth, real MACs, reproducible pipeline (2026-11-10)  — SUCCESS: Wi-Fi + Bluetooth + SSH + pacman all working
- Final working set: `recovery-work/recovery-new22.img` (kernel/build.sh) + `userdata-work/userdata-arch.img` (stick-setup/build-arch-userdata.sh).
- Bluetooth = BCM4345C5 (AP6256 combo) on uart_A, serdev `bcm43438-bt` node from the p212 DT (reset GPIOX_17 = vendor `bt-dev` gpio_reset). Needs firmware `brcm/BCM4345C5.hcd` (Armbian firmware repo) + bluez/bluez-utils. Controller powers up with the placeholder address 43:45:c5:00:1f:ac -> stays "unconfigured" until a real address is set.
- Real per-box MACs live in the DTB (recovery partition!): `wifi@1 { local-mac-address }` under `&sd_emmc_a` (read by brcmfmac) and `bluetooth { local-bd-address }` (LSB first; kernel writes it to the chip during setup). The DTS holds placeholders `de ad be ef 00 01/02`; `kernel/build.sh` patches the compiled DTB from `WIFI_MAC`/`BT_MAC` (env or `kernel/macs.env`; zero = unset). Source of the MACs: stock Android `getprop ro.boot.wifimac` / `ro.boot.btmacaddr` (also on the vendor kernel cmdline). Runtime `btmgmt public-addr` timed out (-110, chip powered down) -> DT route is the reliable one.
- Gotcha: build.sh patches the DTB in place, so it now `rm -f`s the DTB before every build (otherwise "placeholder not found").
- Kernel bug found: this 6.12.114 tree has L2CAP converted to `->getsockopt_iter` but `net/socket.c` never dispatched it, so every L2CAP getsockopt returned EOPNOTSUPP and `bluetoothd` died with "Failed to start listening: getsockopt(L2CAP_OPTIONS): Operation not supported (95)" / "Unable to register new adapter". Diagnosed with `strace -f -o /tmp/bt.trace bluetoothd -n`. Fix: added a `getsockopt_iter` branch to `do_sock_getsockopt()` in `net/socket.c` (built-in, modules unaffected).
- Landlock enabled (`CONFIG_SECURITY_LANDLOCK=y`, `landlock` first in `CONFIG_LSM`) so pacman 7's download sandbox works.
- Pipeline: `arch-work/fetch.sh` (tarball+md5, BCM43456 wifi fw, BCM4345C5.hcd) -> `kernel/build.sh <img>` (needs kernel/macs.env) -> `sudo stick-setup/build-arch-userdata.sh` (host `pacman --root` installs `PKGS="iwd bluez bluez-utils"` from ALARM repos, no chroot; image's libalpm hooks parked during install; benign "execv failed" once for ldconfig; `linux-aarch64` unregistered + IgnorePkg; env overrides HN/ROOTPW/WIFI_SSID/WIFI_PSK/PKGS) -> `flash-tools/flash-part.sh userdata <img>` + `flash-tools/flash-recovery.sh <img>` (each needs a fresh burn-mode session). After first boot: `resize2fs /dev/mmcblk1p1`.
- Wi-Fi chip is BCM43456 (SDIO 02d0:4345), NOT Realtek; Arch's linux-firmware lacks brcmfmac43456 files.
- TODO: forum README; optional: Landlock/Bluetooth already done; HDMI 1080p mode message cosmetic; gadget-serial fallback (dwc2 probe hang) unfixed.

### Part 10c — clock sync fix and pipeline validated from a fresh clone (2026-11-10)
- Symptom: TLS failed because the clock was wrong (no RTC: the box boots at an old date); `systemd-timesyncd` was "active" but `timedatectl timesync-status` showed `Server: n/a`, packet count 0.
- Cause: `iwd` was doing its own DHCP (`EnableNetworkConfiguration=true`), so `systemd-networkd` did not manage `wlan0` and wrote `ONLINE_STATE=offline` to `/run/systemd/netif/state`. `timesyncd` only queries NTP when networkd reports online. (Side effect: resolved fell back to Quad9 instead of the DHCP-provided DNS.)
- Fix (in `stick-setup/build-arch-userdata.sh`): iwd only associates (`main.conf` just sets `NameResolvingService=systemd`); `20-wlan.network` (`Name=wl*`, `DHCP=yes`, `RequiredForOnline=degraded`) lets networkd do DHCP; `systemd-networkd` stays enabled; the tarball's wired `en`/`eth` .network files get `RequiredForOnline=no` (the box has no wired port, avoids wait-online stalls). Verified on the box: `ONLINE_STATE=online`, clock synchronised.
- Pipeline test: cloned the GitHub repo into a clean directory and ran `fetch.sh` -> `flash-tools/setup.sh` -> `sudo build-arch-userdata.sh` -> `flash-part.sh userdata` end to end. Found and fixed one bug on the way (`fetch.sh` used `/aarch64/os/...`; the tarball lives under `/os/`). Kernel build from a clean tree (README step 4) is still untested from scratch.
