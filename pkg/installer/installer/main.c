// ChromeOS for PS4 - installer (OpenOrbis homebrew, needs GoldHEN).
//
// Copies the files that boot ChromeOS on the PS4 to where the Linux loader and the
// initramfs expect them, and records where ChromeOS should live:
//
//   /data/linux/boot/bzImage, initramfs.cpio.gz   kernel + initramfs (loader reads these)
//   /data/linux/boot/chromeos.img.xz + .size      the ChromeOS image, installed on first boot
//   /data/linux/boot/ps4-layer.sqfs               read-only PS4 layer (patched Mesa, overrides)
//   /data/linux/boot/chromeos-target              target=internal | target=external token=<hex>
//   /data/linux/boot/ps4-chromeos-loader.bin      the Linux loader payload
//   /data/payloads/ps4-chromeos-loader.bin        copy for GoldHEN's payload menu
//   /mnt/usb0/CHROMEOS-PS4-TARGET.txt             external only: marks the drive to erase
//
// Nothing is erased here. The initramfs does the actual install on the first boot:
// internal = unpack to /user/app/chromeos.img, external = write the image to the marked
// USB drive (only that drive, only if its marker token matches).
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <orbis/CommonDialog.h>
#include <orbis/MsgDialog.h>
#include <orbis/Sysmodule.h>
#include <orbis/SystemService.h>
#include <orbis/libkernel.h>
#include <orbis/Net.h>

// The package's files. Inside the app sandbox they are at /app0; after the GoldHEN
// jailbreak the process sees the real root, where /app0 does not exist and the same
// files are at the sandbox mount's real path. The first location that has them wins.
static const char *src_candidates[] = {
	"/app0/assets/chromeos",
	"/mnt/sandbox/pfsmnt/CROS00001-app0/assets/chromeos",
	"/mnt/sandbox/CROS00001_000/app0/assets/chromeos",
};
static char SRC[128];
#define DST "/data/linux/boot"
// Everything lives in /data/linux/boot (the loader's own folder), the payload included;
// one copy of the payload also goes to /data/payloads so GoldHEN's menu lists it.
static const char *payload_dirs[] = { DST, "/data/payloads" };
#define PAYLOAD_NAME "ps4-chromeos-loader.bin"
#define USB "/mnt/usb0"
#define USB_MARKER USB "/CHROMEOS-PS4-TARGET.txt"
#define INTERNAL_IMG "/user/app/chromeos.img"
#define GB (1024ULL * 1024ULL * 1024ULL)

static const char *boot_files[] = {
	"bzImage", "initramfs.cpio.gz", "ps4-layer.sqfs", "chromeos.img.size", "chromeos.img.xz",
};
#define N_BOOT_FILES (sizeof(boot_files) / sizeof(boot_files[0]))

// ---------------------------------------------------------------- raw syscalls
static long orbis_syscall3(long num, long a1, long a2, long a3) {
	long ret;
	unsigned char err;
	__asm__ volatile("syscall\n\tsetc %1"
	                 : "=a"(ret), "=r"(err)
	                 : "a"(num), "D"(a1), "S"(a2), "d"(a3)
	                 : "rcx", "r11", "memory");
	return err ? -ret : ret;   // FreeBSD: carry set, rax = errno
}

// Everything the installer does goes to the GoldHEN klog (port 3232), with numbers
// and error codes, so a failure on someone's PS4 can be diagnosed.
static void klog(const char *fmt, ...) {
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
	va_end(ap);
	if (n < 0) return;
	if (n > (int)sizeof(buf) - 3) n = (int)sizeof(buf) - 3;
	buf[n] = '\n'; buf[n + 1] = 0;
	sceKernelDebugOutText(0, "[chromeos-installer] ");
	sceKernelDebugOutText(0, buf);
}


// ---------------------------------------------------------------- dialogs
static void dialog_param_init(OrbisMsgDialogParam *p) {
	memset(p, 0, sizeof(*p));
	p->baseParam.size = sizeof(OrbisCommonDialogBaseParam);
	p->baseParam.magic = (uint32_t)(ORBIS_COMMON_DIALOG_MAGIC_NUMBER + (uint64_t)&p->baseParam);
	p->size = sizeof(*p);
}

// Shows a message; returns 1 for OK/YES/first button, 2 for NO/second button, 0 for cancel.
static int dialog(OrbisMsgDialogButtonType type, const char *b1, const char *b2, const char *fmt, ...) {
	static char msg[2048];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);

	OrbisMsgDialogParam p;
	OrbisMsgDialogUserMessageParam um;
	OrbisMsgDialogButtonsParam bp;
	OrbisMsgDialogResult r;
	dialog_param_init(&p);
	memset(&um, 0, sizeof(um));
	memset(&bp, 0, sizeof(bp));
	p.mode = ORBIS_MSG_DIALOG_MODE_USER_MSG;
	um.buttonType = type;
	um.msg = msg;
	if (type == ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS) {
		bp.msg1 = b1;
		bp.msg2 = b2;
		um.buttonsParam = &bp;
	}
	p.userMsgParam = &um;
	sceMsgDialogInitialize();
	if (sceMsgDialogOpen(&p) < 0) {
		sceMsgDialogTerminate();
		return 0;
	}
	while (sceMsgDialogUpdateStatus() != ORBIS_COMMON_DIALOG_STATUS_FINISHED)
		sceKernelUsleep(10000);
	memset(&r, 0, sizeof(r));
	sceMsgDialogGetResult(&r);
	sceMsgDialogTerminate();
	klog("dialog type %d result=%d buttonId=%d", (int)type, (int)r.result, (int)r.buttonId);
	if (r.buttonId == ORBIS_MSG_DIALOG_BUTTON_ID_BUTTON1) return 1;
	if (r.buttonId == ORBIS_MSG_DIALOG_BUTTON_ID_BUTTON2) return 2;
	return 0;
}

