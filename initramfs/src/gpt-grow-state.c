// gpt-grow-state TARGET [STATE_GIB]
//
// Grows partition 1 (ChromeOS STATE, the last partition on the disk) of the GPT on
// TARGET (an image file or a block device) after TARGET was made bigger:
//   - partition 1 ends at the last usable sector, or at STATE_GIB GiB if given
//   - the backup GPT (entries + header) moves to the new end of TARGET
//   - last usable LBA, alternate LBA and both CRCs are updated; the (hybrid) MBR is not touched
// Nothing else changes: partitions 2..12 (ROOT-A, KERN-A, EFI, ...) keep their
// sectors, GUIDs and attributes, byte for byte. Refuses anything unexpected.
//
// Built WITHOUT any libc (-nostdlib, raw syscalls), baseline x86-64 only: it runs in
// the PS4 initramfs on a Jaguar CPU.
#include <asm/unistd.h>

typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned char u8;

static long sc3(long n, long a, long b, long c) {
	long r;
	__asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
	return r;
}
static long sc4(long n, long a, long b, long c, long d) {
	long r;
	register long r10 __asm__("r10") = d;
	__asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10) : "rcx", "r11", "memory");
	return r;
}
#define O_RDWR 2
static long xopen(const char *p) { return sc3(__NR_open, (long)p, O_RDWR, 0); }
static long xpread(long fd, void *b, long n, u64 off) { return sc4(__NR_pread64, fd, (long)b, n, (long)off); }
static long xpwrite(long fd, const void *b, long n, u64 off) { return sc4(__NR_pwrite64, fd, (long)b, n, (long)off); }
static void xexit(int c) { sc3(__NR_exit_group, c, 0, 0); for (;;) {} }

static long slen(const char *s) { long n = 0; while (s[n]) n++; return n; }
static void out(long fd, const char *s) { sc3(__NR_write, fd, (long)s, slen(s)); }
static void die(const char *m) { out(2, "gpt-grow-state: "); out(2, m); out(2, "\n"); xexit(1); }
static void mcpy(void *d, const void *s, long n) { u8 *a = d; const u8 *b = s; while (n--) *a++ = *b++; }
static int mcmp(const void *a, const void *b, long n) { const u8 *x = a, *y = b; while (n--) { if (*x != *y) return 1; x++; y++; } return 0; }
static u64 rd64(const u8 *p) { u64 v = 0; for (int i = 7; i >= 0; i--) v = (v << 8) | p[i]; return v; }
static u32 rd32(const u8 *p) { return (u32)p[0] | (u32)p[1] << 8 | (u32)p[2] << 16 | (u32)p[3] << 24; }
static void wr64(u8 *p, u64 v) { for (int i = 0; i < 8; i++) { p[i] = (u8)v; v >>= 8; } }
static void wr32(u8 *p, u32 v) { for (int i = 0; i < 4; i++) { p[i] = (u8)v; v >>= 8; } }

static u32 crc32(const u8 *p, u64 n) {
	u32 c = 0xFFFFFFFFu;
	while (n--) {
		c ^= *p++;
		for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
	}
	return ~c;
}

static u64 parse_u64(const char *s) {
	u64 v = 0;
	if (!*s) die("bad number");
	for (; *s; s++) { if (*s < '0' || *s > '9') die("bad number"); v = v * 10 + (u64)(*s - '0'); }
	return v;
}

static void put_u64(long fd, u64 v) {
	char b[24]; int i = 23; b[i] = 0;
	do { b[--i] = (char)('0' + v % 10); v /= 10; } while (v);
	out(fd, b + i);
}

#define SECT 512
#define MAX_ENT_BYTES (128 * 128)
static u8 mbr[SECT], hdr[SECT], ent[MAX_ENT_BYTES], zero[SECT];

static u64 target_size(long fd) {
	struct { u64 dev, ino, nlink; u32 mode, uid, gid, pad; u64 rdev; long size; char rest[96]; } st;
	if (sc3(__NR_fstat, fd, (long)&st, 0) < 0) die("fstat failed");
	if ((st.mode & 0170000) == 0060000) {               // block device
		u64 sz = 0;
		if (sc3(__NR_ioctl, fd, 0x80081272L /* BLKGETSIZE64 */, (long)&sz) < 0) die("BLKGETSIZE64 failed");
		return sz;
	}
	return (u64)st.size;
}

