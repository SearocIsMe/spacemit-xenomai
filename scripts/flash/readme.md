# SD Card Flashing Guide

Flash the EVL-patched SpacemiT K1 kernel onto an SD card for Milk-V Jupiter boot testing.

## Prerequisites

- Kernel already built: `~/work/build-k1/arch/riscv/boot/Image` (33 MB)
- SD card with a working Jupiter OS image (rootfs on partition 2)
  - If not, flash the full OS first: https://milkv.io/docs/jupiter/getting-started/boot
  - Then re-run this script to replace only the kernel

## WSL2: Attach SD Card via usbipd-win

WSL2 does not see USB block devices by default. Use `usbipd-win` to pass the SD card through.

### Step 1 — Install usbipd-win (Windows PowerShell, Admin)

```powershell
winget install --interactive --exact dorssel.usbipd-win
```

Restart PowerShell as Administrator after installation.

### Step 2 — Identify and attach the SD card (Windows PowerShell, Admin)

```powershell
# List all USB devices — note the BUSID of your SD card reader
usbipd list

# One-time bind (replace 4-4 with your actual BUSID)
usbipd bind --busid 4-4

# Attach to WSL2
usbipd attach --wsl --busid 4-4
```

### Step 3 — Verify in WSL2

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL,MODEL
# A new disk should appear, e.g. /dev/sdd with two partitions:
#   sdd1  FAT32  boot
#   sdd2  ext4   rootfs
```

## Flash the Kernel

```bash
bash scripts/flash/flash-sdcard.sh /dev/sdd ~/work/build-k1
```

The script will:
1. Mount the FAT32 boot partition (`/dev/sdd1`)
2. Copy `Image` (kernel) to `/boot/Image`
3. Copy 26 DTBs to `/boot/dtbs/spacemit/`
4. Copy `configs/extlinux.conf` to `/boot/extlinux/extlinux.conf`
5. Optionally install kernel modules to the rootfs partition

## Boot Configuration

[`configs/extlinux.conf`](../../configs/extlinux.conf) configures U-Boot to boot with:

- **DTB**: `k1-x_milkv-jupiter.dtb`
- **Console**: `ttyS0,115200`
- **Root**: `/dev/mmcblk0p2` (rootfs partition on SD card)

## After Flashing

Insert the SD card into the Milk-V Jupiter and power on.
See [`docs/testing.md`](../../docs/testing.md) for boot verification steps.