static void quit(void) {
	sceSystemServiceLoadExec("exit", NULL);
	for (;;) sceKernelUsleep(1000000);
}

static void fail(const char *fmt, const char *arg) {
	dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL, fmt, arg);
	quit();
}

static int progress_open(const char *msg) {
	OrbisMsgDialogParam p;
	OrbisMsgDialogProgressBarParam pb;
	dialog_param_init(&p);
	memset(&pb, 0, sizeof(pb));
	p.mode = ORBIS_MSG_DIALOG_MODE_PROGRESS_BAR;
	pb.barType = ORBIS_MSG_DIALOG_PROGRESSBAR_TYPE_PERCENTAGE;
	pb.msg = msg;
	p.progBarParam = &pb;
	sceMsgDialogInitialize();
	return sceMsgDialogOpen(&p);
}

static void progress_set(uint32_t pct, const char *msg) {
	sceMsgDialogProgressBarSetValue(0, pct);
	if (msg) sceMsgDialogProgressBarSetMsg(0, msg);
	sceMsgDialogUpdateStatus();
}

static void progress_close(void) {
	sceMsgDialogClose();
	while (sceMsgDialogUpdateStatus() != ORBIS_COMMON_DIALOG_STATUS_FINISHED)
		sceKernelUsleep(10000);
	sceMsgDialogTerminate();
}

// ---------------------------------------------------------------- files
static uint64_t fd_size(int fd) {
	off_t cur = lseek(fd, 0, SEEK_CUR);
	off_t end = lseek(fd, 0, SEEK_END);
	if (cur >= 0) lseek(fd, cur, SEEK_SET);
	return end > 0 ? (uint64_t)end : 0;
}

static uint64_t file_size(const char *path) {
	int fd = open(path, O_RDONLY);
	if (fd < 0) return 0;
	uint64_t n = fd_size(fd);
	close(fd);
	return n;
}

static int exists(const char *path) {
	struct stat st;
	return stat(path, &st) == 0;
}

// FreeBSD statfs(2), syscall 396, called directly: the libc statvfs wrapper does not
// translate the PS4 kernel's struct layout. Offsets from FreeBSD 9 struct statfs:
// f_bsize @16, f_blocks @32, f_bavail @48 (all 64-bit).
// In the app sandbox statfs() returns EPERM (seen for /user and /data), so fstatfs() on
// an open directory (397) and getfsstat() (395, the mount list) are tried next.
#define STATFS_SIZE 472   // FreeBSD 9 struct statfs; f_mntonname @384 (MNAMELEN 88)

static int fs_parse(const char *how, const unsigned char *b, uint64_t *free_b, uint64_t *total_b) {
	uint64_t bsize, blocks; int64_t bavail;
	memcpy(&bsize, b + 16, 8); memcpy(&blocks, b + 32, 8); memcpy(&bavail, b + 48, 8);
	if (bavail < 0) bavail = 0;
	if (bsize == 0 || blocks == 0) { klog("%s: empty result", how); return -1; }
	*free_b = (uint64_t)bavail * bsize;
	*total_b = blocks * bsize;
	klog("%s: bsize=%llu blocks=%llu bavail=%lld -> free %llu MB, total %llu MB", how,
	     (unsigned long long)bsize, (unsigned long long)blocks, (long long)bavail,
	     (unsigned long long)(*free_b >> 20), (unsigned long long)(*total_b >> 20));
	return 0;
}

static int fs_info(const char *path, uint64_t *free_b, uint64_t *total_b) {
	static uint64_t sf[64];
	static unsigned char all[64 * STATFS_SIZE];
	char how[160];
	memset(sf, 0, sizeof(sf));
	long r = orbis_syscall3(396, (long)path, (long)sf, 0);
	snprintf(how, sizeof(how), "statfs(%s)", path);
	if (r >= 0 && fs_parse(how, (unsigned char *)sf, free_b, total_b) == 0) return 0;
	if (r < 0) klog("statfs(%s) failed: errno %ld", path, -r);

	int fd = open(path, O_RDONLY);
	if (fd >= 0) {
		memset(sf, 0, sizeof(sf));
		r = orbis_syscall3(397, (long)fd, (long)sf, 0);
		close(fd);
		snprintf(how, sizeof(how), "fstatfs(%s)", path);
		if (r >= 0 && fs_parse(how, (unsigned char *)sf, free_b, total_b) == 0) return 0;
		if (r < 0) klog("fstatfs(%s) failed: errno %ld", path, -r);
	} else klog("open(%s) for fstatfs failed: errno %d", path, errno);

	// Mount list: the PS4 user partition is mounted at /user; /data lives on it.
	memset(all, 0, sizeof(all));
	r = orbis_syscall3(395, (long)all, (long)sizeof(all), 2 /* MNT_NOWAIT */);
	if (r < 0) { klog("getfsstat failed: errno %ld", -r); return -1; }
	int pick = -1;
	for (long i = 0; i < r && i < 64; i++) {
		const char *on = (const char *)all + i * STATFS_SIZE + 384;
		const char *type = (const char *)all + i * STATFS_SIZE + 280;
		klog("mount %ld: %.88s (%.16s)", i, on, type);
		if (pick < 0 && (strcmp(on, "/user") == 0 || strcmp(on, "/data") == 0)) pick = (int)i;
	}
	if (pick < 0) { klog("getfsstat: no /user or /data mount"); return -1; }
	snprintf(how, sizeof(how), "getfsstat(%.88s)", (const char *)all + pick * STATFS_SIZE + 384);
	return fs_parse(how, all + pick * STATFS_SIZE, free_b, total_b);
}