static int run(int argc, char **argv) {
	if (argc < 2) { out(2, "usage: gpt-grow-state TARGET [STATE_GIB]\n"); return 2; }
	long fd = xopen(argv[1]);
	if (fd < 0) die("cannot open target");
	u64 total = target_size(fd) / SECT;
	if (total < 64) die("target too small");

	if (xpread(fd, mbr, SECT, 0) != SECT || xpread(fd, hdr, SECT, SECT) != SECT) die("read failed");
	if (mcmp(hdr, "EFI PART", 8)) die("no GPT header at LBA 1");
	u32 hsize = rd32(hdr + 12);
	if (hsize < 92 || hsize > SECT) die("bad GPT header size");
	u32 hcrc = rd32(hdr + 16);
	wr32(hdr + 16, 0);
	if (crc32(hdr, hsize) != hcrc) die("GPT header CRC mismatch");
	if (rd64(hdr + 24) != 1) die("primary header not at LBA 1");
	u64 old_alt = rd64(hdr + 32), first_usable = rd64(hdr + 40);
	u64 plba = rd64(hdr + 72);
	u32 nent = rd32(hdr + 80), esz = rd32(hdr + 84), ecrc = rd32(hdr + 88);
	if (esz != 128 || nent == 0 || (u64)nent * esz > MAX_ENT_BYTES || plba != 2) die("unexpected entry array layout");
	u64 ebytes = (u64)nent * esz, esects = (ebytes + SECT - 1) / SECT;
	if (xpread(fd, ent, (long)ebytes, plba * SECT) != (long)ebytes) die("entry read failed");
	if (crc32(ent, ebytes) != ecrc) die("GPT entries CRC mismatch");

	// Partition 1 must exist and be the last partition on the disk.
	u8 *p1 = ent;
	static const u8 nil[16];
	if (!mcmp(p1, nil, 16)) die("partition 1 is empty");
	u64 p1_first = rd64(p1 + 32);
	for (u32 i = 1; i < nent; i++) {
		u8 *e = ent + (u64)i * esz;
		if (!mcmp(e, nil, 16)) continue;
		if (rd64(e + 40) >= p1_first) die("partition 1 is not the last partition");
	}

	u64 new_alt = total - 1;
	u64 new_last_usable = new_alt - esects - 0;   // entries at new_alt-esects .. new_alt-1
	new_last_usable -= 1;
	u64 new_p1_last = new_last_usable;
	if (argc > 2) {
		u64 gib = parse_u64(argv[2]);
		u64 want = p1_first + gib * (1073741824ULL / SECT) - 1;
		if (want > new_last_usable) die("requested STATE size does not fit");
		new_p1_last = want;
	}
	if (new_p1_last < p1_first + 2048) die("STATE would be too small");
	if (new_alt < old_alt) die("target is smaller than the GPT says; refusing to shrink");

	// Update partition 1, entries CRC, primary header.
	wr64(p1 + 40, new_p1_last);
	u32 new_ecrc = crc32(ent, ebytes);
	wr64(hdr + 32, new_alt);
	wr64(hdr + 48, new_last_usable);
	wr32(hdr + 88, new_ecrc);
	wr32(hdr + 16, 0);
	wr32(hdr + 16, crc32(hdr, hsize));

	// Backup header: same, with current/alternate swapped and its own entry array.
	static u8 bhdr[SECT];
	mcpy(bhdr, hdr, SECT);
	wr64(bhdr + 24, new_alt);
	wr64(bhdr + 32, 1);
	wr64(bhdr + 72, new_alt - esects);
	wr32(bhdr + 16, 0);
	wr32(bhdr + 16, crc32(bhdr, hsize));

	// MBR: ChromeOS uses a hybrid MBR (EFI FAT32 entry for legacy boot + a 1-sector 0xEE
	// entry), which does not depend on the disk size. Only check it, never write it.
	int has_ee = 0;
	for (int i = 0; i < 4; i++) if (mbr[446 + 16 * i + 4] == 0xEE) has_ee = 1;
	if (mbr[510] != 0x55 || mbr[511] != 0xAA || !has_ee) die("no GPT-protective MBR entry");

	// Write: backup first (outside everything in use), then primary, then MBR.
	if (xpwrite(fd, ent, (long)ebytes, (new_alt - esects) * SECT) != (long)ebytes) die("backup entries write failed");
	if (xpwrite(fd, bhdr, SECT, new_alt * SECT) != SECT) die("backup header write failed");
	if (xpwrite(fd, ent, (long)ebytes, plba * SECT) != (long)ebytes) die("entries write failed");
	if (xpwrite(fd, hdr, SECT, SECT) != SECT) die("header write failed");
	// Wipe the old backup header so nothing mistakes it for a valid GPT later.
	if (old_alt != new_alt && old_alt < total) xpwrite(fd, zero, SECT, old_alt * SECT);
	if (sc3(__NR_fsync, fd, 0, 0) < 0) die("fsync failed");

	out(1, "STATE: sectors "); put_u64(1, p1_first); out(1, "-"); put_u64(1, new_p1_last);
	out(1, " ("); put_u64(1, (new_p1_last - p1_first + 1) * SECT / 1048576); out(1, " MiB), disk ");
	put_u64(1, total * SECT / 1048576); out(1, " MiB\n");
	(void)first_usable;
	return 0;
}

__attribute__((used)) static void start_c(long *sp) {
	xexit(run((int)sp[0], (char **)(sp + 1)));
}
__asm__(".global _start\n_start:\n\txor %rbp,%rbp\n\tmov %rsp,%rdi\n\tand $-16,%rsp\n\tcall start_c\n\thlt\n");
