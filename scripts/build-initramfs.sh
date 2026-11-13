#!/bin/bash
# Build initramfs.cpio.gz for ChromeOS on PS4 from the original PS4 initramfs.
# Adds: ChromeOS boot (functions/45-chromeos.sh), PS4 layer hook, static dmsetup
# (Alpine, baseline x86-64), loop-partscan, gpt-grow-state. No firmware (see below).
# VARIANT=release (default: what the PKG ships) or VARIANT=debug (SSH, logger, shell test).
set -euo pipefail
VARIANT=${VARIANT:-release}
case "$VARIANT" in release|debug) ;; *) echo "VARIANT must be release or debug" >&2; exit 1 ;; esac
B=/mnt/build/brunch-ps4
ORIG=${ORIG:-"$HOME/Downloads/ps4 linux/initramfs.cpio.gz"}
STAGE=$B/initramfs/stage
OUT=${1:-$B/out/initramfs-$VARIANT.cpio.gz}

rm -rf "$STAGE"; mkdir -p "$STAGE"
(cd "$STAGE" && zcat "$ORIG" | cpio -idm --quiet --no-absolute-filenames)
cp -a "$B/initramfs/overlay/." "$STAGE/"
cp -a "$B/initramfs/overlay-$VARIANT/." "$STAGE/"
chmod +x "$STAGE/hooks/pre_switch_root/"* "$STAGE/hooks/early/"*
echo "$VARIANT" > "$STAGE/PS4_VARIANT"
if [ "$VARIANT" = release ]; then
  # No remote access in production: drop the SSH server the original initramfs ships.
  rm -f "$STAGE/bin/dropbear" "$STAGE/bin/dropbearkey"
  # The RAM-disk speed test only costs ~6 s per boot.
  rm -f "$STAGE/hooks/early/2-ramdisk-test"
fi

# ChromeOS first, before the external/internal Linux installs.
python3 -I - "$STAGE/functions/40-install.sh" "$STAGE/init" <<'PY'
import sys
inst, init = sys.argv[1], sys.argv[2]
s = open(inst).read()
old = "ps4_locate_install() {\n\tif mountpoint -q /newroot && ! umount /newroot; then"
new = ("ps4_locate_install() {\n\tif cros_mount; then\n\t\treturn 0\n\tfi\n"
       "\tif mountpoint -q /newroot && ! umount /newroot; then")
assert s.count(old) == 1, "40-install.sh: ps4_locate_install anchor not found"
open(inst, "w").write(s.replace(old, new))
s = open(init).read()
old = "\nps4_prepare_newroot\n"
assert s.count(old) == 1, "init: ps4_prepare_newroot anchor not found"
open(init, "w").write(s.replace(old, '\n[ -n "${ps4_chromeos}" ] || ps4_prepare_newroot\n'))
PY

install -m 755 "$B/dl/alpine/x/usr/sbin/dmsetup.static" "$STAGE/bin/dmsetup"

# No firmware is added here (audit, docs/BOOT-MAP.md): GPU and Wi-Fi/BT firmware for every
# model is built into the kernel (CONFIG_EXTRA_FIRMWARE), and the loader appends the console's
# own GPU firmware, EDID and HDD key at boot. regulatory.db must NOT be here: applying it this
# early deadlocks the MediaTek vendor driver's mtk_reg_notify (seen on an Aeolia Fat), which
# also blocks networking. ChromeOS loads its own copy from ROOT-A later.
if find "$STAGE/lib/firmware" -type f ! -name .keep | grep . >/dev/null; then   # not grep -q: SIGPIPE + pipefail could hide a hit
  echo "initramfs must not carry firmware files:" >&2; find "$STAGE/lib/firmware" -type f ! -name .keep >&2; exit 1
fi

for f in "$STAGE"/init "$STAGE"/functions/*.sh "$STAGE"/hooks/*/*; do
  sh -n "$f"
done
if [ "$VARIANT" = release ]; then
  for f in bin/dropbear functions/46-debug-ssh.sh functions/48-chromeos-debug.sh etc/ps4-debug; do
    [ ! -e "$STAGE/$f" ] || { echo "release initramfs must not contain $f" >&2; exit 1; }
  done
fi
grep -q 'if cros_mount; then' "$STAGE/functions/40-install.sh"

mkdir -p "$(dirname "$OUT")"
(cd "$STAGE" && find . -print0 | cpio --null -o -H newc -R 0:0 --quiet | gzip -9) > "$OUT"
echo "initramfs ($VARIANT): $OUT ($(stat -c %s "$OUT") bytes)"
