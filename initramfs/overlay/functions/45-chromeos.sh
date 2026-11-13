#!/bin/sh

# ChromeOS (Flex) on PS4. ROOT-A is immutable: mounted read-only through dm-verity
# with Google's own hash from the image's grub.cfg. Only STATE (partition 1) is
# written to. PS4 additions live in a separate read-only layer (ps4-layer.sqfs).
#
# First start: a menu on the TV asks where ChromeOS goes (the PS4 drive or a USB
# drive) and how big its storage (STATE) is; without a keyboard it installs to the
# PS4 drive at the recommended minimum. The choice is kept in
#   /data/linux/boot/chromeos-target:  target=internal|external  state_gib=<n>|max
# chromeos.img.xz is a small seed (system partitions + a tiny STATE); the install
# grows it to the chosen size (gpt-grow-state) and formats STATE fresh.
#   internal: /user/app/chromeos.img on the PS4 drive (loop device)
#   external: written raw to the chosen USB drive, found again by its GPT disk GUID
CROS_BOOT=/ps4hdd/data/linux/boot
CROS_IMG=/ps4hdd/app/chromeos.img
# Space reserved by the PKG app from OrbisOS (zeros, default size); used by the install.
# It is in /data (the app sandbox cannot reach /user/app), same partition: moved by rename.
CROS_ALLOC=${CROS_BOOT}/chromeos.img.alloc
# Where + how big, chosen in the app (target=internal state_gib=N | target=external).
CROS_CHOICE_FILE=${CROS_BOOT}/chromeos-install-choice
CROS_XZ_DIRS="${CROS_BOOT} /ps4hdd/system/boot"
CROS_TARGET_FILE=${CROS_BOOT}/chromeos-target
CROS_EXT_GUID_FILE=${CROS_BOOT}/chromeos-external.guid
CROS_STATE_MIN_GIB=32        # recommended minimum, the default
CROS_PS4_RESERVE_GIB=10      # always leave this much free on the PS4 drive
CROS_MENU_TIMEOUT=30
CROS_FRESH_STATE=

cros_say() {
	# User-facing message that is shown even in quiet (release) mode.
	kernel_msg_lvl 4 "$*"
	echo -ne "\033[1;33m>>> $*\033[0m\n" >&2
}

# Warnings are never hidden, even in quiet (release) mode: a failed boot must say why.
ewarn() {
	kernel_msg_lvl 4 "${*}"
	echo -ne "\033[1;30m>\033[0;33m>\033[1;33m> \033[0m${*}\n" >&2
}

# Debug-only hooks; the debug build redefines these (functions/48-chromeos-debug.sh).
cros_dump_log() { :; }

# The PS4 drive key: the Linux loader reads it from OrbisOS's kernel memory (per-firmware
# offset), appends it to the initramfs as /key/eap_hdd_key.bin (32 bytes), and the kernel
# (ps4-ccp) also exposes it at /sys/firmware/ps4/eap_hdd_key. ps4hdd_open decrypts
# /dev/sdX27 with it (AES-XTS; offset 0 on Aeolia, 111669149696 on Belize/Baikal).
cros_check_hdd_key() {
	local k=/key/eap_hdd_key.bin
	if [ ! -s "${k}" ] && [ -s /sys/firmware/ps4/eap_hdd_key ]; then
		mkdir -p /key && cat /sys/firmware/ps4/eap_hdd_key > "${k}"
	fi
	if [ ! -s "${k}" ]; then
		eerror "No PS4 drive key: the Linux loader did not pass /key/eap_hdd_key.bin."
		eerror "Use the loader payload for this firmware (ps4-chromeos-loader.bin supports 5.05-14.00)."
		return 1
	fi
	if [ "$(stat -c %s "${k}")" != 32 ]; then
		eerror "PS4 drive key has the wrong size ($(stat -c %s "${k}") bytes, expected 32)."
		return 1
	fi
	if [ -z "$(od -An -tx1 "${k}" | tr -d ' \n0')" ]; then
		eerror "PS4 drive key is all zeros: the loader could not read it on this firmware."
		return 1
	fi
	return 0
}

# PS4 drive handoff, all models (replaces ps4hdd_open from functions/30-ps4-hardware.sh;
# init calls it too). Source: fs/ufs/super.c.
#  - Linux never marks UFS2 dirty on disk, but the cylinder-group summary table (s_csp) is
#    written only at unmount / remount-ro (ufs_put_super_internal); sync only writes totals.
#    So every allocation must happen before cros_ps4hdd_commit (umount + mount), which runs
#    before chromeos.img is opened. After that nothing allocates: UFS has no fallocate,
#    so loop never punches holes (drivers/block/loop.c), and ChromeOS only rewrites blocks
#    of the fully written image. Its shutdown syncs after unmounting STATE
#    (chromeos_shutdown), so the drive is consistent at power-off without an unmount.
#  - The UFS driver mounts read-only (only pr_err) if the fs is "active", "bad" or "needs
#    fsck"; that is refused here instead of failing later on writes.
CROS_UFS_OPTS=ufstype=ufs2,noatime
cros_ps4hdd_mount() {
	mkdir -p /ps4hdd
	mount -t ufs -o "${CROS_UFS_OPTS}" /dev/mapper/ps4hdd /ps4hdd || return 1
	if awk '$2 == "/ps4hdd" { split($4, o, ","); if (o[1] == "ro") f = 1 } END { exit !f }' /proc/mounts; then
		eerror "The PS4 drive file system is not clean (Linux mounted it read-only)."
		eerror "Boot OrbisOS once and shut it down normally, then try again."
		umount /ps4hdd
		return 2
	fi
	if [ ! -d /ps4hdd/app ] || [ ! -d /ps4hdd/data ]; then
		umount /ps4hdd
		return 1
	fi
	return 0
}

