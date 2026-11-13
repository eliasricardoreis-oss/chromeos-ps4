#!/bin/sh
# DEBUG BUILD ONLY. Not part of release initramfs images.
# Boot log on the internal drive, post-switch_root screen logger (keeps the debug
# SSH port open through the ChromeOS firewall), ChromeOS shell test mode, and
# Upstart --debug. Sourced after 45-chromeos.sh, so these override its stubs.

# Boot log for debugging without a display: the whole kernel log (einfo/eerror
# go there too) is written to the internal drive, next to chromeos.img.xz.
CROS_LOG=${CROS_BOOT}/chromeos-boot.log
cros_dump_log() {
	mountpoint -q /ps4hdd || return 0
	{ echo "=== $1 ($(date)) ==="; dmesg; } > "${CROS_LOG}" 2>&1
	sync
}

# Post-switch_root logger. switch_root only deletes files on the initramfs itself,
# so a busybox copy on its own tmpfs and a private /proc survive it. Screen only:
# no disk writes after switch_root.
cros_start_logger() {
	mkdir -p /.lg /.lgproc
	mount -t tmpfs -o size=8m dbg /.lg || return 0
	cp /bin/busybox /.lg/busybox || return 0
	mknod /.lg/kmsg c 1 11 || return 0
	mount -t proc dbgproc /.lgproc || return 0
	# Kernel messages back on screen for the ChromeOS part (initramfs set printk to 0).
	echo 7 > /.lgproc/sys/kernel/printk
	/.lg/busybox setsid /.lg/busybox sh -c '
		B=/.lg/busybox P=/.lgproc K=/.lg/kmsg
		i=0
		while [ $i -lt 100000 ]; do
			u=$($B cut -d" " -f1 $P/uptime)
			n=0; for p in $P/[0-9]*; do n=$((n + 1)); done
			echo "<4>ps4-logger tick $i uptime $u procs $n pid1=$($B tr "\0" " " < $P/1/cmdline | $B cut -c1-50)" > $K
			# Keep the debug SSH (port 22) reachable once the ChromeOS firewall is
			# up, using the ChromeOS iptables; only adds the rule if missing.
			if [ -x $P/1/root/sbin/iptables ]; then
				$B chroot $P/1/root /sbin/iptables -w -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null \
					|| $B chroot $P/1/root /sbin/iptables -w -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null
			fi
			if [ $((i % 5)) -eq 4 ]; then
				l=""
				for p in $($B ls -d $P/[0-9]* | $B sed "s|.*/||" | $B sort -n | $B tail -n 10); do
					l="$l $($B cat $P/$p/comm 2>/dev/null)($($B cut -d" " -f3 $P/$p/stat 2>/dev/null))"
				done
				echo "<4>ps4-logger procs:$l" > $K
			fi
			# Shutdown witness: as soon as Upstart starts the halt or reboot job (network
			# already going down, screen black), write to the PS4 drive every second:
			# jobs not yet stopped, processes in D state and what they wait on, kernel log.
			R=$P/1/root
			if $B chroot $R /sbin/initctl status halt 2>/dev/null | $B grep -q "start/" \
				|| $B chroot $R /sbin/initctl status reboot 2>/dev/null | $B grep -q "start/"; then
				echo "<4>ps4-logger: shutdown started, logging to the PS4 drive" > $K
				j=0
				while [ $j -lt 1800 ]; do
					{ echo "=== shutdown log, uptime $($B cut -d" " -f1 $P/uptime), pass $j"
					  echo "--- jobs not stop/waiting:"
					  $B chroot $R /sbin/initctl list 2>&1 | $B grep -v "stop/waiting"
					  echo "--- processes in D state / shutdown tools:"
					  for p in $P/[0-9]*; do
						st=$($B cut -d" " -f3 $p/stat 2>/dev/null); c=$($B cat $p/comm 2>/dev/null)
						case "$st:$c" in D:*|*:chromeos_shutdo|*:umount|*:halt|*:sync|*:process_killer|*:dmsetup|*:session_manager|*:chrome)
							echo "${p##*/} $c state=$st wchan=$($B cat $p/wchan 2>/dev/null) cmd=$($B tr "\0" " " < $p/cmdline 2>/dev/null | $B cut -c1-80)";;
						esac
					  done
					  echo "--- dmesg:"
					  $B dmesg | $B tail -n 120; } > '"${CROS_BOOT}"'/chromeos-shutdown.log.part 2>&1
					$B mv -f '"${CROS_BOOT}"'/chromeos-shutdown.log.part '"${CROS_BOOT}"'/chromeos-shutdown.log
					$B sync
					$B sleep 1
					j=$((j + 1))
				done
			fi
			if [ $i -lt 60 ]; then $B sleep 1; else $B sleep 2; fi
			i=$((i + 1))
		done
	' </dev/null >/dev/null 2>&1 &
	einfo "Debug logger running (screen, keeps SSH open through the ChromeOS firewall)."
}

