#!/bin/bash
# Flash ONE whitelisted partition from burn mode, then read it back and compare.
# usage: flash-part.sh <recovery|logo|misc|userdata> <image> [venv-python]
# Allowed: recovery (25165824 bytes), logo and misc (8388608 bytes each), userdata (5574230016 bytes). Anything else is refused.
set -u
PART="$1"; IMG="$(realpath "$2")"
HERE="$(dirname "$(realpath "$0")")"
PY="${3:-$HERE/../.venv/bin/python}"
UPD="$HERE/khadas/aml-flash-tool/tools/linux-x86/update"
PW="$HERE/../password/password.bin"
case "$PART" in recovery) SIZE=25165824;; logo|misc) SIZE=8388608;; userdata) SIZE=5574230016;; *) echo "refusing partition '$PART' (allowed: recovery, logo, misc, userdata)"; exit 1;; esac
LOG="$HERE/logs/flash-$PART-$(date +%H%M%S).log"; mkdir -p "$HERE/logs"
BACK="$HERE/logs/readback-$PART-$(basename "$IMG")"
step() { echo "== $*" | tee -a "$LOG"; }
run()  { "$@" >>"$LOG" 2>&1 || { echo "FAILED: $*  (see $LOG)"; tail -5 "$LOG"; exit 1; }; }
ISZ=$(stat -c %s "$IMG")
if [ "$PART" = userdata ]; then  # a smaller image is fine (writes only the head of the partition; grow later with resize2fs)
  [ "$ISZ" -le "$SIZE" ] && [ $((ISZ % 4096)) = 0 ] && [ "$ISZ" -gt 0 ] || { echo "userdata image must be <= $SIZE bytes and a multiple of 4096"; exit 1; }
  SIZE=$ISZ
else
  [ "$ISZ" = "$SIZE" ] || { echo "image must be exactly $SIZE bytes for $PART"; exit 1; }
fi
lsusb | grep -q "1b8e:c003" || { echo "box not in burn mode (1b8e:c003 not found)"; exit 1; }
step "password";        run "$UPD" password "$PW"
step "load U-Boot to RAM"; run "$PY" "$HERE/stage1.py"
sleep 5
step "check U-Boot answers"; run "$UPD" bulkcmd "echo 12345"
step "init storage (no wipe)"; run "$UPD" bulkcmd "disk_initial 0"
step "write $PART";  run "$UPD" partition "$PART" "$IMG" normal
step "read back";       run "$UPD" mread store "$PART" normal $SIZE "$BACK"
if cmp "$IMG" "$BACK"; then echo "VERIFIED: $PART partition matches $IMG" | tee -a "$LOG"
else echo "MISMATCH after write of $PART! do not reboot; re-run or restore the backup image" | tee -a "$LOG"; exit 2; fi
