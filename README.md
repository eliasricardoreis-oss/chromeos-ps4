# ChromeOS for PS4
[DOWNLOAD](https://github.com/theJetsetlife/chromeos-ps4/releases)

Runs **ChromeOS Flex** on a jailbroken PlayStation 4, installed from a PS4 app. ChromeOS
itself is Google's image, unchanged and verified at every boot. This project adds what the
PS4 needs around it: the boot and install, a PS4 Linux kernel, PS4 graphics drivers and a
few fixes.

**Version 1.00** (2026-11-12): ChromeOS Flex 16805.36.0, Strawberry PS4 Linux 7.3.3, Mesa 24.0.9.
---

## What works

| | PS4 Fat CUH-1115A (Aeolia) | PS4 Slim (Baikal) | Pro ( Baikal) 
|---|---|---|----|
| Install from the app, welcome screen | yes | yes | yes
| Graphics (radeonsi, PS4-patched Mesa) | yes | yes | yes
| Wi-Fi, Bluetooth | yes | yes | yes
| HDMI audio (default output) | yes | yes | yes
| Restart, power off from ChromeOS | yes | yes | yes


**Known limits**
- Audio is HDMI only. The Fat's optical output is turned off so ChromeOS uses HDMI.
- No boot chime.
- ChromeOS doesn't update itself. ChromeOS's updater and "Install ChromeOS Flex" are off;
  a new version comes as a new PKG.

---

## How to use

### What you need
- A jailbroken PS4 on **firmware 5.05 up to 14.00** (the range the Linux loader supports)
  with **GoldHEN** (tested with 2.4) and its **BinLoader** turned on (port 9090).
- A TV on HDMI.
- Free space on the PS4 drive: the storage size you pick + about 4 GB, plus 10 GB that
  always stay free. With the recommended 32 GB that is about 47 GB.
- For a USB install: a USB drive (it is erased) and a USB keyboard.

### Install
1. Copy `IV0000-CROS00001_00-CHROMEOSPS4INSTL.pkg` to the PS4 (for example to `/data/pkg`
   over FTP) and install it with GoldHEN's Package Installer.
2. Launch **ChromeOS for PS4**. It copies its files (about 1 GB).
3. Answer the two questions (X selects, O cancels and closes the app):
   - **Where:** *PS4 drive* (games and saves stay) or *USB drive* (that drive is erased).
   - **Size** (PS4 drive only): *Next size* goes through 32 GB (recommended), 64, 128,
     256 GB and "all the free space". Only sizes that fit are shown. *Install* picks one.
4. The app reserves the space once, showing the speed and time left. Measured for 32 GB:
   about 4 minutes on a Slim (~150 MB/s) and 10 minutes on a Fat with its stock drive
   (~59 MB/s). 64 GB takes about twice as long.
5. The app then waits until the PS4 drive has finished writing ("Finishing writing to the
   PS4 drive", about 30 seconds) and starts Linux by itself. Starting Linux while the
   drive was still writing the reserve crashed it, so this wait is measured, not guessed.
6. The PS4 starts Linux. The LED turns **orange** while ChromeOS is installed
   (about 10 minutes). Then the **ChromeOS welcome screen** appears.
   - USB drive (no reserve, no restart): pick the drive on the TV and type `ERASE` with
     the USB keyboard.

### Starting ChromeOS later
Launch **ChromeOS for PS4** again. It skips the copy and boots ChromeOS within seconds.
Starting `ps4-chromeos-loader.bin` from **GoldHEN > Payloads** works too.

Restart from ChromeOS returns to OrbisOS (the PS4 system).

### Updating
Install the newer PKG over the old one and launch it. It copies the new files once;
ChromeOS and your data stay.

### Uninstall
Delete these over FTP, then delete the app:
- `/user/app/chromeos.img` (ChromeOS and all its data)
- the ChromeOS files in `/data/linux/boot` (`bzImage`, `initramfs.cpio.gz`,
  `ps4-layer.sqfs`, `chromeos.img.xz`, `chromeos.img.size`, `ps4-chromeos-loader.bin`,
  `build-id`, `chromeos-target`, `chromeos-error.txt`, and `chromeos.img.alloc` or `chromeos-install-choice`
  if they are there)
- `/data/payloads/ps4-chromeos-loader.bin`

### Dry run
Create an empty file `/data/linux/boot/chromeos-dryrun` (FTP), then launch the app. It
shows the real questions with the real sizes and a summary, and changes nothing. The flag
is removed by that run, so the next launch is a real one.

### When something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| "Continue with the slower install?" | The app couldn't read the free space (GoldHEN didn't give access) | *Continue* installs the old, slow way (about 40 min more, questions on the TV). Or *Cancel*, check that GoldHEN 2.4+ is running, and try again. |
| "The PS4 drive is full" / "write error" | The reserve failed | Full: free up space or pick a smaller size. Other errors: launch again, it continues. |
| No picture, LED stays white, or the PS4 turns off | Linux started while the PS4 drive was still busy | Start OrbisOS and launch the app again (it continues). Please report it with the GoldHEN klog. |
| Red or purple LED, error text, "restarts in 60 s" | ChromeOS couldn't start | It restarts into OrbisOS by itself. The details are in `/data/linux/boot/chromeos-error.txt` (FTP). |
| Kernel panic text | Linux crashed | The PS4 restarts after 30 s. A photo of the screen helps. |
| Orange LED for a long time | Installing | Wait. Don't turn the PS4 off while the LED is orange. |
| "The PS4 drive file system is not clean" | OrbisOS wasn't shut down normally | Start OrbisOS once, shut it down normally, try again. |
| "No PS4 drive key" | Wrong loader for this firmware | Use the `ps4-chromeos-loader.bin` from the PKG. |

The app writes what it does to the GoldHEN klog (port 3232), for example
`nc <PS4 IP> 3232`.

---

## How it works

```
PKG app (OrbisOS)        copies files to /data/linux/boot, asks where + how big,
                         reserves the space, sends the loader to GoldHEN BinLoader
  -> Linux loader        shuts OrbisOS down, starts our kernel + initramfs
  -> initramfs           opens the PS4 drive, installs ChromeOS on first start,
                         sets up ROOT-A (dm-verity, Google's hash), STATE and the PS4 layer
  -> ChromeOS Flex       starts normally (switch_root)
```

- **ROOT-A is never modified.** It is mounted read-only through dm-verity with Google's
  own hash. Only STATE (your data) is written.
- **PS4 layer** (`ps4-layer.sqfs`): a read-only layer the initramfs puts over ROOT-A. It
  holds the PS4-patched Mesa and the switches that turn off ChromeOS's updater and
  "Install ChromeOS Flex".
- **Fast install:** Linux writes the PS4 drive slowly (about 13 MB/s) and must not add new
  space after boot. So the app reserves the space from OrbisOS (about 150 MB/s on the tested Slim), and
  the initramfs unpacks ChromeOS into it in place.
- **Internal install:** `/user/app/chromeos.img` on the PS4 drive, used as a loop device.
  **USB install:** written straight to the drive and found again by its GPT disk GUID.

More detail: [docs/BOOT-MAP.md](docs/BOOT-MAP.md).

---

## Building from source

Host: x86-64 Linux with clang/LLVM, Docker (for Mesa), xz, squashfs-tools, sgdisk and the
[OpenOrbis PS4 Toolchain](https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain)
(`OO_PS4_TOOLCHAIN`).

| Step | Command | Output |
|---|---|---|
| Kernel | `VARIANT=release scripts/build-kernel.sh` | `kbuild-release/out/bzImage` |
| initramfs | `VARIANT=release scripts/build-initramfs.sh` | `out/initramfs-release.cpio.gz` |
| Mesa | `mesa/build-mesa.sh` (Debian 12 in Docker) | `mesa/out/` |
| PS4 layer | `scripts/make-layer.sh` | `out/ps4-layer.sqfs` |
| ChromeOS image | `scripts/make-image.sh RECOVERY.bin out STATE_GIB` | `out/chromeos.img.xz` |
| PKG | `scripts/make-pkg.sh` | `out/pkg/IV0000-CROS00001_00-CHROMEOSPS4INSTL.pkg` |

- The kernel is the [Strawberry PS4 Linux](https://gitlab.com/rmuxnet/linux) tree, built
  out of tree with our configs (`scripts/chromeos*.cfg`).
- `VARIANT=debug` builds a debug kernel and initramfs (SSH, netconsole, permissive
  SELinux). `make-pkg.sh` refuses debug parts.
- The PS4 must get binaries built for plain x86-64 (the Jaguar CPU has no AVX2). Never
  link a modern host's static libraries into them.

### Source layout

| Path | What |
|---|---|
| `pkg/installer/` | the PS4 app (OpenOrbis, C) |
| `initramfs/overlay*/` | our initramfs code: `functions/45-chromeos.sh` (install + boot) and the hooks |
| `initramfs/src/` | the PS4 initramfs we start from, plus `gpt-grow-state.c` and `loop-partscan.c` |
| `mesa/` | Mesa 24.0.9 PS4 patch and its Docker build |
| `scripts/` | build scripts and kernel configs |
| `docs/` | boot map (`BOOT-MAP.md`: what boots, which firmware comes from where) and credits |

---

## Sources

| Part | Source | License |
|---|---|---|
| ChromeOS Flex 16805.36.0 | [Google ChromeOS Flex](https://chromeenterprise.google/os/chromeosflex/) (recovery image) | Google terms; not redistributable by us |
| Kernel: Strawberry PS4 Linux 7.3.3 | [gitlab.com/rmuxnet/linux](https://gitlab.com/rmuxnet/linux) | GPL-2.0 |
| Linux loader payload | [ps4-linux/ps4-linux-loader](https://github.com/ps4-linux/ps4-linux-loader) | see project |
| initramfs base | [GattoDev-debug/initramfs-ps4](https://github.com/GattoDev-debug/initramfs-ps4), [better-initramfs](https://bitbucket.org/piotrkarbowski/better-initramfs) | GPL-3.0 / BSD |
| Mesa 24.0.9 | [mesa3d.org](https://mesa3d.org), [gitlab.freedesktop.org/mesa/mesa](https://gitlab.freedesktop.org/mesa/mesa) | MIT |
| PS4 Mesa patch (adapted) | [centi07/arch-ps4-aur](https://github.com/centi07/arch-ps4-aur), [DionKill/ps4-video-archlinux](https://github.com/DionKill/ps4-video-archlinux) (`ps4-mesa.patch`); origin: [fail0verflow/ps4-radeon-patches](https://github.com/fail0verflow/ps4-radeon-patches) | see projects |
| libdrm 2.4.124 | [dri.freedesktop.org/libdrm](https://dri.freedesktop.org/libdrm/) | MIT |
| LLVM 15 | [llvm.org](https://llvm.org) | Apache-2.0 with LLVM exception |
| GPU / Wi-Fi / Bluetooth firmware | [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git) (AMD, MediaTek, Marvell) | proprietary, linux-firmware terms |
| BusyBox, cryptsetup, LVM2, e2fsprogs, btrfs-progs, mdadm, util-linux, pv, xz | their upstream projects (as shipped in initramfs-ps4) | GPL / LGPL |
| GoldHEN, BinLoader, SDK | [github.com/GoldHEN](https://github.com/GoldHEN) | see project |
| OpenOrbis PS4 Toolchain | [github.com/OpenOrbis](https://github.com/OpenOrbis) | GPL-3.0 |
| Approach | [sebanc/brunch](https://github.com/sebanc/brunch) (idea only, no code) | GPL-3.0 |

Our own code (the app, the initramfs ChromeOS code, `gpt-grow-state`, `loop-partscan`,
the PS4 layer and build scripts) is in this tree and in the release's source archive.

## Credits

Most of this is other people's work. The full list, with everyone from the kernel,
loader and initramfs projects, is in [docs/CREDITS.md](docs/CREDITS.md).
