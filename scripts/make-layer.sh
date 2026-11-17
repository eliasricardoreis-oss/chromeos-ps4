#!/bin/bash
# Build out/ps4-layer.sqfs: the read-only PS4 system layer that the initramfs stacks
# over ROOT-A's /usr/lib64, /etc/init, /etc/lsb-release and /etc/ui_use_flags.txt. Contents: the PS4-patched Mesa set from mesa/out
# (radeonsi_dri.so + the matching libEGL_mesa.so.0 and libglapi.so.0).
# Goes to /data/linux/boot/ps4-layer.sqfs on the PS4.
set -euo pipefail
B=/mnt/build/brunch-ps4
M=$B/mesa/out
OUT=$B/out/ps4-layer.sqfs
for f in radeonsi_dri.so libEGL_mesa.so.0 libglapi.so.0; do
  [ -f "$M/$f" ] || { echo "missing $M/$f (run mesa/build-mesa.sh)" >&2; exit 1; }
done
# Guard the two ways this can break on the PS4: AVX2-class instructions (Jaguar
# lacks them) and glibc symbols newer than ChromeOS's.
n_avx=$(objdump -d --no-show-raw-insn "$M"/* | grep -c -E '%ymm|%zmm|\b(shlx|sarx|shrx|rorx|mulx|pdep|pext|bzhi|vfmadd[0-9a-z]*)\b' || true)
if [ "$n_avx" -gt 0 ]; then
  echo "Mesa build contains AVX/AVX2/BMI2/FMA instructions - not for Jaguar" >&2; exit 1
fi
maxg=$(objdump -T "$M"/* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
[ "$(printf '%s\nGLIBC_2.41\n' "$maxg" | sort -V | tail -1)" = GLIBC_2.41 ] \
  || { echo "Mesa needs $maxg, ChromeOS has glibc 2.41" >&2; exit 1; }
# (count, not grep -q: with pipefail, grep -q exiting early fails the pipeline via SIGPIPE)
[ "$(strings "$M/radeonsi_dri.so" | grep -c -x -E 'LIVERPOOL|GLADIUS')" -ge 2 ] || { echo "radeonsi lacks LIVERPOOL/GLADIUS" >&2; exit 1; }

S=$(mktemp -d); chmod 755 "$S"; trap 'rm -rf "$S"' EXIT
install -D -m 755 "$M/radeonsi_dri.so" "$S/usr/lib64/dri/radeonsi_dri.so"
install -D -m 755 "$M/libEGL_mesa.so.0" "$S/usr/lib64/libEGL_mesa.so.0"
install -D -m 755 "$M/libglapi.so.0" "$S/usr/lib64/libglapi.so.0"
# Upstart overrides: "manual" = never started automatically. Firmware updaters and the
# disk installer have no business on a PS4.
mkdir -p "$S/etc/init"
for job in boot-update-firmware fwupdtool-update os_install_service; do
  printf '# PS4 layer: job disabled on PS4 (see scripts/make-layer.sh).\nmanual\n' > "$S/etc/init/$job.override"
done
# --- "light" system -------------------------------------------------------------
# 1) ps4-tune: boot-time sysctl/sysfs tuning (layer-extra/etc/init/ps4-tune.conf).
install -D -m 644 "$B/layer-extra/etc/init/ps4-tune.conf" "$S/etc/init/ps4-tune.conf"
# 2) Switch off background jobs a PS4 does not need - ONLY those that exist in ROOT-A
#    (so a wrong name never breaks anything). Override with LIGHT_OFF_JOBS="a b c";
#    LIGHT_OFF_JOBS="" keeps everything. Crostini (vm_concierge) is NOT in the list.
ROOTA_L=${ROOTA:-$B/work/reven/root}
for job in ${LIGHT_OFF_JOBS-metrics_daemon ml-service cupsd cups_proxy avahi}; do
  if [ -f "$ROOTA_L/etc/init/$job.conf" ]; then
    printf '# PS4 layer: job disabled to keep the system light.\nmanual\n' > "$S/etc/init/$job.override"
    echo "light: $job off"
  else
    echo "light: $job not in ROOT-A, skipped"
  fi
done
# Updater: updates come from a new recovery image (ROOT-A stays immutable), so ChromeOS's
# A/B updater must never write ROOT-B/KERN-B inside chromeos.img. It still has to RUN:
# OOBE's update step waits for it (~3 min, then "Exiting update after retry check timout").
# So it runs against a dead update server: every check fails at once, nothing downloads.
# etc/lsb-release = ROOT-A's file with only CHROMEOS_AUSERVER changed; the initramfs binds
# it only if the rest matches the installed image byte for byte. If it does not match, the
# initramfs adds etc/init-noupdate (update-engine "manual") instead - never the real server.
# Two ROOT-A files are replaced by patched copies (bind-mounted by the initramfs):
#  etc/lsb-release       only CHROMEOS_AUSERVER -> dead server
#  etc/ui_use_flags.txt  without "os_install_service": session_manager then starts Chrome
#                        without --allow-os-install, so OOBE offers no "Install ChromeOS Flex"
#                        (it would erase a whole disk = the PS4 drive). Verified on the Fat.
# etc/ps4-orig.md5 holds the originals' checksums; the initramfs binds the copies only if
# ROOT-A matches. Otherwise it adds etc/init-noupdate (update-engine "manual") instead.
ROOTA=${ROOTA:-$B/work/reven/root}
for f in etc/lsb-release etc/ui_use_flags.txt; do
  [ -f "$ROOTA/$f" ] || { echo "missing $ROOTA/$f (ROOT-A of the image in out/)" >&2; exit 1; }
done
DEAD=https://127.0.0.1:1/service/update2
sed "s#^CHROMEOS_AUSERVER=.*#CHROMEOS_AUSERVER=$DEAD#" "$ROOTA/etc/lsb-release" > "$S/etc/lsb-release"
[ "$(grep -c "^CHROMEOS_AUSERVER=$DEAD\$" "$S/etc/lsb-release")" -eq 1 ] || { echo "lsb-release has no single CHROMEOS_AUSERVER" >&2; exit 1; }
[ "$(diff "$ROOTA/etc/lsb-release" "$S/etc/lsb-release" | grep -c '^[<>]')" -eq 2 ] || { echo "lsb-release: more than AUSERVER changed" >&2; exit 1; }
grep -vx os_install_service "$ROOTA/etc/ui_use_flags.txt" > "$S/etc/ui_use_flags.txt" || true
[ "$(diff "$ROOTA/etc/ui_use_flags.txt" "$S/etc/ui_use_flags.txt" | grep -c '^[<>]')" -eq 1 ] || { echo "ui_use_flags.txt: expected exactly one line (os_install_service) removed" >&2; exit 1; }
chmod 644 "$S/etc/lsb-release" "$S/etc/ui_use_flags.txt"
(cd "$ROOTA" && md5sum etc/lsb-release etc/ui_use_flags.txt) > "$S/etc/ps4-orig.md5"
mkdir -p "$S/etc/init-noupdate"
printf '# PS4 layer: lsb-release does not match ROOT-A, updater kept off.\nmanual\n' > "$S/etc/init-noupdate/update-engine.override"
echo "mesa 24.0.9 + PS4 Liverpool/Gladius; updater -> dead server, no OS install ($(sed -n 's/^CHROMEOS_RELEASE_BUILDER_PATH=//p' "$ROOTA/etc/lsb-release"), $(date -u +%F))" > "$S/LAYER_VERSION"
rm -f "$OUT"
# SELinux labels (ChromeOS enforces): the same labels the ROOT-A files carry, read from
# ROOT-A with debugfs - /usr/lib64/** cros_system_file, /etc/init/** cros_conf_file.
P=$(mktemp); trap 'rm -rf "$S" "$P"' EXIT
(cd "$S" && find . -mindepth 1 | sed 's|^\./||') | while read -r f; do
  case "$f" in etc|etc/*) ctx=u:object_r:cros_conf_file:s0 ;; *) ctx=u:object_r:cros_system_file:s0 ;; esac
  printf '%s x security.selinux=%s\n' "$f" "$ctx"
done > "$P"
printf '/ x security.selinux=u:object_r:cros_system_file:s0\n' >> "$P"
mksquashfs "$S" "$OUT" -comp xz -all-root -noappend -quiet -xattrs -pf "$P"
echo "layer: $OUT ($(stat -c %s "$OUT") bytes), $maxg max"
