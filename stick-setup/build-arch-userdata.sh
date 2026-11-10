#!/bin/bash
# Builds a SMALL ext4 image with Arch Linux ARM for the Mi Box S `userdata` partition (no chroot needed).
#   sudo bash stick-setup/build-arch-userdata.sh [image-size-MiB, default 2048]
# Output: userdata-work/userdata-arch.img   (flash: flash-tools/flash-part.sh userdata <img>; grow later: resize2fs /dev/mmcblk1p1)
# Asks (silently) for the root password and the Wi-Fi SSID/passphrase; nothing is stored except the hash / the iwd profile inside the image.
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"; A="$HERE/arch-work"; OUT="$HERE/userdata-work"; IMG="$OUT/userdata-arch.img"
MIB="${1:-2048}"; UUID=5f0c2b7e-3d1a-4c55-9a47-a7c1d3e9b6a2; MODREL=6.12.114-ophub
TB="$A/ArchLinuxARM-aarch64-latest.tar.gz"
for f in "$TB" "$A/fw43456/brcmfmac43456-sdio.bin" "$A/fw43456/brcmfmac43456-sdio.txt" "$A/fw43456/brcmfmac43456-sdio.clm_blob" "$A/fw43456/BCM4345C5.hcd" "$HERE/kernel/modroot/lib/modules/$MODREL"; do [ -e "$f" ] || { echo "missing $f"; exit 1; }; done
command -v openssl >/dev/null && command -v bsdtar >/dev/null && command -v pacman >/dev/null || { echo "need openssl, bsdtar (libarchive) and pacman on the host (Arch-based PC; used only with --root, no chroot)"; exit 1; }
PKGS="${PKGS:-iwd bluez bluez-utils}"   # extra packages installed into the image (space separated; override via env)

[ -n "${HN:-}" ] || { read -r -p "hostname [mibox]: " HN; HN=${HN:-mibox}; }
[ -n "${ROOTPW:-}" ] && P1=$ROOTPW && P2=$ROOTPW || while :; do read -r -s -p "root password: " P1; echo; read -r -s -p "again: " P2; echo; [ -n "$P1" ] && [ "$P1" = "$P2" ] && break; echo "empty or mismatch"; done
SSID=${WIFI_SSID:-}; WPW=${WIFI_PSK:-}; [ -n "$SSID" ] || { read -r -p "Wi-Fi SSID: " SSID; read -r -s -p "Wi-Fi passphrase (8-63 chars): " WPW; echo; }
HASH=$(printf '%s' "$P1" | openssl passwd -6 -stdin); unset P1 P2

