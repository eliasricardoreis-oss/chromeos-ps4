# ChromeOS for PS4 - boot map and firmware audit

Everything here is from source code or from logs on real consoles. Source paths are in
`~/linux` (Strawberry 7.3.3, read-only for us), the loader
(ps4-linux-loader v25.2) and our build tree.
Status marks: **[verified]** seen on a console, **[source]** read in code, **[open]** unknown.

## 1. Boot chain

```
OrbisOS + GoldHEN
 └─ PKG app "ChromeOS for PS4" (pkg/installer)            copies files, sends payload to 127.0.0.1:9090
     └─ GoldHEN BinLoader runs ps4-chromeos-loader.bin      = loader v25.2 linux-1024mb.bin (AIO firmware 5.05-14.00)
         ├─ reads bzImage, initramfs.cpio.gz                /mnt/usb0 > /mnt/usb1 > /data/linux/boot > /user/system/boot
         ├─ reads bootargs.txt (optional), vram.txt (optional)
         ├─ from OrbisOS kernel memory (per-FW offsets, fw_offsets.h):
         │    EAP HDD key  -> /key/eap_hdd_key.bin (32 B, halves byte-reversed)      [source][verified Slim+Fat]
         │    HDMI EDID    -> /lib/firmware/edid/my_edid.bin
         │    GPU firmware -> /lib/firmware/amdgpu/<liverpool|gladius>_*.bin
         │  appended as a 2nd cpio after our initramfs (cpio_hdr(), main-aio.c)
         └─ kexec -> Linux
             └─ Strawberry kernel (AIO: southbridge detected at boot)
                 ├─ ps4-ccp: /key/eap_hdd_key.bin -> /sys/firmware/ps4/eap_hdd_key     [verified]
                 ├─ storage (see 2)
                 └─ initramfs (initramfs-ps4 v0.15 + our overlay)
                     ├─ early hooks: release = quiet + NTP | debug = SSH, logger
                     ├─ ps4hdd_open: cryptsetup AES-XTS on /dev/sdX27 -> UFS2 /ps4hdd
                     │     offset 0 (Aeolia) | skip 111669149696 (Belize, Baikal)
                     ├─ cros_mount: first-start menu -> install (seed + gpt-grow-state)
                     │     -> loop0 (internal) or /dev/sdX (USB) -> dm-verity ROOT-A
                     ├─ PS4 layer: firmware overlay, ps4-layer.sqfs over /usr/lib64 + /etc/init,
                     │     Slim S/PDIF pin off
                     └─ switch_root -> ChromeOS /sbin/init (Upstart)
```

## 2. Internal HDD path per southbridge  [source: drivers/usb/host/xhci-aeolia.c, drivers/ata/ahci.c]

| Southbridge | Consoles | HDD controller | Linux device |
|---|---|---|---|
| Aeolia | Fat CUH-10xx/11xx | **USB 3 on the "middle" xHCI host** (index 1, Aeolia only: `xhci_aeolia_has_middle_host`). `ahci_init_one` in xhci-aeolia returns early for Aeolia. Standalone AHCI 14.2 has 1 port = Blu-ray (`CAP.NP=0`, verified). | usb 4-1 -> usb-storage/uas -> sdX |
| Belize | Fat CUH-12xx, Slim, Pro | AHCI inside the xHCI function (`ahci_init_one`, `ps4sb_sata_phy_init`) | ata -> sdX |
| Baikal | Slim, Pro | AHCI inside xHCI (`baikal_sata_phy_init`), NCQ off | ata -> sda (verified Slim: ata1 6 Gbps) |

**[verified] Fat CUH-1115A (Aeolia) HDD at boot:** the bridge is SCEI "USB-SATA Bridge"
054c:084e on the middle host (usb3 = USB 2 side, usb4 = SuperSpeed side). After the OrbisOS
shutdown the loader runs before kexec (`hook_icc_query_nowait` only hijacks the last ICC
message), its SuperSpeed link fails: `usb 4-1: device not accepting address 2, error -71`,
`usb4-port1: attempt power cycle`, port `not attached`, no sdX. Same with the stock kernel.
Not a lost kernel step: the old Aeolia ICC driver had its USB reset commented out
(`//	resetUsbPort();`), and IOMMU (identity) and the host IRQ are fine.
Recovery (by hand over SSH, then in `cros_aeolia_hdd_kick`, 45-chromeos.sh, after 5 s without
sd?27): `usb4-port1/disable` 1 -> 0 makes the bridge come up on `usb3-port1` (480 Mbit/s);
`usb3-port1/disable` 1 -> 0 brings it back on `usb4-port1` at 5 Gbit/s (97 MB/s read).
Then ps4hdd_open (offset 0) mounts the UFS2 partition with the loader's key.

