// psmove-mouse: PS Move (ZCM1/ZCM2, Bluetooth hidraw) -> uinput mouse, using the gyro.
// Static build, plain x86-64 (the PS4 Jaguar CPU has no AVX2).
//   psmove-mouse            run as daemon
//   psmove-mouse --dump     print raw reports (to check the offsets below)
// Options: --sens N (default 10)  --gyro-off N (default 25)  --swap  --inv-x  --inv-y
// Buttons: T(trigger)/Cross = left, Move/Circle = right, PS = middle,
//          Triangle = scroll up, Square = scroll down.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <math.h>
#include <sys/ioctl.h>
#include <linux/hidraw.h>
#include <linux/uinput.h>

static int sens = 10, gyro_off = 25, swap = 0, invx = 0, invy = 0, dump = 0;

static void emit(int fd, int type, int code, int val) {
	struct input_event e; memset(&e, 0, sizeof e);
	e.type = type; e.code = code; e.value = val;
	if (write(fd, &e, sizeof e) < 0) {}
}

static int mk_uinput(void) {
	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0) fd = open("/dev/input/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0) return -1;
	ioctl(fd, UI_SET_EVBIT, EV_KEY); ioctl(fd, UI_SET_EVBIT, EV_REL); ioctl(fd, UI_SET_EVBIT, EV_SYN);
	ioctl(fd, UI_SET_KEYBIT, BTN_LEFT); ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT); ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE);
	ioctl(fd, UI_SET_RELBIT, REL_X); ioctl(fd, UI_SET_RELBIT, REL_Y); ioctl(fd, UI_SET_RELBIT, REL_WHEEL);
	struct uinput_setup us; memset(&us, 0, sizeof us);
	us.id.bustype = BUS_VIRTUAL; us.id.vendor = 0x054c; us.id.product = 0xffee;
	strcpy(us.name, "PS Move Mouse");
	ioctl(fd, UI_DEV_SETUP, &us); ioctl(fd, UI_DEV_CREATE);
	return fd;
}

static int find_move(void) {
	for (int i = 0; i < 32; i++) {
		char p[32]; snprintf(p, sizeof p, "/dev/hidraw%d", i);
		int fd = open(p, O_RDONLY);
		if (fd < 0) continue;
		struct hidraw_devinfo di;
		if (ioctl(fd, HIDIOCGRAWINFO, &di) == 0 && di.vendor == 0x054c &&
		    (di.product == 0x03d5 || di.product == 0x0c5e)) return fd;
		close(fd);
	}
	return -1;
}

static int s16(const unsigned char *b, int o) { return (int)(b[o] | (b[o + 1] << 8)) - 0x8000; }

static void run(int ui, int fd) {
	unsigned char b[64]; double bx = 0, by = 0, bz = 0, rx = 0, ry = 0; int cal = 0, prev = 0;
	for (;;) {
		int n = read(fd, b, sizeof b);
		if (n < 0 && errno == EINTR) continue;
		if (n <= 0) return;                       // controller gone -> caller looks again
		if (dump) { for (int i = 0; i < n; i++) printf("%02x ", b[i]); putchar('\n'); fflush(stdout); continue; }
		if (n < gyro_off + 6 || b[0] != 0x01) continue;
		int gx = s16(b, gyro_off), gy = s16(b, gyro_off + 2), gz = s16(b, gyro_off + 4);
		if (cal < 100) { bx += gx; by += gy; bz += gz; if (++cal == 100) { bx /= 100; by /= 100; bz /= 100; } continue; } // bias: hold still ~1 s
		double a = (swap ? gz - bz : gx - bx), c = (swap ? gx - bx : gz - bz);
		rx += (invx ? -1 : 1) * c * sens / 4000.0; ry += (invy ? -1 : 1) * a * sens / 4000.0;
		int dx = (int)rx, dy = (int)ry; rx -= dx; ry -= dy;
		if (dx) emit(ui, EV_REL, REL_X, dx);
		if (dy) emit(ui, EV_REL, REL_Y, dy);
		int btn = (b[5] > 0x80 || (b[1] & 0x40)) ? 1 : 0;                 // T trigger / Cross
		int rgt = ((b[3] & 0x08) || (b[1] & 0x20)) ? 1 : 0;                // Move / Circle
		int mid = (b[3] & 0x01) ? 1 : 0;                                   // PS
		int up = (b[1] & 0x10) ? 1 : 0, dn = (b[1] & 0x80) ? 1 : 0;        // Triangle / Square
		int cur = btn | rgt << 1 | mid << 2 | up << 3 | dn << 4, ch = cur ^ prev;
		if (ch & 1) emit(ui, EV_KEY, BTN_LEFT, btn);
		if (ch & 2) emit(ui, EV_KEY, BTN_RIGHT, rgt);
		if (ch & 4) emit(ui, EV_KEY, BTN_MIDDLE, mid);
		if ((ch & 8) && up) emit(ui, EV_REL, REL_WHEEL, 1);
		if ((ch & 16) && dn) emit(ui, EV_REL, REL_WHEEL, -1);
		prev = cur;
		emit(ui, EV_SYN, SYN_REPORT, 0);
	}
}

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--dump")) dump = 1;
		else if (!strcmp(argv[i], "--swap")) swap = 1;
		else if (!strcmp(argv[i], "--inv-x")) invx = 1;
		else if (!strcmp(argv[i], "--inv-y")) invy = 1;
		else if (!strcmp(argv[i], "--sens") && i + 1 < argc) sens = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--gyro-off") && i + 1 < argc) gyro_off = atoi(argv[++i]);
	}
	int ui = dump ? -1 : mk_uinput();
	if (!dump && ui < 0) { perror("uinput"); return 1; }
	for (;;) { int fd = find_move(); if (fd >= 0) { run(ui, fd); close(fd); } else sleep(2); }
}