static uint64_t free_bytes(const char *path) {
	uint64_t f = 0, t = 0;
	return fs_info(path, &f, &t) == 0 ? f : 0;
}


static void mkdirs(const char *path) {
	char tmp[256];
	snprintf(tmp, sizeof(tmp), "%s", path);
	for (char *p = tmp + 1; *p; p++) {
		if (*p == '/') {
			*p = 0;
			mkdir(tmp, 0777);
			*p = '/';
		}
	}
	mkdir(tmp, 0777);
}


// Copies src to dst (via dst.part, then rename), updating the progress bar.
// Copies the already-open source fd to dst (via dst.part, then rename), with progress.
static int copy_file(int in, const char *dst, uint64_t *done, uint64_t total, const char *label) {
	static unsigned char buf[4 * 1024 * 1024];
	char part[256], msg[256];
	snprintf(part, sizeof(part), "%s.part", dst);
	snprintf(msg, sizeof(msg), "Copying %s ...", label);
	progress_set(total ? (uint32_t)(*done * 100 / total) : 0, msg);
	if (in < 0 || lseek(in, 0, SEEK_SET) != 0) { klog("copy %s: source seek failed errno %d", label, errno); return -1; }
	// World-writable: the files can be updated later over FTP without deleting them first.
	int out = open(part, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (out < 0) { klog("copy %s: open %s failed errno %d", label, part, errno); return -1; }
	klog("copy %s -> %s (%llu bytes)", label, dst, (unsigned long long)fd_size(in));
	ssize_t n;
	int rc = 0;
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		ssize_t off = 0;
		while (off < n) {
			ssize_t w = write(out, buf + off, (size_t)(n - off));
			if (w <= 0) { klog("copy %s: write failed errno %d after %llu", label, errno, (unsigned long long)*done); rc = -1; break; }
			off += w;
		}
		if (rc) break;
		*done += (uint64_t)n;
		progress_set(total ? (uint32_t)(*done * 100 / total) : 0, NULL);
	}
	if (n < 0) { klog("copy %s: read failed errno %d", label, errno); rc = -1; }
	if (fsync(out) != 0) klog("copy %s: fsync errno %d (ignored)", label, errno);
	if (close(out) != 0) { klog("copy %s: close errno %d", label, errno); rc = -1; }
	if (rc == 0) {
		uint64_t a = file_size(part), b = fd_size(in);
		if (a != b) { klog("copy %s: size mismatch %llu != %llu", label, (unsigned long long)a, (unsigned long long)b); rc = -1; }
	}
	if (rc == 0) {
		unlink(dst);
		if (rename(part, dst) != 0) { klog("copy %s: rename failed errno %d", label, errno); rc = -1; }
		else chmod(dst, 0666);
	}
	if (rc != 0) unlink(part);
	return rc;
}

// ---------------------------------------------------------------- build stamp
// make-pkg.sh puts build-id (hash of all package files) next to the assets. It is copied
// to DST last, after every other file, so a matching stamp means the last copy completed.
#define BUILD_ID "build-id"

static int read_small(const char *path, char *buf, size_t cap) {
	int fd = open(path, O_RDONLY);
	if (fd < 0) return -1;
	ssize_t n = read(fd, buf, cap - 1);
	close(fd);
	if (n <= 0) return -1;
	buf[n] = 0;
	return 0;
}

// 1 if DST already holds exactly this package's files (stamp matches, sizes match).
static int already_installed(const int *src_fd, int payload_fd) {
	char a[128], b[128], path[256];
	snprintf(path, sizeof(path), "%s/%s", SRC, BUILD_ID);
	if (read_small(path, a, sizeof(a)) != 0) { klog("no build-id in package: copying"); return 0; }
	if (read_small(DST "/" BUILD_ID, b, sizeof(b)) != 0) { klog("no build-id on console: copying"); return 0; }
	if (strcmp(a, b) != 0) { klog("build-id differs: copying"); return 0; }
	for (size_t i = 0; i < N_BOOT_FILES; i++) {
		snprintf(path, sizeof(path), DST "/%s", boot_files[i]);
		if (file_size(path) != fd_size(src_fd[i])) { klog("%s missing or wrong size: copying", boot_files[i]); return 0; }
	}
	for (size_t i = 0; i < 2; i++) {
		snprintf(path, sizeof(path), "%s/%s", payload_dirs[i], PAYLOAD_NAME);
		if (file_size(path) != fd_size(payload_fd)) { klog("%s missing or wrong size: copying", path); return 0; }
	}
	klog("files already installed (build-id match): skipping copy");
	return 1;
}

