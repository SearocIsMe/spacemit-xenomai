# SD Card Flashing Guide — Milk-V Jupiter (SpacemiT K1)

## Why the old `evl-boot-k1-*.img` did not boot

`make-boot-img.sh` produced a **64 MiB FAT32 *partition* image** — a raw FAT32
filesystem blob with no partition table, no U-Boot SPL, and no rootfs.

The SpacemiT K1 ROM / FSBL locates U-Boot SPL at a fixed raw sector offset
inside a properly partitioned disk.  Writing a bare FAT32 blob to LBA 0 of
an SD card means the ROM finds no valid bootloader there and the board shows
no output at all — exactly the symptom observed.

A working Jupiter image (`buildroot-k1_rt-sdcard.img`) is a **full GPT disk
image** containing:

| Region | Content |
|--------|---------|
| Raw sectors (pre-partition) | U-Boot SPL + proper U-Boot |
| Partition 1 (FAT32) | kernel `Image`, DTBs, `extlinux/extlinux.conf` |
| Partition 2 (ext4) | Root filesystem |

The EVL build only replaces partition 1 content — the bootloader and rootfs
must come from the SpacemiT buildroot base image.

---

## Recommended Workflow (first-time or clean flash)

### Step 0 — Prerequisites

- **Base image** downloaded from SpacemiT:
  https://www.spacemit.com/community/document/info?lang=zh&nodepath=software/SDK/buildroot/k1_buildroot/source.md
  e.g. `buildroot-k1_rt-sdcard.img`

- **EVL kernel built** (see repo root README §5):
  ```bash
  bash scripts/build/00-setup-env.sh
  bash scripts/build/01-apply-patches.sh
  bash scripts/build/02-configure.sh
  bash scripts/build/03-build-kernel.sh
  ```
  Output: `~/work/build-k1/arch/riscv/boot/Image` + DTBs

---

### Step 1 — Build the complete EVL SD card image (Linux / WSL2)

```bash
bash scripts/flash/make-full-sdcard-img.sh \
    ~/Downloads/buildroot-k1_rt-sdcard.img \
    ~/work/build-k1 \
    /tmp
```

This:
1. Copies the full buildroot base image (preserves U-Boot + rootfs verbatim).
2. Loop-mounts partition 1 of the copy.
3. Injects the EVL `Image`, DTBs, and `extlinux/extlinux.conf`.
4. Writes a ready-to-flash `evl-sdcard-k1-YYYYMMDD.img`.

> To put the output somewhere Windows can reach:
> ```bash
> bash scripts/flash/make-full-sdcard-img.sh \
>     ~/Downloads/buildroot-k1_rt-sdcard.img \
>     ~/work/build-k1 \
>     /mnt/c/Users/<you>/Downloads
> ```

---

### Step 2A — Flash from Linux

```bash
# Find your SD card device
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,MODEL

# Flash (replace /dev/sdX with your actual device)
bash scripts/flash/flash-sdcard.sh --image /tmp/evl-sdcard-k1-*.img /dev/sdX
```

Or use `dd` directly:
```bash
sudo dd if=/tmp/evl-sdcard-k1-*.img of=/dev/sdX bs=4M status=progress conv=fsync
```

---

### Step 2B — Flash from Windows

The WSL2 default kernel does **not** include `CONFIG_USB_STORAGE`, so USB SD
card readers are not accessible as block devices from WSL2.  Flash from
Windows instead:

1. **Balena Etcher** (recommended, free):
   - Download: https://etcher.balena.io/
   - Open `evl-sdcard-k1-*.img` → select the SD card disk → Flash.

2. **Rufus**:
   - Select the SD card device.
   - Select `evl-sdcard-k1-*.img`.
   - Mode: **DD Image** (NOT ISO mode).
   - Click Start.

3. **Win32DiskImager**:
   - Image File: `evl-sdcard-k1-*.img`
   - Device: SD card disk (e.g. `\\.\PhysicalDrive2`)
   - Click Write.