ps4hdd_open() {
	mountpoint -q /ps4hdd && return 0
	cros_check_hdd_key || return 1
	local part skip rc
	case "$(ps4_southbridge)" in
	Aeolia) skip="" ;;
	Belize|Baikal) skip="--skip 111669149696" ;;
	*) eerror "Unknown PS4 southbridge (PCI 00:14.4 = $(cat /sys/bus/pci/devices/0000:00:14.4/device 2>/dev/null)): not opening the drive."; return 1 ;;
	esac
	# A mapping left from an earlier try: use it if it mounts, else drop it.
	if [ -b /dev/mapper/ps4hdd ]; then
		cros_ps4hdd_mount && return 0
		cryptsetup remove ps4hdd 2>/dev/null
	fi
	for part in /dev/sd?27; do
		[ -b "${part}" ] || continue
		kernel_msg "Opening ${part} as /dev/mapper/ps4hdd"
		# shellcheck disable=SC2086
		cryptsetup -d /key/eap_hdd_key.bin --cipher aes-xts-plain64 -s 256 --offset 0 ${skip} \
			create ps4hdd "${part}" || { ewarn "cryptsetup failed on ${part}."; continue; }
		cros_ps4hdd_mount; rc=$?
		if [ "${rc}" -eq 0 ]; then
			kernel_msg "Mounted ${part} (PS4 drive) on /ps4hdd (${CROS_UFS_OPTS})"
			return 0
		fi
		cryptsetup remove ps4hdd 2>/dev/null
		[ "${rc}" -eq 2 ] && return 1
		ewarn "${part} is not the PS4 drive (no UFS2 with app/ and data/ under this key)."
	done
	ewarn "No PS4 internal drive found (no /dev/sd?27)."
	return 1
}

cros_ps4hdd_commit() {
	# Write UFS allocation state to disk (see above): umount + mount. Before loop setup only.
	sync
	if ! umount /ps4hdd; then
		ewarn "Could not unmount /ps4hdd to commit it: $(grep ' /ps4hdd' /proc/mounts | head -n 1)"
		return 0
	fi
	cros_ps4hdd_mount || { eerror "Could not mount the PS4 drive again."; return 1; }
	kernel_msg "PS4 drive committed (umount + mount)"
}

cros_cfg() {
	# cros_cfg KEY -> value of KEY=... in chromeos-target
	sed -n "s/^[[:space:]]*$1=//p" "${CROS_TARGET_FILE}" 2>/dev/null | head -n 1 | tr -d '\r[:space:]'
}

cros_xz() {
	# Path of chromeos.img.xz (with its .size next to it) or nothing.
	local d
	for d in ${CROS_XZ_DIRS}; do
		[ -f "${d}/chromeos.img.xz" ] && { echo "${d}/chromeos.img.xz"; return 0; }
	done
	return 1
}

cros_xz_size() {
	local want
	want="$(cat "${1%.xz}.size" 2>/dev/null)"
	case "${want}" in ''|*[!0-9]*) return 1 ;; esac
	echo "${want}"
}

# ---------------------------------------------------------------- disks
cros_disk_guid() {
	# GPT disk GUID (raw bytes as hex) of block device $1, or nothing.
	local sig
	sig="$(dd if="$1" bs=512 skip=1 count=1 2>/dev/null | dd bs=1 count=8 2>/dev/null)"
	[ "${sig}" = "EFI PART" ] || return 1
	dd if="$1" bs=512 skip=1 count=1 2>/dev/null | od -An -tx1 -j56 -N16 | tr -d ' \n'
}

cros_is_internal_disk() {
	# The PS4's own drive is the one with partition 27 (the encrypted user partition).
	[ -b "/dev/${1}27" ]
}

cros_external_disks() {
	# Candidate external disks: every sd* that is not the PS4's internal drive.
	local b
	for b in /sys/block/sd*; do
		[ -e "${b}" ] || continue
		cros_is_internal_disk "${b##*/}" && continue
		echo "${b##*/}"
	done
}

cros_disk_gib() { echo $(( $(cat "/sys/block/$1/size" 2>/dev/null || echo 0) / 2097152 )); }

cros_disk_name() {
	local v m
	v="$(cat "/sys/block/$1/device/vendor" 2>/dev/null | tr -s ' ')"
	m="$(cat "/sys/block/$1/device/model" 2>/dev/null | tr -s ' ')"
	echo "${v}${m}" | sed 's/^ *//;s/ *$//'
}