// ---------------------------------------------------------------- space reservation
// Linux's UFS driver writes ~13 MB/s and must not allocate after boot (see the
// initramfs, 45-chromeos.sh), so the first install used to zero-fill 32 GB in Linux
// (~40 min). OrbisOS writes the PS4 drive natively and much faster (~150 MB/s): reserve
// the image for the size picked in the app's menu, once. The initramfs unpacks the seed
// into it in place.
// Written as .alloc.part (resumed if interrupted), renamed to .alloc when complete.
#define ALLOC_NAME "chromeos.img.alloc"
// In /data (same partition as /user/app; the app sandbox cannot reach /user/app):
// the initramfs moves it to /user/app/chromeos.img by rename, no data copied.
#define ALLOC_FILE DST "/" ALLOC_NAME
#define RESERVE_FREE (10ULL * GB)   // same reserve the initramfs keeps

// GoldHEN SDK: syscall 500, cmd 2 = jailbreak (leave the sandbox). The sandbox refuses
// statfs/fstatfs/getfsstat (EPERM), and reserving without knowing the free space could
// fill the PS4 drive. Used only here, right before the reserve.
#define GOLDHEN_SDK_CMD_JAILBREAK 2
#define GOLDHEN_SDK_CMD_UNJAILBREAK 3
struct jailbreak_backup {
	uint32_t cr_uid, cr_ruid, cr_rgid, cr_groups;
	uint64_t cr_paid;
	uint64_t cr_caps[2];
	void *cr_prison, *fd_cdir, *fd_jdir, *fd_rdir;
	uint8_t spare[128];   // headroom in case a GoldHEN version stores more
};

static struct jailbreak_backup jb;
static int jailbroken;

static int goldhen_jailbreak(void) {
	int done = jailbroken;
	if (done) return 0;
	memset(&jb, 0, sizeof(jb));
	long r = orbis_syscall3(500, GOLDHEN_SDK_CMD_JAILBREAK, (long)&jb, 0);
	klog("GoldHEN jailbreak: %ld", r);
	if (r != 0) return -1;
	jailbroken = 1;
	return 0;
}

// Back into the sandbox before the payload: a boot right after a jailbroken reserve run
// had no HDMI and no LED change (seen on a Slim); the same files booted fine from a
// normal launch. Also let the 35 GB write settle before the loader shuts OrbisOS down.
static void goldhen_unjailbreak(void) {
	if (!jailbroken) return;
	long r = orbis_syscall3(500, GOLDHEN_SDK_CMD_UNJAILBREAK, (long)&jb, 0);
	klog("GoldHEN unjailbreak: %ld", r);
	if (r == 0) jailbroken = 0;
	sync();
	sceKernelUsleep(5 * 1000000);
	klog("settled: sync + 5 s");
}

// The install choice (where + how big) is made here, so the reserve matches it, and saved
// for the initramfs, which then skips those questions on the TV:
//   /data/linux/boot/chromeos-install-choice:  target=internal state_gib=<n> | target=external
// Removed by the initramfs after the install (chromeos-target is written instead).
#define CHOICE_FILE DST "/chromeos-install-choice"
#define STATE_START_NAME "chromeos.img.state-start"
// For the time estimate in the size menu. Measured ~150 MB/s on the Slim, but a stock
// 5400 RPM PS4 drive (or a fuller one) is slower: estimate cautiously, show the real
// remaining time while reserving.
#define RESERVE_MBPS 50   // Fat CUH-1115A stock drive: 59 MB/s measured

// Image size for a STATE of gib GiB: STATE start + STATE + backup GPT (34 sectors),
// rounded up to whole MiB - the same formula as cros_install_internal.
static uint64_t img_bytes(uint64_t start, uint64_t gib) {
	return (start * 512 + gib * GB + 34 * 512 + 1048575) / 1048576 * 1048576;
}

static int write_choice(const char *text) {
	int fd = open(CHOICE_FILE ".part", O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd < 0) { klog("choice: open failed errno %d", errno); return -1; }
	ssize_t n = write(fd, text, strlen(text));
	fsync(fd);
	close(fd);
	if (n != (ssize_t)strlen(text) || rename(CHOICE_FILE ".part", CHOICE_FILE) != 0) {
		klog("choice: write failed errno %d", errno);
		unlink(CHOICE_FILE ".part");
		return -1;
	}
	chmod(CHOICE_FILE, 0666);
	klog("choice saved: %s", text);
	return 0;
}

static uint64_t choice_gib(const char *c) {
	const char *p = strstr(c, "state_gib=");
	return p ? strtoull(p + 10, NULL, 10) : 0;
}

