#!/bin/bash
# Flash ONLY the `recovery` partition from burn mode, then read it back and compare.
# usage: flash-recovery.sh <image> [venv-python]
# Never touches bootloader/misc/anything else. Stops on the first failure.
set -u
IMG="$(realpath "$1")"
HERE="$(dirname "$(realpath "$0")")"
PY="${2:-$HERE/../.venv/bin/python}"
UPD="$HERE/khadas/aml-flash-tool/tools/linux-x86/update"
PW="$HERE/../password/password.bin"
SIZE=25165824
LOG="$HERE/logs/flash-$(date +%H%M%S).log"; mkdir -p "$HERE/logs"
BACK="$HERE/logs/readback-$(basename "$IMG")"
step() { echo "== $*" | tee -a "$LOG"; }
run()  { "$@" >>"$LOG" 2>&1 || { echo "FAILED: $*  (see $LOG)"; tail -5 "$LOG"; exit 1; }; }

[ "$(stat -c %s "$IMG")" = "$SIZE" ] || { echo "image must be exactly $SIZE bytes"; exit 1; }
lsusb | grep -q "1b8e:c003" || { echo "box not in burn mode (1b8e:c003 not found)"; exit 1; }

step "password";        run "$UPD" password "$PW"
step "load U-Boot to RAM"; run "$PY" "$HERE/stage1.py"
sleep 5
step "check U-Boot answers"; run "$UPD" bulkcmd "echo 12345"
step "init storage (no wipe)"; run "$UPD" bulkcmd "disk_initial 0"
step "write recovery";  run "$UPD" partition recovery "$IMG" normal
step "read back";       run "$UPD" mread store recovery normal $SIZE "$BACK"
if cmp "$IMG" "$BACK"; then echo "VERIFIED: recovery partition matches $IMG" | tee -a "$LOG"
else echo "MISMATCH after write! do not reboot; re-run or restore recovery-backup.img" | tee -a "$LOG"; exit 2; fi