cros_find_external() {
	# Already-installed external ChromeOS disk, found by its recorded GPT disk GUID.
	local want d i=0
	want="$(tr -d ' \n' < "${CROS_EXT_GUID_FILE}" 2>/dev/null)"
	[ -n "${want}" ] || return 1
	while [ "${i}" -lt 15 ]; do
		for d in $(cros_external_disks); do
			[ "$(cros_disk_guid "/dev/${d}")" = "${want}" ] && { echo "${d}"; return 0; }
		done
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# ---------------------------------------------------------------- first-start menu
cros_tty() {
	if [ -n "${console}" ] && [ -c "/dev/${console}" ]; then echo "/dev/${console}"
	elif [ -c /dev/tty1 ]; then echo /dev/tty1
	else echo /dev/console; fi
}

cros_ask() {
	# cros_ask DEFAULT TIMEOUT -> one key (or DEFAULT after TIMEOUT seconds / no keyboard)
	local k tty
	tty="$(cros_tty)"
	if read -r -t "$2" -n 1 k < "${tty}" 2>/dev/null && [ -n "${k}" ]; then echo "${k}"; else echo "$1"; fi
}

cros_menu() {
	# cros_menu [usb]: sets CROS_MENU_TARGET (internal|external), CROS_MENU_DISK,
	# CROS_MENU_STATE (GiB|max). "usb": USB drive already chosen in the app - only the
	# drive (and its storage size) is asked. Fails (and forgets that choice) if none is picked.
	local tty free_gib max_gib n d k opts i=1 sz confirm usb="${1:-}" w=0
	tty="$(cros_tty)"
	# Space the app reserved for the image counts as free for the internal install.
	free_gib=$(( ( $(df -Pk /ps4hdd | awk 'END { print $4 }') + $( [ -f "${CROS_ALLOC}" ] && stat -c %s "${CROS_ALLOC}" || echo 0) / 1024 ) / 1048576 ))
	max_gib=$(( free_gib - CROS_PS4_RESERVE_GIB - 4 ))
	ps4_change_led orange
	if [ -n "${usb}" ]; then
		# Give a USB drive plugged in late up to 60 s to show up.
		while [ -z "$(cros_external_disks)" ] && [ "${w}" -lt 60 ]; do
			[ "${w}" -eq 0 ] && cros_say "Connect the USB drive for ChromeOS ..."
			sleep 2; w=$((w + 2))
		done
		if [ -z "$(cros_external_disks)" ]; then
			rm -f "${CROS_CHOICE_FILE}"
			eerror "No USB drive found. Restart ChromeOS for PS4 to choose again (PS4 drive or USB)."
			return 1
		fi
	fi
	{
		echo; echo "  =========  ChromeOS for PS4 - first start  ========="
		if [ -n "${usb}" ]; then
			echo; echo "  Which USB drive should ChromeOS be installed on?"; echo
		else
			echo; echo "  Where should ChromeOS be installed?"; echo
			echo "    1) PS4 internal drive   (${free_gib} GB free, games and saves stay)"
		fi
	} > "${tty}"
	n=1
	for d in $(cros_external_disks); do
		n=$((n + 1))
		eval "CROS_DISK_${n}=${d}"
		echo "    ${n}) USB drive /dev/${d}: $(cros_disk_name "${d}"), $(cros_disk_gib "${d}") GB  - ERASES IT" > "${tty}"
	done
	if [ -n "${usb}" ]; then
		echo; echo "  Press a number (USB keyboard; nothing is erased without it): " > "${tty}"
		k="$(cros_ask 0 120)"
	else
		echo; echo "  Press a number (default 1 in ${CROS_MENU_TIMEOUT} s): " > "${tty}"
		k="$(cros_ask 1 "${CROS_MENU_TIMEOUT}")"
	fi
	CROS_MENU_TARGET=internal; CROS_MENU_DISK=
	case "${k}" in
	[2-9])
		eval "d=\${CROS_DISK_${k}}"
		if [ -n "${d}" ] && ! cros_is_internal_disk "${d}"; then
			echo "  Type ERASE and press Enter to erase /dev/${d} ($(cros_disk_name "${d}")), anything else cancels:" > "${tty}"
			read -r -t 120 confirm < "${tty}" 2>/dev/null
			if [ "${confirm}" = "ERASE" ]; then CROS_MENU_TARGET=external; CROS_MENU_DISK=${d}
			elif [ -z "${usb}" ]; then echo "  Cancelled: installing to the PS4 internal drive." > "${tty}"; fi
		fi
		;;
	esac
	if [ -n "${usb}" ] && [ "${CROS_MENU_TARGET}" != external ]; then
		rm -f "${CROS_CHOICE_FILE}"
		eerror "No USB drive chosen, nothing was erased. Restart ChromeOS for PS4 to choose again."
		return 1
	fi
	if [ "${CROS_MENU_TARGET}" = external ]; then
		max_gib=$(( $(cros_disk_gib "${CROS_MENU_DISK}") - 4 ))
	fi
	if [ "${max_gib}" -lt 8 ]; then
		eerror "Not enough space: ${max_gib} GB available, ChromeOS needs at least 8 GB (${CROS_STATE_MIN_GIB} GB recommended)."
		return 1
	fi
	if [ "${max_gib}" -lt "${CROS_STATE_MIN_GIB}" ]; then
		CROS_MENU_STATE=max
		[ "${CROS_MENU_TARGET}" = internal ] && CROS_MENU_STATE=${max_gib}
		cros_say "Only ${max_gib} GB available, using all of it (recommended: ${CROS_STATE_MIN_GIB} GB)."
		return 0
	fi
	{
		echo; echo "  How much storage for ChromeOS (apps, files, Android, Linux)?"; echo
		echo "    1) ${CROS_STATE_MIN_GIB} GB  (recommended minimum)"
	} > "${tty}"
	opts="${CROS_STATE_MIN_GIB}"; i=1
	for sz in 64 128 256; do
		[ "${sz}" -le "${max_gib}" ] || continue
		i=$((i + 1)); opts="${opts} ${sz}"
		echo "    ${i}) ${sz} GB" > "${tty}"
	done
	i=$((i + 1)); opts="${opts} max"
	if [ "${CROS_MENU_TARGET}" = external ]; then echo "    ${i}) the whole drive (${max_gib} GB)" > "${tty}"
	else echo "    ${i}) all free space but ${CROS_PS4_RESERVE_GIB} GB (${max_gib} GB)" > "${tty}"; fi
	echo; echo "  Press a number (default 1 in ${CROS_MENU_TIMEOUT} s): " > "${tty}"
	k="$(cros_ask 1 "${CROS_MENU_TIMEOUT}")"
	case "${k}" in [1-9]) ;; *) k=1 ;; esac
	CROS_MENU_STATE="$(echo ${opts} | cut -d' ' -f"${k}")"
	[ -n "${CROS_MENU_STATE}" ] || CROS_MENU_STATE=${CROS_STATE_MIN_GIB}
	[ "${CROS_MENU_STATE}" = max ] && [ "${CROS_MENU_TARGET}" = internal ] && CROS_MENU_STATE=${max_gib}
	echo > "${tty}"
}