// Asks where ChromeOS goes and how big its storage is; returns the STATE size in GiB for
// the PS4 drive, 0 for a USB drive. Quits the app on cancel.
static uint64_t ask_install(uint64_t start, uint64_t avail) {
	int r = dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "PS4 drive", "USB drive",
	               "ChromeOS for PS4 - where should ChromeOS be installed?\n\n"
	               "PS4 drive: games and saves stay.\n"
	               "USB drive: that drive is ERASED. You pick it on the TV after the restart "
	               "(needs a USB keyboard).");
	if (r == 0) quit();
	if (r == 2) return 0;

	uint64_t max_gib = 0;
	while (img_bytes(start, max_gib + 1) <= avail) max_gib++;
	klog("sizes: avail %llu MB -> max %llu GB", (unsigned long long)(avail >> 20), (unsigned long long)max_gib);
	if (max_gib < 8) {
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "Not enough free space on the PS4 drive: ChromeOS needs at least 8 GB "
		       "(32 GB recommended) plus %llu GB that always stay free.\n\n"
		       "Free up space, or install to a USB drive.", (unsigned long long)(RESERVE_FREE / GB));
		quit();
	}
	static const uint64_t steps[] = { 32, 64, 128, 256 };
	uint64_t sizes[8];
	int n = 0;
	for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); i++)
		if (steps[i] <= max_gib) sizes[n++] = steps[i];
	if (n == 0 || sizes[n - 1] != max_gib) sizes[n++] = max_gib;   // "all the space"

	for (int i = 0;; i = (i + 1) % n) {
		uint64_t g = sizes[i], mins = img_bytes(start, g) / 1048576 / RESERVE_MBPS / 60 + 1;
		const char *tag = g == 32 ? "  (recommended)" : (g == max_gib ? "  (all the free space)" : "");
		r = dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Install", n > 1 ? "Next size" : "Install",
		           "Storage for ChromeOS (apps, files, Android, Linux):\n\n"
		           "        %llu GB%s\n\n"
		           "Reserving it takes up to about %llu min (one time; less on a fast drive). "
		           "%llu GB of the PS4 drive always stay free.%s",
		           (unsigned long long)g, tag, (unsigned long long)mins,
		           (unsigned long long)(RESERVE_FREE / GB),
		           n > 1 ? "\n\n\"Next size\" shows the other sizes." : "");
		if (r == 0) quit();
		if (r == 1 || n == 1) return g;
	}
}

// Dry run (flag file /data/linux/boot/chromeos-dryrun, e.g. made over FTP): shows the
// real install questions with the real sizes, then a summary - and writes, reserves and
// boots nothing (except removing the flag: one dry run per flag). Works even when
// ChromeOS is installed.
#define DRYRUN_FLAG DST "/chromeos-dryrun"
static void dry_run(void) {
	char path[256], buf[64];
	klog("DRY RUN: nothing is written, reserved or booted");
	unlink(DRYRUN_FLAG);   // one time only: the next launch is a real run
	snprintf(path, sizeof(path), "%s/%s", SRC, STATE_START_NAME);
	if (read_small(path, buf, sizeof(buf)) != 0) fail("Dry run: %s is missing from the package.", STATE_START_NAME);
	uint64_t start = strtoull(buf, NULL, 10);
	if (goldhen_jailbreak() != 0) fail("Dry run: the GoldHEN jailbreak failed.%s", "");
	uint64_t free_user = free_bytes(DST);
	if (!free_user) fail("Dry run: the free space could not be read.%s", "");
	uint64_t avail = free_user + file_size(ALLOC_FILE) + file_size(ALLOC_FILE ".part");
	avail = avail > RESERVE_FREE ? avail - RESERVE_FREE : 0;
	uint64_t gib = ask_install(start, avail);
	if (gib == 0) {
		klog("DRY RUN result: USB drive");
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "Dry run - nothing was changed.\n\nChosen: USB drive.\n"
		       "A real run would reserve nothing and ask for the drive on the TV.%s", "");
	} else {
		uint64_t want = img_bytes(start, gib);
		klog("DRY RUN result: PS4 drive, %llu GB STATE -> reserve %llu bytes (~%llu min), free %llu MB",
		     (unsigned long long)gib, (unsigned long long)want,
		     (unsigned long long)(want / 1048576 / RESERVE_MBPS / 60 + 1), (unsigned long long)(free_user >> 20));
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "Dry run - nothing was changed.\n\nChosen: PS4 drive, %llu GB storage.\n"
		       "A real run would reserve %llu MB (about %llu min).\n"
		       "PS4 drive free now: %llu MB.",
		       (unsigned long long)gib, (unsigned long long)(want >> 20),
		       (unsigned long long)(want / 1048576 / RESERVE_MBPS / 60 + 1), (unsigned long long)(free_user >> 20));
	}
	quit();
}

// First install, but the fast reserve is not possible: say so and let the user choose.
static void ask_slow_install(const char *why) {
	klog("fast reserve not possible: %s", why);
	int r = dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Continue", "Cancel",
	               "%s\n\nChromeOS can still be installed, but Linux then has to prepare the space "
	               "itself, which takes much longer (about 40 min more for 32 GB). The questions "
	               "are then asked on the TV (USB keyboard).\n\nContinue with the slower install?", why);
	if (r != 1) quit();
}

// Reserve done: wait until OrbisOS has really written it before Linux gets the drive.
// The loader stops OrbisOS abruptly; booting it straight after a big reserve crashed Linux
// (32 GB: no picture; 64 GB: kernel panic + power off) while a later launch was fine.
// The reserve runs faster than the disk (~200 MB/s), so much of it is still in memory when
// write() returns. Measured, not guessed: a tiny file is written + fsync'd every 2 s; while
// the drive is still busy that takes long, when it is idle it takes milliseconds.
#define PROBE_FILE DST "/.cros-probe"
#define PROBE_FAST_US 150000ULL     // fsync under 150 ms = drive idle (5400 RPM: tens of ms idle)
#define PROBE_NEED 3                // ... three times in a row
// The drive was already idle (1-3 ms) after the 64 GB reserve, and 15 s in total fixed the
// crash that 5 s did not: so the time itself matters. 30 s for margin.
#define SETTLE_MIN_S 30
#define SETTLE_MAX_S 600

static uint64_t probe_us(void) {
	static char block[4096];
	uint64_t t0 = sceKernelGetProcessTime();
	int fd = open(PROBE_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd < 0) return ~0ULL;
	block[0]++;
	ssize_t w = write(fd, block, sizeof(block));
	int f = fsync(fd);
	close(fd);
	if (w != (ssize_t)sizeof(block) || f != 0) return ~0ULL;
	return sceKernelGetProcessTime() - t0;
}

