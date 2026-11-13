// loop-partscan FILE [ro]
// Attach FILE to the next free loop device with LO_FLAGS_PARTSCAN and print
// /dev/loopN. Lets the kernel scan the GPT without loop.max_part, so every
// loop device keeps minor == N (ChromeOS's loop handling relies on that) and
// partitions get dynamic (blkext) device numbers, like on a real disk.
//
// Built WITHOUT any libc (-nostdlib, raw syscalls): the build host's static libc
// is compiled for x86-64-v3 (AVX2), which the PS4's Jaguar CPU lacks (SIGILL).
#include <linux/loop.h>
#include <asm/unistd.h>

typedef unsigned long u64;

static long sys3(long n, long a, long b, long c) {
	long r;
	__asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
	return r;
}
#define O_RDONLY 0
#define O_RDWR 2
#define EBUSY 16

static long sys_open(const char *p, int f) { return sys3(__NR_open, (long)p, f, 0); }
static long sys_ioctl(long fd, unsigned long req, long arg) { return sys3(__NR_ioctl, fd, (long)req, arg); }
static long sys_write(long fd, const void *b, long n) { return sys3(__NR_write, fd, (long)b, n); }
static long sys_close(long fd) { return sys3(__NR_close, fd, 0, 0); }
static void sys_exit(int c) { sys3(__NR_exit_group, c, 0, 0); for (;;) {} }
static void msleep20(void) {
	struct { long s, ns; } t = { 0, 20000000 };
	sys3(__NR_nanosleep, (long)&t, 0, 0);
}

static long slen(const char *s) { long n = 0; while (s[n]) n++; return n; }
static void out(long fd, const char *s) { sys_write(fd, s, slen(s)); }
static void err2(const char *what, const char *msg) { out(2, "loop-partscan: "); out(2, what); out(2, ": "); out(2, msg); out(2, "\n"); }
static int streq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static void zero(void *p, long n) { volatile char *c = p; while (n--) *c++ = 0; }

static int run(int argc, char **argv) {
	if (argc < 2) { out(2, "usage: loop-partscan FILE [ro]\n"); return 2; }
	int ro = argc > 2 && streq(argv[2], "ro");
	long ffd = sys_open(argv[1], ro ? O_RDONLY : O_RDWR);
	if (ffd < 0) { err2(argv[1], "open failed"); return 1; }
	long ctl = sys_open("/dev/loop-control", O_RDWR);
	if (ctl < 0) { err2("/dev/loop-control", "open failed"); return 1; }
	for (int tries = 0; tries < 8; tries++) {
		long n = sys_ioctl(ctl, LOOP_CTL_GET_FREE, 0);
		if (n < 0) { err2("LOOP_CTL_GET_FREE", "failed"); return 1; }
		char dev[32] = "/dev/loop";
		char num[12]; int k = 0;
		do { num[k++] = '0' + n % 10; n /= 10; } while (n);
		int p = 9; while (k) dev[p++] = num[--k]; dev[p] = 0;
		long lfd = -1;
		for (int w = 0; w < 50 && lfd < 0; w++) {  // devtmpfs node may lag a moment
			lfd = sys_open(dev, ro ? O_RDONLY : O_RDWR);
			if (lfd < 0) msleep20();
		}
		if (lfd < 0) { err2(dev, "open failed"); return 1; }
		struct loop_config cfg;
		zero(&cfg, sizeof cfg);
		cfg.fd = (unsigned int)ffd;
		cfg.info.lo_flags = LO_FLAGS_PARTSCAN | (ro ? LO_FLAGS_READ_ONLY : 0);
		for (int i = 0; i < LO_NAME_SIZE - 1 && argv[1][i]; i++) cfg.info.lo_file_name[i] = argv[1][i];
		long r = sys_ioctl(lfd, LOOP_CONFIGURE, (long)&cfg);
		if (r == 0) { out(1, dev); out(1, "\n"); return 0; }
		sys_close(lfd);
		if (r != -EBUSY) { err2("LOOP_CONFIGURE", "failed"); return 1; }
	}
	out(2, "loop-partscan: no free loop device\n");
	return 1;
}

// Entry: the kernel puts argc at (%rsp), argv right after it.
__attribute__((used)) static void start_c(long *sp) {
	int argc = (int)sp[0];
	char **argv = (char **)(sp + 1);
	sys_exit(run(argc, argv));
}
__asm__(".global _start\n_start:\n\txor %rbp,%rbp\n\tmov %rsp,%rdi\n\tand $-16,%rsp\n\tcall start_c\n\thlt\n");