> ⚠️ Always write to the **whole disk** (e.g. `Disk 2`), not to a partition
> (e.g. `D:\`).  The image contains the partition table and bootloader.

---

## Subsequent Kernel Updates (inject only)

Once the SD card already has a working Jupiter OS, you can update just the
kernel and DTBs without re-flashing the entire image.

### From Linux

```bash
# SD card already inserted and recognised as /dev/sdb
bash scripts/flash/flash-sdcard.sh /dev/sdb ~/work/build-k1
```

### From Windows (PowerShell, no Admin required)

Windows will auto-mount the FAT32 boot partition (e.g. as `D:\`) when the SD
card is inserted:

```powershell
.\scripts\flash\flash-windows.ps1 -BootDrive D:
```

---

## Boot Configuration

[`configs/extlinux.conf`](../../configs/extlinux.conf) tells U-Boot to boot with:

| Setting | Value |
|---------|-------|
| Kernel | `/Image` (from FAT32 partition 1) |
| DTB | `dtbs/spacemit/k1-x_milkv-jupiter.dtb` |
| Console | `ttyS0,115200` |
| Root device | `/dev/mmcblk0p2` (ext4 partition 2) |

---

## Debugging Boot Issues

### Symptom: Bianbu icon appears then black screen / static cursor

This means U-Boot ran and loaded the kernel. The kernel is panicking or
hanging before it can bring up a graphical console. **Check serial UART first.**

#### Serial Console (UART) — most reliable debug method

Connect a USB-UART adapter (3.3 V logic level) to the Milk-V Jupiter debug header:

| Jupiter pin | Signal | UART adapter |
|-------------|--------|--------------|
| Pin 8  (GPIO14) | TX | RX |
| Pin 10 (GPIO15) | RX | TX |
| Pin 6  | GND | GND |

On host (Linux):
```bash
sudo screen /dev/ttyUSB0 115200
# or
sudo minicom -D /dev/ttyUSB0 -b 115200
```

On Windows: use **PuTTY** → Serial → COM port → 115200 baud.

Power on the board and watch for the boot log. The last line before hang/panic
tells you exactly what failed.

#### Common boot failure causes and fixes

| Symptom in serial log | Cause | Fix |
|-----------------------|-------|-----|
| `VFS: Cannot open root device` | Wrong `root=` in extlinux.conf | Re-run `make-full-sdcard-img.sh` — it now auto-detects `root=` from base image |
| `Kernel panic — not syncing: VFS` | Same as above, or missing initrd | Check initrd line in extlinux.conf |
| `EVL: …` then panic | EVL/Dovetail init crash | See `docs/porting-notes.md`; try booting without EVL first |
| Nothing after `Starting kernel ...` | earlycon not working | Try adding `earlycon=uart8250,mmio32,0xd4017000` |
| Hangs at `Run /init as init process` | initramfs pivot_root failure | Ensure correct `root=` and that partition 2 is ext4 |

#### Quick fix: verify extlinux.conf on the SD card

Mount the SD card boot partition on Linux and check:
```bash
sudo mount /dev/sdb1 /mnt
cat /mnt/extlinux/extlinux.conf
```

The `append` line must have:
- `console=tty1` — enables HDMI kernel console
- `console=ttyS0,115200` — enables serial console
- `root=<correct device or UUID>` — matching your base image's rootfs partition

If using Bianbu (Ubuntu-based), the `root=` is typically `root=UUID=<uuid>`, **not**
`root=/dev/mmcblk0p2`. Re-run `make-full-sdcard-img.sh` to auto-detect and fix this.

---

## After Flashing

Insert the SD card into the Milk-V Jupiter and power on.
See [`docs/testing.md`](../../docs/testing.md) for boot verification steps,
including:

```bash
dmesg | grep -i evl    # verify EVL loaded
evl check              # basic EVL health check
evl test latmus        # latency measurement
```

---

## Script Reference

| Script | Purpose |
|--------|---------|
| [`make-full-sdcard-img.sh`](make-full-sdcard-img.sh) | ✅ **Use this** — builds complete bootable image |
| [`flash-sdcard.sh`](flash-sdcard.sh) | Flash image (Mode A) or inject kernel (Mode B) |
| [`flash-windows.ps1`](flash-windows.ps1) | Windows: inject kernel into already-booting SD card |
| [`make-boot-img.sh`](make-boot-img.sh) | ⚠️ Deprecated — partition-only image, not bootable alone |