# ---------------------------------------------------------------- install
cros_seed_state_start() {
	# First sector of partition 1 (STATE) in the GPT of file/device $1.
	od -An -tu8 -j1056 -N8 "$1" | tr -d ' \n'
}

cros_install_internal() {
	# cros_install_internal STATE_GIB
	local gib="$1" xzf seed start total have
	xzf="$(cros_xz)" || { eerror "No chromeos.img.xz in ${CROS_BOOT}."; return 1; }
	seed="$(cros_xz_size "${xzf}")" || { eerror "Missing or bad ${xzf%.xz}.size next to ${xzf}."; return 1; }
	# Never mkdir on the PS4 drive (Linux UFS2 mkdir corrupted a directory before).
	[ -d /ps4hdd/app ] || { eerror "/user/app is missing on the PS4 drive."; return 1; }
	cros_say "Installing ChromeOS to the PS4 drive (${gib} GB). This takes a while - do not turn off the PS4."
	ps4_change_led orange
	rm -f "${CROS_IMG}.part"
	if [ -f "${CROS_ALLOC}" ] && [ "$(stat -c %s "${CROS_ALLOC}")" -ge "${seed}" ]; then
		# Space already reserved by the PKG app from OrbisOS (fully written, not sparse):
		# unpack the seed into it in place - overwriting allocated blocks, no allocation.
		kernel_msg "Using the space reserved by the app: ${CROS_ALLOC} ($(stat -c %s "${CROS_ALLOC}") bytes)"
		mv "${CROS_ALLOC}" "${CROS_IMG}.part" || { eerror "Could not rename ${CROS_ALLOC}."; return 1; }
		if ! xz -dc "${xzf}" | pv -s "${seed}" | dd of="${CROS_IMG}.part" bs=1048576 conv=notrunc 2>/dev/null; then
			eerror "Unpacking ${xzf} failed."; rm -f "${CROS_IMG}.part"; return 1
		fi
	elif ! xz -dc "${xzf}" | pv -s "${seed}" > "${CROS_IMG}.part"; then
		eerror "Unpacking ${xzf} failed."; rm -f "${CROS_IMG}.part"; return 1
	fi
	start="$(cros_seed_state_start "${CROS_IMG}.part")"
	case "${start}" in ''|*[!0-9]*) eerror "Seed image has no GPT."; rm -f "${CROS_IMG}.part"; return 1 ;; esac
	# STATE start + STATE + backup GPT (33 sectors), rounded up to whole MiB.
	total=$(( (start * 512 + gib * 1073741824 + 34 * 512 + 1048575) / 1048576 * 1048576 ))
	have="$(stat -c %s "${CROS_IMG}.part")"
	# A reserved file bigger than needed (smaller STATE chosen) is kept as is: STATE ends at
	# ${gib} GiB, the backup GPT goes to the end of the file (gpt-grow-state).
	if [ "${have}" -lt "${total}" ]; then
		cros_say "Allocating ${gib} GB for ChromeOS on the PS4 drive ..."
		# Fully allocated (zeros written), never sparse: Linux's UFS driver is safest that way.
		if ! dd if=/dev/zero bs=1048576 count=$(( (total - have) / 1048576 )) 2>/dev/null \
			| pv -s $(( total - have )) >> "${CROS_IMG}.part"; then
			eerror "Allocating space failed."; rm -f "${CROS_IMG}.part"; return 1
		fi
	fi
	sync
	gpt-grow-state "${CROS_IMG}.part" "${gib}" || { eerror "Growing STATE failed."; rm -f "${CROS_IMG}.part"; return 1; }
	mv "${CROS_IMG}.part" "${CROS_IMG}" && sync
	CROS_FRESH_STATE=1
	cros_say "ChromeOS installed to the PS4 drive."
}

