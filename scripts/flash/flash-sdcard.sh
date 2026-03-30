#!/usr/bin/env bash
# =============================================================================
# flash-sdcard.sh
# Write the EVL kernel image + DTBs + modules onto an SD card for
# Milk-V Jupiter boot testing.
#
# Usage:
#   bash scripts/flash/flash-sdcard.sh <device> <build_dir>
#
# Example:
#   bash scripts/flash/flash-sdcard.sh /dev/sdb ~/work/build-k1
#
# WARNING: This script writes directly to a block device.
#          Double-check the device path before running!
#
# SD card partition layout expected (Jupiter default):
#   p1  FAT32  boot   — kernel Image, DTBs, boot.scr / extlinux.conf
#   p2  ext4   rootfs — root filesystem (not touched by this script)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Guard: refuse to run under /mnt/c/
# ---------------------------------------------------------------------------
if [[ "$PWD" == /mnt/* ]]; then
  echo "ERROR: Running from Windows-mounted path. Use WSL2 native FS."
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
DEVICE="${1:-}"
BUILD_DIR="${2:-${HOME}/work/build-k1}"

if [[ -z "${DEVICE}" ]]; then
  echo "Usage: $0 <device> [build_dir]"
  echo "  device    : SD card block device, e.g. /dev/sdb"
  echo "  build_dir : kernel build output dir (default: ~/work/build-k1)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Safety checks
# ---------------------------------------------------------------------------
[[ -b "${DEVICE}" ]] || die "Device ${DEVICE} is not a block device."

# Refuse to flash to a mounted system disk
DEVICE_BASE=$(basename "${DEVICE}")
if lsblk -no MOUNTPOINT "${DEVICE}" 2>/dev/null | grep -qE "^/$|^/boot|^/home|^/usr"; then
  die "Device ${DEVICE} appears to be a system disk. Aborting for safety."
fi

KERNEL_IMAGE="${BUILD_DIR}/arch/riscv/boot/Image"
DTB_DIR="${BUILD_DIR}/arch/riscv/boot/dts/spacemit"
MODULES_DIR="${BUILD_DIR}/modules_install"

[[ -f "${KERNEL_IMAGE}" ]] || die "Kernel image not found: ${KERNEL_IMAGE}"
[[ -d "${DTB_DIR}" ]]      || die "DTB directory not found: ${DTB_DIR}"

# ---------------------------------------------------------------------------
# Confirm with user
# ---------------------------------------------------------------------------
echo ""
warn "=========================================================="
warn "  ABOUT TO WRITE TO: ${DEVICE}"
warn "  Kernel : ${KERNEL_IMAGE}"
warn "  DTBs   : ${DTB_DIR}"
warn "  This will OVERWRITE the boot partition on ${DEVICE}!"
warn "=========================================================="
echo ""
read -rp "Type 'yes' to continue, anything else to abort: " CONFIRM
[[ "${CONFIRM}" == "yes" ]] || { info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Detect boot partition
# ---------------------------------------------------------------------------
BOOT_PART="${DEVICE}1"
[[ -b "${BOOT_PART}" ]] || die "Boot partition not found: ${BOOT_PART}"

# ---------------------------------------------------------------------------
# Mount boot partition
# ---------------------------------------------------------------------------
MOUNT_POINT=$(mktemp -d /tmp/sdcard-boot-XXXXXX)
trap "umount '${MOUNT_POINT}' 2>/dev/null || true; rmdir '${MOUNT_POINT}'" EXIT

info "Mounting ${BOOT_PART} at ${MOUNT_POINT} ..."
sudo mount "${BOOT_PART}" "${MOUNT_POINT}"
ok "Mounted."

# ---------------------------------------------------------------------------
# Copy kernel image
# ---------------------------------------------------------------------------
info "Copying kernel Image ..."
sudo cp "${KERNEL_IMAGE}" "${MOUNT_POINT}/Image"
ok "Kernel copied."

# ---------------------------------------------------------------------------
# Copy DTBs
# ---------------------------------------------------------------------------
info "Copying DTBs ..."
sudo mkdir -p "${MOUNT_POINT}/dtbs/spacemit"
sudo cp "${DTB_DIR}"/*.dtb "${MOUNT_POINT}/dtbs/spacemit/" 2>/dev/null || \
  warn "No DTBs found in ${DTB_DIR} — skipping."
ok "DTBs copied."

# ---------------------------------------------------------------------------
# Copy extlinux.conf if present in repo
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXTLINUX_CONF="${REPO_ROOT}/configs/extlinux.conf"
if [[ -f "${EXTLINUX_CONF}" ]]; then
  info "Copying extlinux.conf ..."
  sudo mkdir -p "${MOUNT_POINT}/extlinux"
  sudo cp "${EXTLINUX_CONF}" "${MOUNT_POINT}/extlinux/extlinux.conf"
  ok "extlinux.conf copied."
fi

# ---------------------------------------------------------------------------
# Sync and unmount
# ---------------------------------------------------------------------------
info "Syncing ..."
sync
sudo umount "${MOUNT_POINT}"
rmdir "${MOUNT_POINT}"
trap - EXIT
ok "SD card boot partition updated."

# ---------------------------------------------------------------------------
# Optional: install modules to rootfs partition
# ---------------------------------------------------------------------------
if [[ -d "${MODULES_DIR}" ]]; then
  echo ""
  read -rp "Install kernel modules to rootfs partition (${DEVICE}2)? [y/N]: " INSTALL_MODS
  if [[ "${INSTALL_MODS}" =~ ^[Yy]$ ]]; then
    ROOTFS_PART="${DEVICE}2"
    [[ -b "${ROOTFS_PART}" ]] || die "Rootfs partition not found: ${ROOTFS_PART}"
    ROOTFS_MOUNT=$(mktemp -d /tmp/sdcard-rootfs-XXXXXX)
    trap "umount '${ROOTFS_MOUNT}' 2>/dev/null || true; rmdir '${ROOTFS_MOUNT}'" EXIT
    sudo mount "${ROOTFS_PART}" "${ROOTFS_MOUNT}"
    info "Installing modules to rootfs ..."
    sudo cp -r "${MODULES_DIR}/lib" "${ROOTFS_MOUNT}/"
    sync
    sudo umount "${ROOTFS_MOUNT}"
    rmdir "${ROOTFS_MOUNT}"
    trap - EXIT
    ok "Modules installed to rootfs."
  fi
fi

echo ""
echo "============================================================"
echo "  SD card ready!"
echo "  Insert into Milk-V Jupiter and power on."
echo "  See docs/testing.md for boot verification steps."
echo "============================================================"
