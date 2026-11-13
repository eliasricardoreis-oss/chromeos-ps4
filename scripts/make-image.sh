#!/bin/bash
# Build chromeos.img for the PS4 from an official ChromeOS Flex recovery image.
#
# - Partitions 2..12 (KERN-A/B, ROOT-A/B, OEM, EFI, RWFW, ...) are copied byte-for-byte.
#   ROOT-A is never modified (immutable, verity-checked at boot).
# - STATE (partition 1) is a fresh ext4 made like ChromeOS's clobber-state does, STATE_GB big.
# - Output is compressed to chromeos.img.xz; the PS4 initramfs unpacks it once,
#   fully allocated, to /user/app/chromeos.img.
#
# Usage: make-image.sh RECOVERY.bin OUTDIR [STATE_GB]
# No root needed.
set -euo pipefail
rec=$1; out=$2; state_gb=${3:-64}
mkdir -p "$out"
img="$out/chromeos.img"
tmp="$out/tmp"; mkdir -p "$tmp"

part() { sgdisk -i "$1" "$rec" | awk -v k="$2" '$0 ~ k {print $3; exit}'; }

# 1. The new layout: same sectors as the recovery image for everything but STATE.
state_start=$(part 1 'First sector')
for n in $(seq 2 12); do
  e=$(part "$n" 'Last sector')
  [ "$e" -lt "$state_start" ] || { echo "partition $n lies after STATE, layout unexpected" >&2; exit 1; }
done
state_sectors=$((state_gb * 1024 * 1024 * 2))
total_sectors=$((state_start + state_sectors + 34))
rm -f "$img"
truncate -s $((total_sectors * 512)) "$img"

sgdisk --backup="$tmp/rec.gpt" "$rec" >/dev/null
state_guid=$(sgdisk -i 1 "$rec" | awk '/unique GUID/{print $4}')
state_type=$(sgdisk -i 1 "$rec" | awk '/Partition GUID code/{print $4}')
# One sgdisk run: load the recovery table, move the backup GPT to the new end and
# re-create STATE at the new size. (Separate runs fail when the new image is smaller
# than the recovery's STATE: the intermediate table would end past the disk.)
sgdisk --load-backup="$tmp/rec.gpt" -e -d 1 -n 1:"$state_start":$((state_start + state_sectors - 1)) \
       -t 1:"$state_type" -u 1:"$state_guid" -c 1:STATE "$img" >/dev/null
sgdisk -v "$img" | grep -q 'No problems found' || { sgdisk -v "$img"; exit 1; }

# 2. Copy partitions 2..12 exactly.
for n in $(seq 2 12); do
  s=$(part "$n" 'First sector'); e=$(part "$n" 'Last sector')
  dd if="$rec" of="$img" bs=512 skip="$s" seek="$s" count=$((e - s + 1)) conv=notrunc,sparse status=none
  cmp -n $(((e - s + 1) * 512)) <(dd if="$rec" bs=512 skip="$s" count=$((e - s + 1)) status=none) \
                                 <(dd if="$img" bs=512 skip="$s" count=$((e - s + 1)) status=none) \
    || { echo "partition $n copy mismatch" >&2; exit 1; }
done
echo "copied partitions 2-12 byte-exact"

# 3. STATE: a fresh filesystem, made the way ChromeOS's own clobber-state makes it on
#    a real device (seen in its log on the PS4): ext4, 4 KiB blocks, default inode
#    ratio and journal, features encrypt+quota+project, no label, contents only
#    unencrypted/ (root:root 0755). The recovery image's STATE is NOT reused: it
#    carries installer leftovers (dev_image, var_overlay, vmlinuz_hd.vblock).
#    Needs a kernel with CONFIG_QUOTA + CONFIG_QFMT_V2, or ChromeOS can't mount it.
rm -f "$tmp/state.img"
truncate -s $((state_sectors * 512)) "$tmp/state.img"
# ^orphan_file,^metadata_csum_seed: newer host e2fsprogs defaults ChromeOS (1.47.0) does not use.
mkfs.ext4 -q -F -b 4096 -O encrypt,quota,project,^orphan_file,^metadata_csum_seed "$tmp/state.img"
debugfs -w -R 'mkdir unencrypted' "$tmp/state.img" >/dev/null 2>&1
for f in 'uid 0' 'gid 0' 'mode 040755'; do
  debugfs -w -R "set_inode_field unencrypted $f" "$tmp/state.img" >/dev/null 2>&1
done
e2fsck -f -y "$tmp/state.img" >/dev/null 2>&1 || true   # debugfs mkdir does not update quota usage
e2fsck -f -n "$tmp/state.img" >/dev/null
feat=$(dumpe2fs -h "$tmp/state.img" 2>/dev/null | sed -n 's/^Filesystem features: *//p')
for want in encrypt quota project metadata_csum; do
  case " $feat " in *" $want "*) ;; *) echo "STATE lacks ext4 feature $want" >&2; exit 1 ;; esac
done
[ "$(debugfs -R 'stat unencrypted' "$tmp/state.img" 2>/dev/null | grep -c 'Type: directory.*Mode:  0755')" = 1 ] \
  || { echo "STATE: unencrypted/ missing or wrong mode" >&2; exit 1; }
dd if="$tmp/state.img" of="$img" bs=1M seek=$((state_start * 512)) oflag=seek_bytes conv=notrunc,sparse status=none
rm -f "$tmp/state.img"
echo "STATE: ${state_gb} GiB fresh ext4 (encrypt,quota,project), only unencrypted/ - as ChromeOS clobber makes it"

# 4. Self-check: ROOT-A in the new image verifies against Flex's own verity table.
efi_s=$(part 12 'First sector'); efi_e=$(part 12 'Last sector')
dd if="$img" of="$tmp/efi.img" bs=512 skip="$efi_s" count=$((efi_e - efi_s + 1)) status=none
7z e -y -so "$tmp/efi.img" efi/boot/grub.cfg > "$tmp/grub.cfg" 2>/dev/null
t=$(grep -m1 -o 'dm="[^"]*"' "$tmp/grub.cfg")
sec=$(echo "$t" | sed -E 's/.* 1,0 ([0-9]+) verity.*/\1/')
hs=$(echo "$t" | sed -E 's/.*hashstart=([0-9]+).*/\1/')
alg=$(echo "$t" | sed -E 's/.*alg=([a-z0-9-]+).*/\1/')
dig=$(echo "$t" | sed -E 's/.*root_hexdigest=([0-9a-f]+).*/\1/')
salt=$(echo "$t" | sed -E 's/.*salt=([0-9a-f]+).*/\1/')
ra_s=$(part 3 'First sector'); ra_e=$(part 3 'Last sector')
dd if="$img" of="$tmp/rootA.img" bs=512 skip="$ra_s" count=$((ra_e - ra_s + 1)) status=none
veritysetup verify --no-superblock --format=0 --hash="$alg" --data-block-size=4096 --hash-block-size=4096 \
  --data-blocks=$((sec / 8)) --hash-offset=$((hs * 512)) --salt="$salt" "$tmp/rootA.img" "$tmp/rootA.img" "$dig"
echo "ROOT-A verity: OK ($alg)"
rm -rf "$tmp"

# 5. Compress for transfer.
xz -T0 -6 -f -k "$img"
sha256sum "$img.xz" > "$img.xz.sha256"
ls -la "$out"