cros_install_external() {
	# cros_install_external DISK STATE_GIB|max  (erases DISK)
	local d="$1" gib="$2" xzf seed guid
	cros_is_internal_disk "${d}" && { eerror "Refusing to write to the PS4 internal drive."; return 1; }
	xzf="$(cros_xz)" || { eerror "No chromeos.img.xz in ${CROS_BOOT}."; return 1; }
	seed="$(cros_xz_size "${xzf}")" || { eerror "Missing or bad ${xzf%.xz}.size."; return 1; }
	cros_say "Installing ChromeOS to /dev/${d} ($(cros_disk_name "${d}")). Do not unplug it."
	ps4_change_led orange
	if ! xz -dc "${xzf}" | pv -s "${seed}" | dd of="/dev/${d}" bs=4M conv=fsync 2>/dev/null; then
		eerror "Writing ChromeOS to /dev/${d} failed."; return 1
	fi
	sync
	if [ "${gib}" = max ]; then gpt-grow-state "/dev/${d}" || return 1
	else gpt-grow-state "/dev/${d}" "${gib}" || return 1; fi
	blockdev --rereadpt "/dev/${d}" 2>/dev/null
	guid="$(cros_disk_guid "/dev/${d}")" || { eerror "No GPT on /dev/${d} after writing."; return 1; }
	echo "${guid}" > "${CROS_EXT_GUID_FILE}"
	CROS_FRESH_STATE=1
	sync
	cros_say "ChromeOS installed to /dev/${d}."
}

cros_choice_fits() {
	# cros_choice_fits GIB: the PS4 drive has room for a STATE of GIB (reserved space counts).
	local free_gib
	free_gib=$(( ( $(df -Pk /ps4hdd | awk 'END { print $4 }') + $( [ -f "${CROS_ALLOC}" ] && stat -c %s "${CROS_ALLOC}" || echo 0) / 1024 ) / 1048576 ))
	[ "$1" -le $(( free_gib - CROS_PS4_RESERVE_GIB - 4 )) ]
}

cros_first_start() {
	# Runs only when ChromeOS is not installed yet. The app's choice (if any) replaces
	# the questions it already answered.
	local ct cg
	ct="$(sed -n 's/^[[:space:]]*target=//p' "${CROS_CHOICE_FILE}" 2>/dev/null | head -n 1 | tr -d '\r[:space:]')"
	cg="$(sed -n 's/^[[:space:]]*state_gib=//p' "${CROS_CHOICE_FILE}" 2>/dev/null | head -n 1 | tr -d '\r[:space:]')"
	case "${cg}" in ''|*[!0-9]*) cg= ;; esac
	if [ "${ct}" = internal ] && [ -n "${cg}" ] && [ "${cg}" -ge 8 ] && cros_choice_fits "${cg}"; then
		kernel_msg "Install choice from the app: PS4 drive, ${cg} GB"
		ps4_change_led orange
		CROS_MENU_TARGET=internal; CROS_MENU_DISK=; CROS_MENU_STATE=${cg}
	elif [ "${ct}" = external ]; then
		kernel_msg "Install choice from the app: USB drive"
		cros_menu usb || return 1
	else
		[ -n "${ct}" ] && ewarn "Install choice from the app (${ct} ${cg}) does not fit: asking again."
		cros_menu || return 1
	fi
	if [ "${CROS_MENU_TARGET}" = external ]; then
		# The space the app reserved on the PS4 drive is not needed: give it back.
		rm -f "${CROS_ALLOC}" "${CROS_ALLOC}.part"
		cros_install_external "${CROS_MENU_DISK}" "${CROS_MENU_STATE}" || return 1
		printf 'target=external\nstate_gib=%s\n' "${CROS_MENU_STATE}" > "${CROS_TARGET_FILE}"
	else
		cros_install_internal "${CROS_MENU_STATE}" || return 1
		printf 'target=internal\nstate_gib=%s\n' "${CROS_MENU_STATE}" > "${CROS_TARGET_FILE}"
	fi
	rm -f "${CROS_CHOICE_FILE}"
	sync
}

cros_field() {
	# cros_field NAME TABLE -> value of NAME=... in a ChromeOS dm="..." table
	echo "$2" | tr ' "' '\n\n' | sed -n "s/^$1=//p" | head -n 1
}