static void settle_drive(void) {
	char msg[160];
	sync();
	if (progress_open("Finishing writing to the PS4 drive ...") < 0) { sceKernelUsleep(60 * 1000000); return; }
	uint64_t t0 = sceKernelGetProcessTime();
	int fast = 0, secs = 0;
	for (;;) {
		uint64_t us = probe_us();
		secs = (int)((sceKernelGetProcessTime() - t0) / 1000000);
		klog("settle %3d s: probe fsync %llu ms", secs, (unsigned long long)(us == ~0ULL ? 0 : us / 1000));
		fast = (us != ~0ULL && us < PROBE_FAST_US) ? fast + 1 : 0;
		if (fast >= PROBE_NEED && secs >= SETTLE_MIN_S) break;
		if (secs >= SETTLE_MAX_S) { klog("settle: still busy after %d s, booting anyway", secs); break; }
		snprintf(msg, sizeof(msg), "Finishing writing to the PS4 drive ... %d s", secs);
		progress_set((uint32_t)(secs * 100 / SETTLE_MAX_S), msg);
		sync();
		sceKernelUsleep(2 * 1000000);
	}
	unlink(PROBE_FILE);
	sync();
	progress_close();
	klog("settled after %d s", secs);
}

static void reserved_done(uint64_t gib) {
	klog("reserve of %llu GB complete", (unsigned long long)gib);
	settle_drive();
}

static const char *errno_text(int e) {
	switch (e) {
	case 28: return "The PS4 drive is full.";                       // ENOSPC
	case 5:  return "The PS4 drive reported a read/write error.";   // EIO
	case 13: case 1: return "Access to the PS4 drive was refused.";  // EACCES, EPERM
	default: return "Writing to the PS4 drive failed.";
	}
}

