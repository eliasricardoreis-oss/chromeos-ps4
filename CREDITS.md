# ChromeOS for PS4 - credits

ChromeOS for PS4 is mostly other people's work put together. Everything below is used
unchanged unless it says "modified".

## ChromeOS
- **Google / the ChromiumOS authors**: ChromeOS Flex 16805.36.0, the system image used
  unchanged (ROOT-A is verified with Google's own dm-verity hash). ChromeOS Flex is
  Google's product; the image is not ours to redistribute.
  https://chromeenterprise.google/os/chromeosflex/
- **sebanc**: Brunch, whose approach (an official ChromeOS image booted by our own
  kernel and initramfs) this project follows. No Brunch code is used.
  https://github.com/sebanc/brunch

## PS4 Linux kernel: Strawberry PS4 Linux 7.3.3 (built unmodified, our config only)
- **rmuxnet (Armandas Kvietkus)**: Strawberry, one kernel for Aeolia, Belize and Baikal.
  https://gitlab.com/rmuxnet/linux
- From the Strawberry credits:
  - fail0verflow: the original PS4 Linux
  - whitehax0r: the original 5.4 Baikal bring-up (ps4-linux-baikal)
  - crashniels: the PS4 tree Strawberry is based on
  - Package (feeRnt): original 6.15 Aeolia and Belize source, MT7668 Wi-Fi, CI, bridge fixes
  - Blyadimir: UART, USB, display, testing
  - deWaardt: Baikal hardware maintainer, early tests
  - leg (eclipsed.starr, dreams-of-formaldehyde): bzImage uploads, coordination
  - M H (mircoho): ioremap, ethernet and APCIe fixes
  - Anthony Maniatopoulos (manya4090, Manya3084): Gladius GPU setup, SMU through SAMU, testing
  - Regie Vorkman (TheVorkMan, Regus Prime): DMI strings, testing
  - Comfy702: MT7668 Bluetooth on Baikal
  - team: arabpixel (ArabPixel), packagebob (feeRnt), bjhabibie; coordination: eclipsed.starr,
    hnoobi (TheVorkMan), vanillitefroyo; and the many Baikal, Belize and Aeolia testers listed
    in the Strawberry README
- **The Linux kernel developers**: Linux itself. https://kernel.org

## Linux loader payload (ps4-linux-loader, used unmodified)
- https://github.com/ps4-linux/ps4-linux-loader
- Linux: marcan, shuffle2, eeply, rancido, valeryy, ethylamine, Joonie86
- Exploits: sleirsgoevy, AlAzif, KiwiDog, Specter, Celesteblue, ChendoChap, zecoxao,
  SocraticBliss, ctn123
- Offsets: bestpig, EchoStretch, EinTim23, tihmstar, ArabPixel
- Firmware and southbridge agnostic loader: ArabPixel and rmuxnet

## initramfs (modified: ChromeOS install and boot added in functions/45-chromeos.sh)
- **Piotr Karbowski**: better-initramfs, the base (BSD license).
  https://bitbucket.org/piotrkarbowski/better-initramfs
- **GattoDev (Aryan Hedari)**: initramfs-ps4 v0.15.0, the PS4 initramfs this one starts from.
  https://github.com/GattoDev-debug/initramfs-ps4
- **rmuxnet (Armandas Kvietkus)**: initramfs-ps4 contributions (incl. the southbridge check)
- **DionKill**: the PS4 Linux setup guide. https://dionkill.github.io/ps4-linux-tutorial/
- Tools inside it: BusyBox, cryptsetup and LVM2 (dmsetup), e2fsprogs, btrfs-progs, mdadm,
  util-linux (lsblk), pv, xz - each by its own authors, under its own license.

## Graphics: Mesa 24.0.9 (modified: PS4 Liverpool/Gladius support patch)
- **The Mesa developers**: Mesa (radeonsi, EGL, GBM). https://mesa3d.org
- **centi07 (centi_07)**: arch-ps4-aur, the mesa-ps4 / libdrm-ps4 / xf86-video-amdgpu-ps4
  packages and their `ps4-mesa.patch` (Liverpool and Gladius chip support in radeonsi).
  https://github.com/centi07/arch-ps4-aur
- **DionKill (Diego Pireddu)**: ps4-video-archlinux, the maintained fork of those packages
  (updated to current Mesa), and the PS4 Linux tutorial that points to it.
  https://github.com/DionKill/ps4-video-archlinux
- Our patch (`mesa/mesa-24.0.9-ps4-liverpool.patch`) is that `ps4-mesa.patch` cut down and
  adapted to Mesa 24.0.9: the same chip IDs (CHIP_LIVERPOOL, CHIP_GLADIUS), ASIC ranges
  (STARSHA 0x61-0x71, STARSHP 0x71-0x81) and raster config values, in 4 of its files.
  The patch file itself names no author.
- The PS4 GPU work goes back to **fail0verflow**'s ps4-radeon-patches
  (https://github.com/fail0verflow/ps4-radeon-patches).
- **LLVM project**: LLVM 15 (radeonsi shader compiler, linked in). https://llvm.org
- **libdrm developers**: libdrm 2.4.124. https://dri.freedesktop.org

## Firmware (in the kernel, unmodified, from linux-firmware)
- **AMD**: amdgpu GPU firmware (Liverpool / Gladius)
- **MediaTek**: MT7668 Wi-Fi and Bluetooth firmware (Baikal)
- **Marvell**: Wi-Fi / Bluetooth firmware (Aeolia / Belize)
- Proprietary; redistributable only under the linux-firmware terms, not ours to relicense.

## PS4 app (pkg/installer)
- **OpenOrbis**: the OpenOrbis PS4 Toolchain (compiler setup, libc, PkgTool).
  https://github.com/OpenOrbis
- **GoldHEN team (SiSTRo and contributors)**: GoldHEN, its BinLoader (port 9090, used to
  start the loader) and the GoldHEN SDK call used for the free-space check (syscall 500).
  https://github.com/GoldHEN

## This project
- The PS4-specific pieces written here: the installer app, the ChromeOS boot and install
  code in the initramfs (45-chromeos.sh), gpt-grow-state, loop-partscan, the PS4 layer
  (ps4-layer.sqfs) and the build scripts - with Claude (Anthropic) as coding assistant.
- Tested on a PS4 Fat CUH-1115A and a PS4 Slim.

If your work is used here and missing or wrong in this list, it is a mistake: please
say so and it will be fixed.
