#!/bin/bash
# Build the "ChromeOS for PS4" installer PKG (OpenOrbis) from the RELEASE build.
# Refuses debug pieces: the PKG is what other people install.
#   kernel     kbuild-release/out/bzImage
#   initramfs  out/initramfs-release.cpio.gz
#   layer      out/ps4-layer.sqfs
#   image      out/chromeos.img.xz (+ size)
#   payload    the Linux loader whose VRAM fields match out/vram.txt
# Output: out/pkg/IV0000-CROS00001_00-CHROMEOSPS4INSTL.pkg
set -euo pipefail
B=/mnt/build/brunch-ps4
P=$B/pkg/installer
A=$P/assets/chromeos
PAY="$HOME/Downloads/ps4 linux/bin"
export OO_PS4_TOOLCHAIN=${OO_PS4_TOOLCHAIN:-$HOME/OpenOrbis/PS4Toolchain}
K=$B/kbuild-release/out

# --- release-only checks
[ -f "$K/bzImage" ] || { echo "no release kernel (VARIANT=release scripts/build-kernel.sh)" >&2; exit 1; }
for opt in CONFIG_SECURITY_SELINUX CONFIG_SECURITY_LOCKDOWN_LSM CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY \
           CONFIG_CPUSETS_V1 CONFIG_MEMCG_V1 CONFIG_QFMT_V2 CONFIG_SQUASHFS_XATTR CONFIG_SECURITYFS; do
  grep -q "^${opt}=y" "$K/.config" || { echo "release kernel lacks $opt" >&2; exit 1; }
done
for opt in CONFIG_NETCONSOLE CONFIG_MAGIC_SYSRQ CONFIG_SECURITY_SELINUX_DEVELOP CONFIG_DEBUG_FS CONFIG_KEXEC; do
  grep -q "^${opt}=y" "$K/.config" && { echo "release kernel has debug option $opt" >&2; exit 1; }
done
grep -q '^CONFIG_CMDLINE="cros_efi quiet loglevel=3"$' "$K/.config" || { echo "release kernel cmdline is not the release one" >&2; exit 1; }
I=$B/out/initramfs-release.cpio.gz
[ "$(zcat "$I" | cpio -i --to-stdout --quiet PS4_VARIANT 2>/dev/null)" = release ] || { echo "initramfs is not a release build" >&2; exit 1; }
zcat "$I" | cpio -t --quiet | grep -q -E '(^|/)(dropbear|46-debug-ssh\.sh|48-chromeos-debug\.sh)$' && { echo "release initramfs contains debug files" >&2; exit 1; }
[ -f "$B/out/ps4-layer.sqfs" ] || { echo "no out/ps4-layer.sqfs (scripts/make-layer.sh)" >&2; exit 1; }
unsquashfs -l "$B/out/ps4-layer.sqfs" | grep -q 'etc/init/os_install_service.override' || { echo "layer lacks the os_install_service override" >&2; exit 1; }
LL=$(unsquashfs -l "$B/out/ps4-layer.sqfs")
[ "$(echo "$LL" | grep -c -E 'etc/lsb-release$|etc/ui_use_flags.txt$|etc/ps4-orig.md5$|etc/init-noupdate/update-engine.override$')" -eq 4 ] || { echo "layer lacks lsb-release / ui_use_flags.txt / ps4-orig.md5 / init-noupdate" >&2; exit 1; }
[ "$(echo "$LL" | grep -c 'etc/init/update-engine.override$')" -eq 0 ] || { echo "stale layer: update-engine still manual (rerun make-layer.sh)" >&2; exit 1; }
xz -t "$B/out/chromeos.img.xz"
size=$(xz --robot -l "$B/out/chromeos.img.xz" | awk '$1=="totals"{print $5}')

# --- payload whose VRAM fields match vram.txt
vram=$(cat "$B/out/vram.txt"); payload=
for f in "$PAY"/*.bin; do
  read -r a b < <(python3 -I -c 'import struct,sys;d=open(sys.argv[1],"rb").read();print(*(struct.unpack_from("<I",d,o)[0] for o in (318636,318645)))' "$f" 2>/dev/null) || continue
  [ "$a" = "$vram" ] && [ "$b" = "$vram" ] && { payload=$f; break; }
done
[ -n "$payload" ] || { echo "no loader payload with VRAM=$vram MB" >&2; exit 1; }

# --- stage (hard links: same filesystem, no 1 GB copies)
rm -rf "$A"; mkdir -p "$A"
ln "$K/bzImage" "$A/bzImage"
ln "$I" "$A/initramfs.cpio.gz"
ln "$B/out/ps4-layer.sqfs" "$A/ps4-layer.sqfs"
ln "$B/out/chromeos.img.xz" "$A/chromeos.img.xz"
echo "$size" > "$A/chromeos.img.size"
cp "$payload" "$A/ps4-chromeos-loader.bin"
# STATE start sector of the seed image: the app computes the image size for the storage
# size picked in its menu (same formula as the initramfs) and reserves exactly that
{ xz -dc "$B/out/chromeos.img.xz" 2>/dev/null || true; } | head -c 1048576 > "$A/.gpt" || true
start=$(od -An -tu8 -j1056 -N8 "$A/.gpt" | tr -d ' \n'); rm -f "$A/.gpt"
[ -n "$start" ] && [ "$start" -gt 0 ] || { echo "cannot read the STATE start from the seed GPT" >&2; exit 1; }
echo "$start" > "$A/chromeos.img.state-start"
# build stamp: lets the app skip copying when the console already has this exact build
(cd "$A" && sha256sum bzImage initramfs.cpio.gz ps4-layer.sqfs chromeos.img.size chromeos.img.xz ps4-chromeos-loader.bin chromeos.img.state-start | sha256sum | cut -c1-32) > "$A/build-id"

cd "$P"
make -s clean >/dev/null
make -s 2>&1 | grep -v -E '^\s*\[|parallel|^$' || true
pkg=$(ls -1 "$P"/*.pkg | head -1)
mkdir -p "$B/out/pkg"
mv -f "$pkg" "$B/out/pkg/"
echo "PKG: $B/out/pkg/$(basename "$pkg") ($(stat -c %s "$B/out/pkg/$(basename "$pkg")") bytes)"
echo "  kernel $(cat $B/kbuild-release/include/config/kernel.release), payload $(basename "$payload") (VRAM ${vram} MB), image ${size} bytes"