static void install_setup(void) {
	static unsigned char zero[4 * 1024 * 1024];   // bss: all zeros
	char path[256], buf[64], choice[128];
	// The sandbox cannot see /user/app/chromeos.img; the initramfs writes chromeos-target
	// after a successful install (internal or USB).
	if (exists(DST "/chromeos-target") || exists(DST "/chromeos-external.guid")) return;
	// Package files first: after the jailbreak /app0 is no longer the package's root.
	snprintf(path, sizeof(path), "%s/%s", SRC, STATE_START_NAME);
	if (read_small(path, buf, sizeof(buf)) != 0) { klog("no %s in package: TV menu decides", STATE_START_NAME); return; }
	uint64_t start = strtoull(buf, NULL, 10);
	if (start == 0) { klog("bad state start '%s'", buf); return; }

	uint64_t gib = 0;
	if (read_small(CHOICE_FILE, choice, sizeof(choice)) == 0) {
		if (strstr(choice, "target=external")) { klog("choice: USB drive (nothing to reserve)"); return; }
		gib = choice_gib(choice);
		klog("choice from an earlier launch: %llu GB", (unsigned long long)gib);
		if (gib && exists(ALLOC_FILE) && file_size(ALLOC_FILE) == img_bytes(start, gib)) return;  // reserved
	}
	if (goldhen_jailbreak() != 0) {
		ask_slow_install("GoldHEN did not give the app access to the PS4 drive's free space "
		                 "(is GoldHEN 2.4 or newer running?).");
		return;
	}
	uint64_t free_user = free_bytes(DST);
	if (!free_user) {
		goldhen_unjailbreak();
		ask_slow_install("The free space of the PS4 drive could not be read.");
		return;
	}
	// Space already reserved by an earlier launch counts as free (it is reused or removed).
	uint64_t avail = free_user + file_size(ALLOC_FILE) + file_size(ALLOC_FILE ".part");
	avail = avail > RESERVE_FREE ? avail - RESERVE_FREE : 0;

	if (!gib) {
		gib = ask_install(start, avail);
		if (gib == 0) {
			unlink(ALLOC_FILE); unlink(ALLOC_FILE ".part");
			write_choice("target=external\n");
			return;
		}
		snprintf(choice, sizeof(choice), "target=internal\nstate_gib=%llu\n", (unsigned long long)gib);
		if (write_choice(choice) != 0)
			fail("Could not save your choice to /data/linux/boot.%s\n\nCheck that the PS4 drive is not full, then try again.", "");
	}
	uint64_t want = img_bytes(start, gib);
	if (want > avail) {
		klog("%llu GB no longer fits", (unsigned long long)gib);
		unlink(CHOICE_FILE);
		unlink(ALLOC_FILE ".part");
		fail("The size chosen earlier no longer fits on the PS4 drive.%s\n\nLaunch the app again to choose a smaller size.", "");
	}
	if (exists(ALLOC_FILE) && file_size(ALLOC_FILE) != want) { unlink(ALLOC_FILE); klog("old reserve has another size: removed"); }
	if (exists(ALLOC_FILE)) { reserved_done(gib); return; }   // reserved by an earlier launch

	int out = open(ALLOC_FILE ".part", O_WRONLY | O_CREAT, 0666);
	if (out < 0) { klog("open %s.part failed errno %d", ALLOC_FILE, errno); fail("Could not create the space for ChromeOS in /data/linux/boot.%s", ""); }
	uint64_t have = fd_size(out);
	if (have > want) {   // a bigger size was chosen before: start over
		close(out); unlink(ALLOC_FILE ".part");
		out = open(ALLOC_FILE ".part", O_WRONLY | O_CREAT, 0666);
		if (out < 0) { klog("reopen %s.part failed errno %d", ALLOC_FILE, errno); fail("Could not create the space for ChromeOS in /data/linux/boot.%s", ""); }
		have = 0;
	}
	// Resume from a whole number of buffers.
	have -= have % sizeof(zero);
	if (lseek(out, (off_t)have, SEEK_SET) != (off_t)have) {
		klog("alloc seek failed errno %d", errno); close(out); unlink(ALLOC_FILE ".part");
		fail("Could not continue the earlier reservation; it was removed.%s\n\nLaunch the app again.", "");
	}
	klog("reserving %llu MB (%llu GB STATE) at %s (resume at %llu MB, free %llu MB)", (unsigned long long)(want >> 20),
	     (unsigned long long)gib, ALLOC_FILE, (unsigned long long)(have >> 20), (unsigned long long)(free_user >> 20));
	char msg[160];
	snprintf(msg, sizeof(msg), "Reserving %llu GB on the PS4 drive for ChromeOS (one time only) ...",
	         (unsigned long long)gib);
	if (progress_open(msg) < 0) { close(out); fail("Could not open the progress dialog.%s", ""); }
	uint64_t t0 = sceKernelGetProcessTime(), done = have, last_msg = 0;
	int rc = 0, werr = 0;
	while (done < want) {
		size_t n = (want - done) < sizeof(zero) ? (size_t)(want - done) : sizeof(zero);
		ssize_t w = write(out, zero, n);
		if (w <= 0) { werr = errno; klog("alloc write failed errno %d at %llu MB", werr, (unsigned long long)(done >> 20)); rc = -1; break; }
		done += (uint64_t)w;
		uint64_t now = sceKernelGetProcessTime();
		if (now - last_msg >= 2000000ULL) {   // live remaining time from this drive's speed
			last_msg = now;
			uint64_t el = (now - t0) / 1000000, mb = (done - have) >> 20;
			if (el >= 5 && mb) {
				uint64_t left = ((want - done) >> 20) * el / mb;
				snprintf(msg, sizeof(msg), "Reserving %llu GB on the PS4 drive for ChromeOS (one time only) ...\n"
				         "%llu MB/s, about %llu min %02llu s left", (unsigned long long)gib,
				         (unsigned long long)(mb / el), (unsigned long long)(left / 60), (unsigned long long)(left % 60));
				progress_set((uint32_t)(done * 100 / want), msg);
			} else progress_set((uint32_t)(done * 100 / want), NULL);
		}
	}
	if (fsync(out) != 0) klog("alloc fsync errno %d (ignored)", errno);
	close(out);
	progress_close();
	uint64_t secs = (sceKernelGetProcessTime() - t0) / 1000000;
	klog("reserved %llu MB in %llu s (%llu MB/s)", (unsigned long long)((done - have) >> 20),
	     (unsigned long long)secs, (unsigned long long)(secs ? ((done - have) >> 20) / secs : 0));
	if (rc != 0) {
		if (werr == 28) {   // full: give the space back, a smaller size is needed
			unlink(ALLOC_FILE ".part"); unlink(CHOICE_FILE);
			fail("%s\n\nThe reservation was removed. Free up space or launch the app again and choose a smaller size.", errno_text(werr));
		}
		// .part stays: the next launch resumes it, the initramfs ignores it
		fail("%s\n\nWhat was reserved so far is kept: launch the app again to continue.", errno_text(werr));
	}
	if (file_size(ALLOC_FILE ".part") != want || rename(ALLOC_FILE ".part", ALLOC_FILE) != 0) {
		klog("alloc finish failed (size %llu, errno %d)", (unsigned long long)file_size(ALLOC_FILE ".part"), errno);
		fail("The space was written but could not be finished.%s\n\nLaunch the app again.", "");
	}
	reserved_done(gib);
}

// ---------------------------------------------------------------- payload auto-boot
// Hands the Linux loader to GoldHEN's BinLoader (TCP 9090 on the console itself),
// which runs it right away: the PS4 boots into the kernel + initramfs we just copied.
static int send_payload(int fd) {
	static unsigned char buf[512 * 1024];
	uint64_t size = fd_size(fd);
	if (size == 0 || size > sizeof(buf) || lseek(fd, 0, SEEK_SET) != 0) return -1;
	ssize_t n = read(fd, buf, (size_t)size);
	if (n != (ssize_t)size) { klog("payload read %ld of %llu", (long)n, (unsigned long long)size); return -1; }
	sceNetInit();
	int s = sceNetSocket("chromeos-loader", ORBIS_NET_AF_INET, ORBIS_NET_SOCK_STREAM, 0);
	if (s < 0) { klog("sceNetSocket failed 0x%x", s); return -1; }
	struct { uint8_t len; uint8_t family; uint16_t port; uint32_t addr; uint8_t zero[8]; } sa;
	memset(&sa, 0, sizeof(sa));
	sa.len = sizeof(sa);
	sa.family = ORBIS_NET_AF_INET;
	sa.port = sceNetHtons(9090);
	sa.addr = 0x0100007F;  // 127.0.0.1 in network byte order
	int r = sceNetConnect(s, (const OrbisNetSockaddr *)&sa, sizeof(sa));
	if (r < 0) { klog("connect 127.0.0.1:9090 failed 0x%x (GoldHEN BinLoader off?)", r); sceNetSocketClose(s); return -1; }
	size_t off = 0;
	while (off < (size_t)n) {
		int w = sceNetSend(s, buf + off, (size_t)n - off, 0);
		if (w <= 0) { klog("send failed 0x%x at %zu", w, off); sceNetSocketClose(s); return -1; }
		off += (size_t)w;
	}
	sceNetSocketClose(s);
	klog("payload sent (%zu bytes)", off);
	return 0;
}