cros_port_wait() {
	# cros_port_wait PORT SECONDS: wait until a device on a usb port is configured.
	local i=0
	while [ "${i}" -lt "$2" ]; do
		[ "$(cat "$1/state" 2>/dev/null)" = configured ] && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

cros_port_cycle() {
	# cros_port_cycle PORT OFF_SECONDS: switch a usb port off and on again.
	echo 1 > "$1/disable" 2>/dev/null || return 1
	sleep "$2"
	echo 0 > "$1/disable" 2>/dev/null
}

cros_aeolia_hdd_kick() {
	# Aeolia (Fat CUH-10xx/11xx): the internal HDD is the SCEI USB-SATA bridge (054c:084e) on
	# the "middle" xHCI host (index 1 in xhci-aeolia.c, probed second -> buses 3 + 4). After the
	# OrbisOS shutdown that the loader runs before kexec, its SuperSpeed link fails to address
	# ("device not accepting address, error -71", then "attempt power cycle", port "not
	# attached"; on other boots still retrying with error -110). Verified on a CUH-1115A:
	# switching the SuperSpeed port off makes the bridge reconnect on the USB 2 peer port
	# (480 Mbit/s); switching that port off makes it come back on SuperSpeed (5 Gbit/s, ~97 MB/s). If the second step fails it stays on USB 2.
	# Belize/Baikal (Fat CUH-12xx, Slim, Pro): HDD is AHCI, never USB - this returns here.
	[ "$(ps4_southbridge)" = Aeolia ] || return 1
	local b hub n=0 mid="" p peer
	for b in 1 2 3 4 5 6 7 8 9 10 11 12; do
		hub="/sys/bus/usb/devices/usb${b}"
		[ -e "${hub}" ] || continue
		readlink -f "${hub}" | grep -q '0000:00:14\.7/' || continue
		[ "$(cat "${hub}/speed" 2>/dev/null)" = 5000 ] || continue
		n=$((n + 1))
		[ "${n}" -eq 2 ] && { mid="${hub}"; break; }
	done
	[ -n "${mid}" ] || return 1
	local rc=1
	for p in "${mid}"/*-0:1.0/usb*-port*; do
		[ -e "${p}/disable" ] || continue
		# Any state but "configured": the bridge either gave up ("not attached", -71) or is
		# still stuck in retries ("device descriptor read/8, error -110", seen on the Fat).
		[ "$(cat "${p}/state" 2>/dev/null)" = configured ] && continue
		peer="$(readlink -f "${p}/peer" 2>/dev/null)"
		[ -n "${peer}" ] && [ -e "${peer}/disable" ] || continue
		# A device already up on the USB 2 side is left alone (sdX may just not be there yet).
		[ "$(cat "${peer}/state" 2>/dev/null)" = configured ] && continue
		kernel_msg "Aeolia HDD: SuperSpeed link down on $(basename "${p}"), resetting the bridge"
		cros_port_cycle "${p}" 2 || continue
		if cros_port_wait "${peer}" 8; then
			kernel_msg "Aeolia HDD: bridge up on USB 2 ($(basename "${peer}")), moving it to SuperSpeed"
			cros_port_cycle "${peer}" 3
			cros_port_wait "${p}" 10 \
				&& kernel_msg "Aeolia HDD: SuperSpeed link up on $(basename "${p}")" \
				|| kernel_msg "Aeolia HDD: SuperSpeed did not come back, staying on USB 2"
		else
			kernel_msg "Aeolia HDD: no device on $(basename "${peer}") either"
		fi
		rc=0
	done
	return "${rc}"
}

cros_wait_ps4_drive() {
	# cros_wait_ps4_drive SECONDS: wait for /dev/sd?27 (the PS4's encrypted user partition).
	# Counted in loop passes; on Aeolia a pass with a bridge reset takes ~15 s more.
	local i=0
	ls /dev/sd?27 >/dev/null 2>&1 && return 0
	cros_say "Waiting for the PS4 drive ..."
	while [ "${i}" -lt "$1" ]; do
		sleep 1
		i=$((i + 1))
		ls /dev/sd?27 >/dev/null 2>&1 && { kernel_msg "PS4 drive appeared (wait pass ${i})"; return 0; }
		# Aeolia: reset the HDD bridge at pass 5, then every 10 passes until it shows up.
		[ "${i}" -ge 5 ] && [ $(( (i - 5) % 10 )) -eq 0 ] && cros_aeolia_hdd_kick
	done
	ls /dev/sd?27 >/dev/null 2>&1
}

cros_mount_inner() {
	has_cmdline "nochromeos" && return 1
	cros_check_hdd_key || return 1
	# The PS4 drive can appear late: on Aeolia it is a USB 3 device on the "middle" xHCI
	# host (drivers/usb/host/xhci-aeolia.c), enumerated after the initramfs starts.
	cros_wait_ps4_drive 40
	if ! ps4hdd_open; then
		if [ -z "$(ls /dev/sd?27 2>/dev/null)" ]; then
			eerror "The PS4 internal drive (partition 27) was not found."
		else
			eerror "The PS4 drive did not open with the key (wrong key, or wrong Aeolia/Belize/Baikal offset)."
			eerror "Southbridge: $(ps4_southbridge)."
		fi
		return 1
	fi

	local target pfx release d i t sec hs alg dig salt
	# Not installed yet (no image file, no recorded external drive): first-start menu.
	target="$(cros_cfg target)"
	if [ ! -f "${CROS_IMG}" ] && { [ "${target}" != external ] || [ ! -s "${CROS_EXT_GUID_FILE}" ]; }; then
		cros_first_start || return 1
		target="$(cros_cfg target)"
	fi
	# Installed already: a space reservation left by the app is not needed (before the commit).
	[ -f "${CROS_ALLOC}" ] || [ -f "${CROS_ALLOC}.part" ] && { kernel_msg "Removing unused ${CROS_ALLOC}"; rm -f "${CROS_ALLOC}" "${CROS_ALLOC}.part"; }
	# Last change to the PS4 drive's space: the one-time STATE-reset flag. Then commit.
	CROS_RESET_PENDING=
	if [ -f "${CROS_RESET_FLAG}" ]; then
		CROS_RESET_PENDING=1
		rm -f "${CROS_RESET_FLAG}"
	fi
	cros_ps4hdd_commit || return 1
	case "${target:-internal}" in
	internal)
		[ -f "${CROS_IMG}" ] || { eerror "${CROS_IMG} is missing."; return 1; }
		# PARTSCAN per device instead of loop.max_part: keeps minor == loop number,
		# which ChromeOS's own loop handling (mount-encrypted) relies on.
		d="$(loop-partscan "${CROS_IMG}")" || { eerror "loop-partscan ${CROS_IMG} failed."; return 1; }
		pfx="${d}p"
		release="losetup -d ${d}"
		;;
	external)
		d="$(cros_find_external)" || { eerror "The USB drive with ChromeOS is not connected."; return 1; }
		pfx="/dev/${d}"
		release=":"
		;;
	*)
		eerror "chromeos-target: unknown target=${target}."
		return 1
		;;
	esac

	i=0
	while { [ ! -b "${pfx}3" ] || [ ! -b "${pfx}12" ]; } && [ "${i}" -lt 10 ]; do
		sleep 1
		i=$((i + 1))
	done
	if [ ! -b "${pfx}3" ] || [ ! -b "${pfx}12" ]; then
		eerror "No ChromeOS partitions at ${pfx}N."
		${release}
		return 1
	fi

	cros_reset_state "${pfx}1"

	mkdir -p /cros-efi
	mount -t vfat -o ro "${pfx}12" /cros-efi || { eerror "Cannot mount EFI-SYSTEM (${pfx}12)."; ${release}; return 1; }
	t="$(grep -m 1 -o 'dm="[^"]*"' /cros-efi/efi/boot/grub.cfg)"
	umount /cros-efi
	sec="$(echo "${t}" | sed -n 's/.* 1,0 \([0-9]*\) verity .*/\1/p')"
	hs="$(cros_field hashstart "${t}")"
	alg="$(cros_field alg "${t}")"
	dig="$(cros_field root_hexdigest "${t}")"
	salt="$(cros_field salt "${t}")"
	if [ -z "${sec}" ] || [ -z "${hs}" ] || [ -z "${alg}" ] || [ -z "${dig}" ] || [ -z "${salt}" ]; then
		eerror "Could not read the verity table from grub.cfg."
		${release}
		return 1
	fi

	# ChromeOS hash trees are dm-verity format version 0, no superblock.
	kernel_msg "ChromeOS: verity ${alg} on ${pfx}3, ${sec} sectors"
	if ! dmsetup create vroot --readonly --table \
		"0 ${sec} verity 0 ${pfx}3 ${pfx}3 4096 4096 $((sec / 8)) $((hs / 8)) ${alg} ${dig} ${salt}"; then
		eerror "dm-verity setup failed (ROOT-A does not match Google's hash)."
		${release}
		return 1
	fi
	if ! mount -o ro /dev/mapper/vroot /newroot; then
		eerror "Cannot mount ROOT-A (verity) on /newroot."
		dmsetup remove vroot
		${release}
		return 1
	fi
	ps4_chromeos=1
	einfo "ChromeOS $(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' /newroot/etc/lsb-release) (${target:-internal}, ROOT-A verified)."
}

cros_mount() {
	local rc=0
	cros_mount_inner || rc=$?
	if [ "${rc}" -eq 0 ]; then
		cros_dump_log "cros_mount ok"
	else
		cros_dump_log "cros_mount FAILED rc=${rc}"
	fi
	return "${rc}"
}

cros_ps4_layer() {
	# Read-only PS4 layer: initramfs firmware stacked over ROOT-A's /lib/firmware.
	# Lives on its own tmpfs so switch_root does not delete it. ROOT-A itself is untouched.
	[ -n "${ps4_chromeos}" ] || return 0
	mkdir -p /ps4layer
	mount -t tmpfs -o mode=755,size=64m ps4layer /ps4layer || return 1
	mkdir -p /ps4layer/firmware
	cp -a /lib/firmware/. /ps4layer/firmware/
	mount -o remount,ro /ps4layer
	mount -t overlay -o ro,lowerdir=/ps4layer/firmware:/newroot/lib/firmware ps4fw /newroot/lib/firmware \
		|| ewarn "Could not stack PS4 firmware over /lib/firmware."
	cros_ps4_syslayer
	cros_ps4_audio
}

# Read-only PS4 system layer: /data/linux/boot/ps4-layer.sqfs (squashfs, SELinux-labelled),
# stacked over ROOT-A's /usr/lib64 (PS4-patched Mesa), /etc/init (Upstart overrides) and
# /etc/lsb-release + /etc/ui_use_flags.txt (updater -> dead server, no OS install;
# see scripts/make-layer.sh).
# To update, replace that one file. ROOT-A itself is never modified and stays verity-checked.
CROS_SYSLAYER=${CROS_BOOT}/ps4-layer.sqfs
cros_ps4_syslayer() {
	[ -f "${CROS_SYSLAYER}" ] || { ewarn "No ${CROS_SYSLAYER}: PS4 graphics fixes missing."; return 0; }
	mkdir -p /ps4sys
	if ! mount -t squashfs -o ro,loop "${CROS_SYSLAYER}" /ps4sys; then
		ewarn "Could not mount ${CROS_SYSLAYER}."
		return 0
	fi
	local d f low lsb=false
	# Patched copies of ROOT-A's etc/lsb-release (updater -> dead server) and
	# etc/ui_use_flags.txt (no "Install ChromeOS Flex"), see scripts/make-layer.sh. Bound
	# only if ROOT-A has exactly the originals they were made from; else the updater stays off.
	if [ -f /ps4sys/etc/ps4-orig.md5 ] && (cd /newroot && md5sum -c -s /ps4sys/etc/ps4-orig.md5); then
		lsb=true
		for f in $(awk '{print $2}' /ps4sys/etc/ps4-orig.md5); do
			mount -o bind "/ps4sys/${f}" "/newroot/${f}" || { lsb=false; ewarn "Could not bind /${f}."; }
		done
	else
		ewarn "PS4 layer does not match this ChromeOS image: updater kept off."
	fi
	for d in usr/lib64 etc/init; do
		[ -d "/ps4sys/${d}" ] || continue
		low="/ps4sys/${d}:/newroot/${d}"
		[ "${d}" = etc/init ] && [ "${lsb}" = false ] && [ -d /ps4sys/etc/init-noupdate ] \
			&& low="/ps4sys/etc/init-noupdate:${low}"
		mount -t overlay -o "ro,lowerdir=${low}" "ps4-${d##*/}" "/newroot/${d}" \
			|| ewarn "Could not stack the PS4 system layer over /${d}."
	done
	einfo "PS4 system layer: $(cat /ps4sys/LAYER_VERSION 2>/dev/null)"
}

# One-time STATE reset: if /data/linux/boot/chromeos-reset-state exists, STATE is
# reformatted exactly like ChromeOS's clobber-state does (ext4 4k, encrypt,quota,
# project, only unencrypted/), but with inode tables and journal written out in
# full: BLKZEROOUT through loop on the PS4's UFS can't be trusted to read back
# as zeros, which is how a lazily-initialised STATE got corrupt. The flag file
# is removed before chromeos.img opens (cros_ps4hdd_commit), so it runs once.
# (Erases ChromeOS user data.)
CROS_RESET_FLAG=${CROS_BOOT}/chromeos-reset-state
cros_reset_state() {
	[ -n "${CROS_RESET_PENDING}" ] || [ -n "${CROS_FRESH_STATE}" ] || return 0
	local dev="$1"
	if [ -n "${CROS_FRESH_STATE}" ]; then cros_say "Preparing ChromeOS storage on ${dev} ..."; else cros_say "Resetting ChromeOS user data on ${dev} (one time) ..."; fi
	ps4_change_led orange
	if mkfs.ext4 -q -F -b 4096 -O encrypt,quota,project,^orphan_file,^metadata_csum_seed \
		-E lazy_itable_init=0,lazy_journal_init=0,nodiscard "${dev}"; then
		mkdir -p /cros-state
		if mount -t ext4 "${dev}" /cros-state; then
			mkdir -p /cros-state/unencrypted
			chmod 755 /cros-state/unencrypted
			umount /cros-state
			e2fsck -f -y "${dev}" >/dev/null 2>&1
			einfo "STATE reset done."
		else
			eerror "STATE reset: mount after mkfs failed."
		fi
	else
		eerror "STATE reset: mkfs.ext4 failed."
	fi
	sync
	ps4_change_led white
}

# HDMI audio: the GPU's HDA codec (ATI R6xx HDMI) has the HDMI pin (0x03, pcm 3) and an
# S/PDIF pin (0x07, pcm 7). The PS4 Slim has no optical port, but that pin still reports
# "plugged", and ChromeOS picks it -> silence. On the Slim and the Fat (not the Pro: untested;
# the Fat loses its optical out) mark that pin "not connected"
# before ChromeOS starts, through the HDA driver's runtime pin overrides.
cros_ps4_audio() {
	# Runs from pre_switch_root, after the initramfs moved /sys to /newroot/sys.
	local sys=/sys hw gpu
	[ -d /newroot/sys/class ] && sys=/newroot/sys
	hw=${sys}/class/sound/hwC0D0
	[ -w "${hw}/user_pin_configs" ] && [ -w "${hw}/reconfig" ] || return 0
	[ "$(cat "${hw}/vendor_id" 2>/dev/null)" = "0x1002aa01" ] || return 0
	# Fat (Aeolia/Belize): has an optical port, but CRAS picks S/PDIF (pcm 7) over HDMI
	# (pcm 3) -> no sound / no boot chime. So HDMI-only on the Fat too (its optical output is off).
	# Pro (Baikal + Neo GPU): untested, left alone.
	local model sb
	sb="$(cat "${sys}/bus/pci/devices/0000:00:14.4/device" 2>/dev/null)"
	gpu="$(cat "${sys}/bus/pci/devices/0000:00:01.0/device" 2>/dev/null)"
	case "${sb}" in
		0x90a1|0x90cc) model="Fat" ;;
		0x90db) [ "${gpu}" = "0x9923" ] || return 0; model="Slim" ;;
		*) return 0 ;;
	esac
	echo "0x07 0x411111f0" > "${hw}/user_pin_configs" \
		&& echo 1 > "${hw}/reconfig" \
		&& einfo "PS4 ${model}: S/PDIF pin disabled, HDMI is the only audio output." \
		|| ewarn "Could not disable the S/PDIF pin (audio may need choosing in ChromeOS)."
}