# Shell test: if /data/linux/boot/chromeos-shell exists, start ChromeOS's own
# /bin/bash as PID 1 instead of /sbin/init. ROOT-A is not touched: helpers live
# on a tmpfs mounted over the empty /tmp of ROOT-A.
CROS_SHELL_FLAG=${CROS_BOOT}/chromeos-shell
cros_shell_mode() {
	[ -f "${CROS_SHELL_FLAG}" ] || return 1
	mount -t tmpfs -o size=16m,mode=1777 ps4tmp /newroot/tmp || return 1
	mkdir -p /newroot/tmp/ps4
	cat > /newroot/tmp/ps4/steps.sh <<'STEPS'
#!/bin/bash
# ChromeOS's first boot jobs, one at a time, in the order upstart runs them.
step() { echo; echo "=== STEP $1: $2"; sync; sleep 1; }
step 0 "basic mounts"
mountpoint -q /run || mount -n -t tmpfs -o mode=0755,nodev,nosuid,noexec run /run; echo "run rc=$?"
mountpoint -q /dev/pts || { mkdir -p /dev/pts; mount -n -t devpts -o noexec,nosuid devpts /dev/pts; }; echo "pts rc=$?"
step 1 "pstore.conf"; mount -n -t pstore -o nodev,nosuid,noexec pstore /sys/fs/pstore; echo "rc=$?"
step 2 "sysrq-init.conf"; /sbin/cros_sysrq_init; echo "rc=$? sysrq=$(cat /proc/sys/kernel/sysrq)"
step 3 "pre-startup.conf"; systemd-tmpfiles --create --remove --boot --prefix /dev --prefix /proc --prefix /run 2>/run/tmpfiles.log; echo "rc=$?"
step 4 "startup.conf"; chromeos_startup --verbosity=1 --encrypted_stateful; echo "rc=$?"
echo; echo "=== All steps done. 'exec /sbin/init' hands over to upstart."
STEPS
	chmod 755 /newroot/tmp/ps4/steps.sh
	echo 1 > /newroot/proc/sys/kernel/sysrq
	echo 4 > /newroot/proc/sys/kernel/printk
	init=/bin/bash
	einfo "ChromeOS SHELL TEST: PID 1 is ChromeOS's /bin/bash. Run /tmp/ps4/steps.sh or exec /sbin/init."
	return 0
}

# Start ChromeOS's init (Upstart) with --debug: every event and job goes to the
# kernel log (and netconsole).
cros_debug_init() {
	boot_newroot() {
		einfo "Switching root to /newroot and executing /sbin/init --debug (debug build)."
		exec env -i \
			TERM="${TERM:-linux}" \
			PATH="${PATH:-/bin:/sbin:/usr/bin:/usr/sbin}" \
			switch_root /newroot /sbin/init --debug
	}
}
