#!/bin/sh

# Debug SSH: dropbear in its own chroot on a tmpfs (/.dbg), started at the very
# beginning of the initramfs. Key-only login (the build PC's ~/.ssh/ps4_debug),
# no passwords. Everything it needs lives on /.dbg, so it keeps running after
# switch_root. From an SSH session:
#   chroot /proc/1/root /bin/bash   -> the live system (initramfs, later ChromeOS)
#   dmesg                           -> kernel log
DBG=/.dbg

debug_ssh_setup() {
	mkdir -p "${DBG}"
	mountpoint -q "${DBG}" || mount -t tmpfs -o size=32m,mode=755 dbg "${DBG}" || return 1
	mkdir -p "${DBG}/bin" "${DBG}/dev/pts" "${DBG}/proc" "${DBG}/sys" "${DBG}/etc/dropbear" \
		"${DBG}/root/.ssh" "${DBG}/tmp" "${DBG}/var/run" "${DBG}/run"
	chmod 1777 "${DBG}/tmp"
	cp /bin/busybox /bin/dropbear "${DBG}/bin/" || return 1
	for a in $(/bin/busybox --list); do
		[ -e "${DBG}/bin/${a}" ] || ln -s busybox "${DBG}/bin/${a}"
	done
	# Private /dev: a few nodes plus its own devpts instance (the real /dev moves away).
	mknod -m 666 "${DBG}/dev/null" c 1 3
	mknod -m 666 "${DBG}/dev/zero" c 1 5
	mknod -m 666 "${DBG}/dev/random" c 1 8
	mknod -m 666 "${DBG}/dev/urandom" c 1 9
	mknod -m 666 "${DBG}/dev/tty" c 5 0
	mknod -m 600 "${DBG}/dev/console" c 5 1
	mknod -m 644 "${DBG}/dev/kmsg" c 1 11
	mount -t devpts -o newinstance,ptmxmode=0666,mode=620 devpts "${DBG}/dev/pts"
	ln -s pts/ptmx "${DBG}/dev/ptmx"
	mount -t proc proc "${DBG}/proc"
	mount -t sysfs sysfs "${DBG}/sys"
	echo 'root:x:0:0:root:/root:/bin/sh' > "${DBG}/etc/passwd"
	echo 'root:x:0:' > "${DBG}/etc/group"
	echo '/bin/sh' > "${DBG}/etc/shells"
	cat > "${DBG}/etc/profile" <<-'EOF'
		export PATH=/bin
		export PS1='ps4-debug:\w# '
		echo "PS4 debug shell (dropbear chroot on /.dbg)."
		echo "  chroot /proc/1/root /bin/sh    -> live system (initramfs; after switch_root: ChromeOS, use /bin/bash)"
		echo "  dmesg | tail                   -> kernel log"
	EOF
	cp /etc/ps4-debug/authorized_keys "${DBG}/root/.ssh/authorized_keys"
	cp /etc/ps4-debug/host_key "${DBG}/etc/dropbear/host_key"
	chmod 700 "${DBG}/root" "${DBG}/root/.ssh"
	chmod 600 "${DBG}/root/.ssh/authorized_keys" "${DBG}/etc/dropbear/host_key"
}

debug_ssh_start() {
	debug_ssh_setup || { ewarn "Debug SSH: setup failed."; return 0; }
	# Network + dropbear in the background so a slow DHCP never delays the boot.
	setsid sh -c '
		ip link set lo up
		i=0
		while [ ! -e /sys/class/net/eth0 ] && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
		ip link set eth0 up
		udhcpc -i eth0 -s /bin/udhcpc.script -n -q -t 10 -T 3 >/dev/null 2>&1
		# The PS4 RTC is unusable (clock reads 1970): set the time over NTP so
		# ChromeOS starts with a valid clock (TLS certificates, sign-in).
		ntpd -n -q -p pool.ntp.org -p 216.239.35.0 -p 216.239.35.4 >/dev/null 2>&1
		echo "<4>[ps4-debug] clock: $(date -u "+%Y-%m-%d %H:%M:%S UTC")" > /dev/kmsg
		chroot '"${DBG}"' /bin/dropbear -s -g -j -k -p 22 \
			-r /etc/dropbear/host_key -P /var/run/dropbear.pid
		a="$(ip -4 -o addr show eth0 | awk "{print \$4}")"
		echo "<4>[ps4-debug] SSH ready on eth0 ${a:-NO-ADDRESS} (key ~/.ssh/ps4_debug, user root)" > /dev/kmsg
	' </dev/null >/dev/null 2>&1 &
	einfo "Debug SSH starting in the background (eth0, DHCP, key-only)."
}
