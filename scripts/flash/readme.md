# SD Card Flashing Guide

Flash the EVL-patched SpacemiT K1 kernel onto an SD card for Milk-V Jupiter boot testing.

## Prerequisites

- Kernel already built: `~/work/build-k1/arch/riscv/boot/Image` (33 MB)
- SD card with a working Jupiter OS image (rootfs on partition 2)
  - If not, flash the full OS first: https://milkv.io/docs/jupiter/getting-started/boot
  - Then re-run this script to replace only the kernel

---

## Option A: Flash from a Native Linux Machine (Recommended)

If you have access to a native Linux machine (or a Linux live USB), this is the simplest path.

```bash
# Insert SD card, find device (e.g. /dev/sdb)
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,MODEL

# Clone this repo and run the flash script
git clone https://github.com/YOUR_REPO/spacemit-xenomai.git
bash spacemit-xenomai/scripts/flash/flash-sdcard.sh /dev/sdb ~/work/build-k1
```

---

## Option B: Flash from Windows (No WSL2 Required)

The WSL2 default kernel (`5.15.167.4-microsoft-standard-WSL2`) does **not** include
`CONFIG_USB_STORAGE`, so USB SD card readers are not visible as block devices in WSL2.

Instead, copy the files directly from Windows using one of these methods:

### Method B1: Windows Explorer (Manual)

1. Insert the SD card — Windows will mount the FAT32 boot partition (e.g. `D:\`)
2. Copy files from WSL2 to Windows:
   ```powershell
   # In PowerShell — WSL2 files are accessible at \\wsl$\Ubuntu\...
   $build = "\\wsl$\Ubuntu\home\lindows\work\build-k1"
   $repo  = "\\wsl$\Ubuntu\home\lindows\projects\spacemit-xenomai"
   $boot  = "D:\"   # adjust to your SD card drive letter

   # Copy kernel image
   Copy-Item "$build\arch\riscv\boot\Image" "$boot\Image" -Force

   # Copy DTBs
   New-Item -ItemType Directory -Force "$boot\dtbs\spacemit"
   Copy-Item "$build\arch\riscv\boot\dts\spacemit\*.dtb" "$boot\dtbs\spacemit\" -Force

   # Copy extlinux.conf
   New-Item -ItemType Directory -Force "$boot\extlinux"
   Copy-Item "$repo\configs\extlinux.conf" "$boot\extlinux\extlinux.conf" -Force
   ```

### Method B2: Automated PowerShell Script

Save and run [`scripts/flash/flash-windows.ps1`](flash-windows.ps1) in PowerShell:

```powershell
# Run from PowerShell (no Admin required)
.\scripts\flash\flash-windows.ps1 -BootDrive D:
```

---

## Option C: WSL2 with Custom Kernel (Advanced)

Build a custom WSL2 kernel with `CONFIG_USB_STORAGE=y` to enable SD card access from WSL2.

```bash
# Clone WSL2 kernel source
git clone --depth=1 --branch linux-msft-wsl-5.15.167.4 \
  https://github.com/microsoft/WSL2-Linux-Kernel.git ~/work/wsl2-kernel

# Enable USB storage
cd ~/work/wsl2-kernel
cp Microsoft/config-wsl .config
scripts/config --enable CONFIG_USB_STORAGE --enable CONFIG_USB \
               --enable CONFIG_SCSI --enable CONFIG_BLK_DEV_SD
make olddefconfig
make -j$(nproc) LOCALVERSION="-usb"

# Install custom kernel
mkdir -p /mnt/c/wsl2-kernels
cp arch/x86/boot/bzImage /mnt/c/wsl2-kernels/bzImage-usb
```

Then add to `C:\Users\<you>\.wslconfig`:
```ini
[wsl2]
kernel=C:\\wsl2-kernels\\bzImage-usb
```

Restart WSL2 (`wsl --shutdown` in PowerShell), then re-attach the SD card via usbipd and run `flash-sdcard.sh`.

---

## Boot Configuration

[`configs/extlinux.conf`](../../configs/extlinux.conf) configures U-Boot to boot with:

- **DTB**: `k1-x_milkv-jupiter.dtb`
- **Console**: `ttyS0,115200`
- **Root**: `/dev/mmcblk0p2` (rootfs partition on SD card)

## After Flashing

Insert the SD card into the Milk-V Jupiter and power on.
See [`docs/testing.md`](../../docs/testing.md) for boot verification steps.