mkdir -p "$OUT"; W=$(mktemp -d "$OUT/w.XXXX")
R="$W/root"; mkdir -p "$R"; trap 'rm -rf "$W"' EXIT
echo "extracting Arch Linux ARM..."
bsdtar -xpf "$TB" --numeric-owner -C "$R" 2>&1 | grep -v "Ignoring malformed pax" || true
# extra packages via host pacman --root against the ALARM aarch64 repos: resolves deps, fills the image's pacman db.
# Scriptlets/hooks are skipped (they would need an aarch64 chroot); signatures are not checked here (plain-http mirror, ALARM keyring not on host).
mkdir -p "$A/pkgcache"
cat > "$W/pacman.conf" <<PC
[options]
RootDir = $R
DBPath = $R/var/lib/pacman
CacheDir = $A/pkgcache
HookDir = $W/nohooks
GPGDir = $W/gpg
Architecture = aarch64
SigLevel = Never
[core]
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
[extra]
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
[alarm]
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
PC
mkdir -p "$W/nohooks" "$W/gpg"
# the image's own libalpm hooks would try to run aarch64 binaries on the host: park them during the install, put them back after
HK="$R/usr/share/libalpm/hooks"; [ -d "$HK" ] && mv "$HK" "$W/hooks.parked"
# our kernel replaces the packaged one: unregister it (db only) so pacman never tries to update it
for k in linux-aarch64 linux-aarch64-headers; do pacman --config "$W/pacman.conf" -Rdd --dbonly --noscriptlet --noconfirm $k >/dev/null 2>&1 || true; done
echo "NOTE: one \"call to execv failed (Exec format error)\" at the end is pacman trying to run the image's aarch64 ldconfig on the host; harmless"
pacman --config "$W/pacman.conf" -Sy --noscriptlet --disable-sandbox --noconfirm --needed $PKGS
[ -d "$W/hooks.parked" ] && { rm -rf "$HK"; mv "$W/hooks.parked" "$HK"; }
# drop the packaged kernel; use our modules
rm -rf "$R"/usr/lib/modules/* "$R"/boot/* "$R"/usr/lib/firmware/{amdgpu,nvidia,i915,xe,radeon,netronome,mellanox,qcom,ath10k,ath11k,ath12k,mediatek,intel,mrvl,cirrus,ti-connectivity} 2>/dev/null || true
cp "$A"/fw43456/brcmfmac43456-sdio.* "$A"/fw43456/BCM4345C5.hcd "$R/usr/lib/firmware/brcm/"   # BCM43456 Wi-Fi (run arch-work/fetch.sh first)
mkdir -p "$R/usr/lib/modules"; cp -a "$HERE/kernel/modroot/lib/modules/$MODREL" "$R/usr/lib/modules/"
rm -f "$R/usr/lib/modules/$MODREL"/{build,source}

# --- configuration by file writes ---
echo "$HN" > "$R/etc/hostname"
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s\n' "$HN" > "$R/etc/hosts"
printf 'UUID=%s  /     ext4  defaults,noatime,commit=60,errors=remount-ro  0 1\ntmpfs  /tmp  tmpfs  defaults,nosuid  0 0\n' "$UUID" > "$R/etc/fstab"
python3 -I - "$R/etc/shadow" "$HASH" <<'PY'
import sys
p,h=sys.argv[1:3]; L=open(p).read().splitlines()
L=[('root:'+h+':'+':'.join(l.split(':')[2:])) if l.startswith('root:') else l for l in L]
open(p,'w').write('\n'.join(L)+'\n')
PY
chmod 600 "$R/etc/shadow"; unset HASH
ln -sf /usr/share/zoneinfo/UTC "$R/etc/localtime"
mkdir -p "$R/etc/ssh/sshd_config.d"; printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > "$R/etc/ssh/sshd_config.d/10-root.conf"
mkdir -p "$R/etc/modules-load.d"; printf 'brcmfmac\n' > "$R/etc/modules-load.d/wifi.conf"
# networking: iwd only handles Wi-Fi association; systemd-networkd does DHCP and reports the "online" state that
# systemd-timesyncd waits for (with iwd's own DHCP networkd says ONLINE_STATE=offline and NTP never starts); DNS via systemd-resolved
mkdir -p "$R/etc/iwd" "$R/etc/systemd/network"; printf '[Network]\nNameResolvingService=systemd\n' > "$R/etc/iwd/main.conf"
printf '[Match]\nName=wl*\n\n[Network]\nDHCP=yes\nIPv6AcceptRA=yes\n\n[Link]\nRequiredForOnline=degraded\n' > "$R/etc/systemd/network/20-wlan.network"
# this box has no wired port: don't let network-online wait for the (carrier-less) ethernet interface
for f in en eth; do [ -f "$R/etc/systemd/network/$f.network" ] && printf '\n[Link]\nRequiredForOnline=no\n' >> "$R/etc/systemd/network/$f.network"; done
mkdir -p "$R/var/lib/iwd"
if printf '%s' "$SSID" | grep -qE '^[A-Za-z0-9_ -]+$'; then FN="$SSID.psk"; else FN="=$(printf '%s' "$SSID" | od -An -tx1 | tr -d ' \n').psk"; fi
printf '[Security]\nPassphrase=%s\n' "$WPW" > "$R/var/lib/iwd/$FN"; chmod 600 "$R/var/lib/iwd/$FN"; chmod 700 "$R/var/lib/iwd"; unset WPW
rm -f "$R/etc/resolv.conf"; ln -s ../run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"
# enable services (symlinks, as `systemctl enable` would)
S=/usr/lib/systemd/system; WT="$R/etc/systemd/system/multi-user.target.wants"; mkdir -p "$WT" "$R/etc/systemd/system/sockets.target.wants"
mkdir -p "$R/etc/systemd/system/bluetooth.target.wants"; ln -sf $S/bluetooth.service "$R/etc/systemd/system/bluetooth.target.wants/bluetooth.service"; ln -sf $S/bluetooth.service "$R/etc/systemd/system/dbus-org.bluez.service"
for u in sshd iwd systemd-resolved systemd-timesyncd; do [ -e "$R$S/$u.service" ] && ln -sf "$S/$u.service" "$WT/$u.service" || echo "NOTE: $u.service missing"; done
# networkd on (tarball default, DHCP for wlan0 above); dhcpcd off
ln -sf $S/systemd-networkd.service "$WT/systemd-networkd.service"; rm -f "$WT/dhcpcd.service"
# first boot: arch keyring init so pacman works
mkdir -p "$R/etc/systemd/system"; sed -i 's/^#\?IgnorePkg.*/IgnorePkg = linux-aarch64 linux-aarch64-headers/' "$R/etc/pacman.conf"; grep -q '^IgnorePkg' "$R/etc/pacman.conf" || sed -i '/^\[options\]/a IgnorePkg = linux-aarch64 linux-aarch64-headers' "$R/etc/pacman.conf"
cat > "$R/etc/systemd/system/pacman-keyinit.service" <<'U'
[Unit]
Description=Initialise pacman keyring (first boot)
ConditionPathExists=!/etc/pacman.d/gnupg/trustdb.gpg
After=time-sync.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'pacman-key --init && pacman-key --populate archlinuxarm'
[Install]
WantedBy=multi-user.target
U
ln -sf /etc/systemd/system/pacman-keyinit.service "$WT/pacman-keyinit.service"
: > "$R/etc/machine-id"

echo "tree size: $(du -sh "$R" | cut -f1); building ${MIB} MiB ext4..."
rm -f "$IMG"; truncate -s "${MIB}M" "$IMG"
mke2fs -q -t ext4 -b 4096 -m 1 -L ALARM -U $UUID -E root_owner=0:0 -d "$R" "$IMG"
e2fsck -fn "$IMG" | tail -2
chown "${SUDO_USER:-root}" "$IMG"; ls -l "$IMG"; sha256sum "$IMG" | tee "$IMG.sha256"
echo "done."