## 3. Firmware audit

| Firmware | Requested by (source) | Hardware | Built into kernel | Loader cpio | Original initramfs | Our overlay | ChromeOS ROOT-A |
|---|---|---|---|---|---|---|---|
| amdgpu/liverpool_*.bin (ce, me, mec, mec2, pfp, rlc, sdma, sdma1, refresh_uvd, vce) | amdgpu gfx_v7 / cik_sdma / uvd / vce | Fat, Slim | yes (EXTRA_FIRMWARE) | yes (extracted from OrbisOS) | no | yes (from Downloads/lib/firmware) | no |
| amdgpu/gladius_*.bin (incl. gladius_a_/gladius_b_ CP) | same, `cp_name` gladius_a/b by register 0x203e | Pro | yes | yes | no | partly (gladius_*.bin) | no |
| mrvl/sd8797_uapsta.bin | mwifiex_sdio + btmrvl_sdio | Fat (Marvell 88W8797) | yes | no | no | yes (+ /lib/firmware root copy) | yes |
| mrvl/sd8897_uapsta.bin | mwifiex_sdio + btmrvl_sdio | some Slim/Pro | yes | no | no | no | yes |
| mt7668 set (mt7668_patch_e*_hdr.bin, WIFI_RAM_CODE*, EEPROM_MT7668*, TxPwrLimit_MT76x8.dat, wifi.cfg) | mt76x8 vendor driver (drv_wlan/MT6632) | Slim/Pro (MediaTek) | yes | no | no | no | no |
| mediatek/mt7668pr2h.bin | btmtksdio (FIRMWARE_MT7668) | Slim/Pro BT | yes | no | no | no | ? |
| edid/my_edid.bin | drm edid_firmware (only if drm.edid_firmware= set) | all | no | yes | no | removed (was another TV's) | no |
| regulatory.db(.p7s) | cfg80211 | all Wi-Fi | no | no | **no** | removed (was added by us) | yes |

Findings:
- GPU and Wi-Fi firmware for every model is **built into the kernel**; the initramfs copies are
  redundant (the kernel's built-in firmware is found first).
- `regulatory.db` exists only because our overlay adds it. On the Fat it triggered a deadlock in
  the MediaTek vendor driver's `mtk_reg_notify` (built into the AIO kernel, registered even on a
  Marvell console): `reg_regdb_apply` -> `mtk_reg_notify` -> `wiphy_apply_custom_regulatory`
  blocks on a mutex its own worker holds; mwifiex firmware load and `ip` (our DHCP) block behind
  it. [verified on Fat]

Fixes applied:
- initramfs carries **no firmware at all** (build-initramfs.sh refuses any file in
  lib/firmware besides .keep): no regulatory.db (deadlock trigger), no redundant GPU/Wi-Fi
  copies, no foreign edid/my_edid.bin (it was another TV's EDID). Firmware at boot = kernel
  built-ins + what the loader appends (this console's GPU firmware, EDID, HDD key).
- cros_mount waits up to 30 s for /dev/sd?27 (Aeolia HDD is a late USB 3 device).
- installer app writes its files 0666 (FTP can replace them later).

## 4. Known per-model issues

| Issue | Where | Status |
|---|---|---|
| Restart on Aeolia/Belize | sb-icc.c: non-atomic ICC power request after machine_shutdown (possible hang, from source) | Fat CUH-1115A: restart from the UI **works** [verified]; Belize untested |
| Slim S/PDIF pin reports plugged | HDA pin 0x07 | fixed in initramfs (Baikal + 0x9923 only) |
| SELinux enforcing | release kernel | analysed: only cros_spaced denials enforced |
