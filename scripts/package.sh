#!/bin/bash
# Collect everything the PS4 needs into out/release.
#   USB root:  bzImage  initramfs.cpio.gz   (no bootargs.txt: kernel has a built-in cmdline)
#   Internal drive (/data/linux/boot or /system/boot): chromeos.img.xz  chromeos.img.size
#   Payload:   Linux_Loader_<VRAM>.bin (VRAM must match out/vram.txt)
set -euo pipefail
B=/mnt/build/brunch-ps4
R=$B/out/release
PAY="$HOME/Downloads/ps4 linux/bin"
vram=$(cat "$B/out/vram.txt")

[ -f "$B/kbuild/out/bzImage" ] || { echo "no kernel: run build-kernel.sh" >&2; exit 1; }
grep -q "amdgpu/liverpool_rlc.bin" "$B/kbuild/out/.config" || { echo "kernel lacks built-in GPU firmware" >&2; exit 1; }
xz -t "$B/out/chromeos.img.xz"
# Kernel features ChromeOS userspace can't start without (each found the hard way).
for opt in CONFIG_SECURITY_SELINUX CONFIG_QFMT_V2 CONFIG_SQUASHFS_XATTR CONFIG_SECURITYFS; do
  grep -q "^${opt}=y" "$B/kbuild/out/.config" || { echo "kernel lacks ${opt}" >&2; exit 1; }
done
if grep -q '^CONFIG_CMDLINE=".*loop.max_part=' "$B/kbuild/out/.config"; then
  echo "kernel cmdline has loop.max_part (breaks ChromeOS loop devices)" >&2; exit 1
fi
zcat "$B/out/initramfs.cpio.gz" | cpio -t --quiet 2>/dev/null | grep -qx 'bin/loop-partscan\|./bin/loop-partscan' \
  || { echo "initramfs lacks bin/loop-partscan" >&2; exit 1; }

rm -rf "$R"; mkdir -p "$R/usb" "$R/hdd" "$R/payload"
cp "$B/kbuild/out/bzImage" "$B/out/initramfs.cpio.gz" "$R/usb/"
cp "$B/kbuild/out/.config" "$R/usb/kernel.config"

# Exact unpacked size; the initramfs refuses to install without it.
xz --robot -l "$B/out/chromeos.img.xz" | awk '$1=="totals"{print $5}' > "$R/hdd/chromeos.img.size"
[ "$(cat "$R/hdd/chromeos.img.size")" = "$(stat -c %s "$B/out/chromeos.img")" ]
ln "$B/out/chromeos.img.xz" "$R/hdd/chromeos.img.xz" 2>/dev/null || cp "$B/out/chromeos.img.xz" "$R/hdd/"
# Read-only PS4 system layer (patched Mesa), stacked over /usr/lib64 by the initramfs.
if [ -f "$B/out/ps4-layer.sqfs" ]; then cp "$B/out/ps4-layer.sqfs" "$R/hdd/"; else echo "note: no out/ps4-layer.sqfs (run scripts/make-layer.sh)" >&2; fi

# Pick the loader whose two VRAM fields both equal vram.txt.
found=
for f in "$PAY"/*.bin; do
  read -r a b < <(python3 -I -c 'import struct,sys;d=open(sys.argv[1],"rb").read();print(*(struct.unpack_from("<I",d,o)[0] for o in (318636,318645)))' "$f" 2>/dev/null) || continue
  if [ "$a" = "$vram" ] && [ "$b" = "$vram" ]; then cp "$f" "$R/payload/"; found=$f; break; fi
done
[ -n "$found" ] || { echo "no payload with VRAM=$vram MB" >&2; exit 1; }

(cd "$R" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
echo "kernel $(cat "$B/kbuild/include/config/kernel.release"), payload $(basename "$found"), VRAM ${vram} MB"
ls -laR "$R"
