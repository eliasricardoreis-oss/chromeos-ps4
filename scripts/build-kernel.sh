#!/bin/bash
# Out-of-tree build of the Strawberry PS4 kernel (~/linux) with ChromeOS options.
# Mirrors build.sh (General profile + KVM, ThinLTO, btver2 flags) without touching the source tree.
# VARIANT=release (default: what the PKG ships) or VARIANT=debug (bring-up only).
set -euo pipefail
VARIANT=${VARIANT:-release}
case "$VARIANT" in release|debug) ;; *) echo "VARIANT must be release or debug" >&2; exit 1 ;; esac
SRC=${SRC:-$HOME/linux}
O=${O:-/mnt/build/brunch-ps4/kbuild-$VARIANT}
HERE=$(cd "$(dirname "$0")" && pwd)
export KCFLAGS="-march=btver2 -mtune=btver2 -Os"
export KAFLAGS="-march=btver2 -mtune=btver2"
MAKE=(make -C "$SRC" O="$O" -j"$(nproc)" LLVM=1 ARCH=x86_64
      HOSTCFLAGS="-Wno-error=incompatible-pointer-types-discards-qualifiers")
mkdir -p "$O"
cp "$SRC/config" "$O/.config"
cfg() { "$SRC/scripts/config" --file "$O/.config" "$@"; }
apply() {
  while read -r action name value; do
    [[ -z "$action" || "$action" == \#* ]] && continue
    case "$action" in
      enable) cfg --enable "$name" ;; disable) cfg --disable "$name" ;;
      set-val) cfg --set-val "$name" "$value" ;; set-str) cfg --set-str "$name" "$value" ;;
    esac
  done < "$1"
}
cfg --set-str CONFIG_EXTRA_FIRMWARE_DIR "$SRC/extra_firmware"
# Built-in PS4 GPU firmware, same list as build.sh (REQUIRED_PS4_AMDGPU_FW):
# without it amdgpu can not start Liverpool/Gladius and HDMI stays dark.
fw=$(sed -n 's/^CONFIG_EXTRA_FIRMWARE="\(.*\)"/\1/p' "$O/.config")
while read -r blob; do
  [ -f "$SRC/extra_firmware/$blob" ] || { echo "missing firmware $SRC/extra_firmware/$blob" >&2; exit 1; }
  case " $fw " in *" $blob "*) ;; *) fw="${fw:+$fw }$blob" ;; esac
done < <(sed -n '/^REQUIRED_PS4_AMDGPU_FW=(/,/^)/p' "$SRC/build.sh" | grep -o 'amdgpu/[^"]*\.bin')
cfg --set-str CONFIG_EXTRA_FIRMWARE "$fw"
apply "$SRC/configs/lto-thin.cfg"
cfg --disable CONFIG_LOCALVERSION_AUTO
cfg --set-str CONFIG_LOCALVERSION "-Strawberry-ChromeOS-$VARIANT"
apply "$SRC/configs/base.cfg"
apply "$SRC/configs/release.cfg"
apply "$SRC/configs/tuning-general.cfg"
apply "$SRC/configs/debloat.cfg"
apply "$SRC/configs/kvm.cfg"
apply "$HERE/chromeos.cfg"
apply "$HERE/chromeos-$VARIANT.cfg"
"${MAKE[@]}" olddefconfig
# Every requested option must have stuck; a silently dropped one is a broken build.
bad=0
while read -r action name value; do
  case "$action" in
    enable)  grep -q "^${name}=y" "$O/.config" || { echo "ERROR: $name did not stick: $(grep -E "^(# )?${name}[ =]" "$O/.config" || echo missing)" >&2; bad=1; } ;;
    disable) grep -q "^${name}=y" "$O/.config" && { echo "ERROR: $name still enabled" >&2; bad=1; } ;;
  esac
done < <(cat "$HERE/chromeos.cfg" "$HERE/chromeos-$VARIANT.cfg")
[ "$bad" = 0 ] || exit 1
time "${MAKE[@]}" bzImage
mkdir -p "$O/out"
cp "$O/arch/x86/boot/bzImage" "$O/.config" "$O/out/"
grep -q 'amdgpu/liverpool_rlc.bin' "$O/.config" || { echo "GPU firmware not in CONFIG_EXTRA_FIRMWARE" >&2; exit 1; }
echo "kernel ($VARIANT): $O/out/bzImage ($(cat "$O/include/config/kernel.release"))"