// ---------------------------------------------------------------- main
// No questions here: the first start of ChromeOS (in the initramfs) asks where to
// install and how big, on the TV. This app only puts the files in place and boots.
int main(void) {
	char path[256], path2[256];

	sceSysmoduleLoadModule(ORBIS_SYSMODULE_MESSAGE_DIALOG);
	sceCommonDialogInitialize();
	klog("start (build " __DATE__ " " __TIME__ ")");

	// The package's files (see src_candidates), opened once and copied via the handles.
	SRC[0] = 0;
	for (size_t i = 0; i < sizeof(src_candidates) / sizeof(src_candidates[0]); i++) {
		snprintf(path, sizeof(path), "%s/bzImage", src_candidates[i]);
		if (exists(path)) { snprintf(SRC, sizeof(SRC), "%s", src_candidates[i]); break; }
	}
	if (!SRC[0]) fail("Cannot find the installer's files.%s\n\nReinstall the package and try again.", "");
	klog("package files at %s", SRC);
	int src_fd[N_BOOT_FILES], payload_fd;
	uint64_t total = 0;
	for (size_t i = 0; i < N_BOOT_FILES; i++) {
		snprintf(path, sizeof(path), "%s/%s", SRC, boot_files[i]);
		src_fd[i] = open(path, O_RDONLY);
		if (src_fd[i] < 0) fail("The installer package is incomplete: %s is missing.", boot_files[i]);
		total += fd_size(src_fd[i]);
	}
	snprintf(path, sizeof(path), "%s/%s", SRC, PAYLOAD_NAME);
	payload_fd = open(path, O_RDONLY);
	if (payload_fd < 0) fail("The installer package is incomplete: %s is missing.", PAYLOAD_NAME);
	total += 2 * fd_size(payload_fd);
	klog("files total %llu bytes", (unsigned long long)total);
	klog("free space on the PS4 drive: %llu MB (0 = unknown)", (unsigned long long)(free_bytes(DST) >> 20));
	if (exists(DRYRUN_FLAG)) dry_run();   // never returns

	// Same package already copied: boot right away.
	if (already_installed(src_fd, payload_fd)) {
		unlink(DST "/chromeos-shell");
		unlink(DST "/chromeos-reset-state");
		install_setup();   // no-op once ChromeOS is installed
		goldhen_unjailbreak();
		if (send_payload(payload_fd) != 0)
			fail("ChromeOS is installed, but the payload could not be started.%s\n\n"
			     "Start it yourself: GoldHEN > Payloads > " PAYLOAD_NAME, "");
		for (;;) sceKernelUsleep(1000000);
	}
	unlink(DST "/" BUILD_ID);   // invalidate the stamp until this copy completes

	uint64_t free_user = free_bytes("/data");   // /user is not visible in the app sandbox
	if (free_user && free_user < total + GB)
		fail("Not enough free space on the PS4 drive for the ChromeOS files.%s", "");

	// Copy everything into /data/linux/boot (+ the payload copy in /data/payloads).
	mkdirs(DST);
	for (size_t i = 0; i < 2; i++) mkdirs(payload_dirs[i]);
	if (progress_open("Copying ChromeOS for PS4 ...") < 0) fail("Could not open the progress dialog.%s", "");
	uint64_t done = 0;
	for (size_t i = 0; i < N_BOOT_FILES; i++) {
		snprintf(path2, sizeof(path2), DST "/%s", boot_files[i]);
		if (copy_file(src_fd[i], path2, &done, total, boot_files[i]) != 0) {
			progress_close();
			fail("Copying %s failed (details in the GoldHEN log).", boot_files[i]);
		}
	}
	for (size_t i = 0; i < 2; i++) {
		snprintf(path2, sizeof(path2), "%s/%s", payload_dirs[i], PAYLOAD_NAME);
		if (copy_file(payload_fd, path2, &done, total, "Linux loader payload") != 0) {
			progress_close();
			fail("Copying the loader payload to %s failed.", payload_dirs[i]);
		}
	}
	// Stamp last: only a complete copy lets the next launch skip copying.
	snprintf(path, sizeof(path), "%s/%s", SRC, BUILD_ID);
	int id_fd = open(path, O_RDONLY);
	if (id_fd >= 0) {
		uint64_t d0 = 0;
		if (copy_file(id_fd, DST "/" BUILD_ID, &d0, 0, "build stamp") != 0) klog("build-id copy failed (next launch copies again)");
		close(id_fd);
	}
	unlink(DST "/chromeos-shell");          // debug-only flag files from development builds
	unlink(DST "/chromeos-reset-state");
	progress_set(100, "Starting ChromeOS ...");
	progress_close();
	install_setup();

	// Boot it.
	goldhen_unjailbreak();
	if (send_payload(payload_fd) != 0)
		fail("The files are in place, but the payload could not be started.%s\n\n"
		     "Start it yourself: GoldHEN > Payloads > " PAYLOAD_NAME, "");
	for (;;) sceKernelUsleep(1000000);   // the loader takes over the console
	return 0;
}
