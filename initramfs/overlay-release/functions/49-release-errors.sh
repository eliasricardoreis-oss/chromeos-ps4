#!/bin/sh

# Release build: no rescue shell. Nobody has a keyboard there, and a shell hides why the
# boot failed. Instead: show the error, save it to the PS4 drive (readable over FTP),
# close the PS4 drive cleanly and restart into OrbisOS.
# (The debug build keeps the rescue shell: this file is only in overlay-release.)
CROS_ERROR_FILE=${CROS_BOOT}/chromeos-error.txt
CROS_ERROR_WAIT=60

cros_error_log() {
	echo "ChromeOS for PS4 - boot error"
	echo "date: $(date)  kernel: $(uname -r)  southbridge: $(ps4_southbridge 2>/dev/null)"
	echo
	echo "--- initramfs messages"
	dmesg | grep '\[initramfs-ps4\]' | tail -n 100
	echo
	echo "--- kernel log (last 150 lines)"
	dmesg | tail -n 150
	echo
	echo "--- init.log"
	cat /init.log 2>/dev/null
	echo
	echo "--- mounts"
	cat /proc/mounts
}

cros_release_ps4hdd_close() {
	# Everything stacked on the PS4 drive goes first (verity/STATE dm devices, then the
	# loop device of chromeos.img), so the umount can commit UFS (see 45-chromeos.sh).
	local m l
	for m in /newroot/mnt/stateful_partition /newroot /cros-state; do
		mountpoint -q "${m}" 2>/dev/null && umount "${m}" 2>/dev/null
	done
	for l in $(losetup -a 2>/dev/null | grep '/ps4hdd/' | cut -d: -f1); do
		dmsetup ls 2>/dev/null | cut -f1 | grep -v '^ps4hdd$' | while read -r m; do dmsetup remove "${m}" 2>/dev/null; done
		losetup -d "${l}" 2>/dev/null
	done
	sync
}

rescueshell() {
	local saved="" tty i
	initramfs_quiet=false
	tty="$(cros_tty)"
	# Not orange (that means "installing, do not turn off"): red, else purple.
	ps4_change_led red 2>/dev/null || ps4_change_led purple 2>/dev/null
	eerror "ChromeOS for PS4 could not start (the reason is above)."
	if mountpoint -q /ps4hdd 2>/dev/null; then
		cros_release_ps4hdd_close
		# A plain file in an existing directory (never mkdir on the PS4 drive).
		if [ -d "${CROS_BOOT}" ] && cros_error_log > "${CROS_ERROR_FILE}" 2>/dev/null; then
			sync
			saved=1
		fi
		umount /ps4hdd 2>/dev/null || { sync; ewarn "The PS4 drive could not be unmounted (it was synced)."; }
	fi
	if [ -n "${saved}" ]; then
		cros_say "The details were saved to /data/linux/boot/chromeos-error.txt (read it over FTP)."
	else
		ewarn "The details could not be saved (the PS4 drive is not open)."
	fi
	cros_say "Take a photo of this screen if you want to report it."
	i=${CROS_ERROR_WAIT}
	while [ "${i}" -gt 0 ]; do
		printf '\r  The PS4 restarts into OrbisOS in %2d s ...' "${i}" > "${tty}"
		sleep 1
		i=$((i - 1))
	done
	echo > "${tty}"
	sync
	reboot -f
	# Restart not possible: stop here instead of looping.
	while :; do sleep 3600; done
}
