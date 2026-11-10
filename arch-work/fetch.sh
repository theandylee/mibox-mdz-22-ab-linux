#!/bin/bash
# Downloads everything the Arch image build needs into arch-work/ (idempotent; verifies the tarball md5).
set -eu
cd "$(dirname "$0")"
ALARM=http://os.archlinuxarm.org
get() { [ -s "$2" ] || { echo "fetch $2"; curl -fsSL -o "$2.part" "$1" && mv "$2.part" "$2"; }; }
get $ALARM/os/ArchLinuxARM-aarch64-latest.tar.gz ArchLinuxARM-aarch64-latest.tar.gz
get $ALARM/os/ArchLinuxARM-aarch64-latest.tar.gz.md5 ArchLinuxARM-aarch64-latest.tar.gz.md5
md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5
# extra packages (iwd, bluez, ...) are installed by build-arch-userdata.sh with host pacman --root; cached in pkgcache/
# Mi Box S Wi-Fi = AP6256-class BCM43456 (SDIO 02d0:4345); Arch's linux-firmware has no 43456 files, Armbian's firmware repo does
mkdir -p fw43456
for f in bin clm_blob txt; do get https://raw.githubusercontent.com/armbian/firmware/master/brcm/brcmfmac43456-sdio.$f fw43456/brcmfmac43456-sdio.$f; done
get https://raw.githubusercontent.com/armbian/firmware/master/brcm/BCM4345C5.hcd fw43456/BCM4345C5.hcd   # Bluetooth patchram (AP6256 BT)
sha256sum fw43456/*
