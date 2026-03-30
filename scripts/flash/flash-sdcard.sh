#!/usr/bin/env bash
# =============================================================================
# flash-sdcard.sh
#
# TWO MODES — read carefully before choosing:
#
# ─────────────────────────────────────────────────────────────────────────────
# MODE A (RECOMMENDED): Flash a complete bootable EVL SD card image
# ─────────────────────────────────────────────────────────────────────────────
# First build a full image with make-full-sdcard-img.sh, then flash it:
#
#   # Step 1 — build the complete image (once per base-image update)
#   bash scripts/flash/make-full-sdcard-img.sh \
#       ~/Downloads/buildroot-k1_rt-sdcard.img \
#       ~/work/build-k1 \
#       /tmp
#
#   # Step 2 — flash to SD card
#   bash scripts/flash/flash-sdcard.sh --image /tmp/evl-sdcard-k1-*.img /dev/sdX
#
# ─────────────────────────────────────────────────────────────────────────────
# MODE B: Inject EVL kernel into an existing Jupiter SD card (already booting)
# ─────────────────────────────────────────────────────────────────────────────
# If the SD card already has a working SpacemiT/buildroot OS on it, you can
# replace only the kernel/DTBs/extlinux.conf without re-flashing everything:
#
#   bash scripts/flash/flash-sdcard.sh /dev/sdX ~/work/build-k1
#
# WARNING: Mode B ONLY works if partition 1 already contains a valid U-Boot
# and the SD card already boots the Jupiter board.  A blank or unpartitioned
# SD card will NOT boot even after Mode B.
#
# SD card partition layout expected (Jupiter default):
#   p1  FAT32  boot   — kernel Image, DTBs, extlinux.conf
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE="inject"       # default: Mode B (inject into existing SD card)
DISK_IMAGE=""
DEVICE=""
BUILD_DIR="${HOME}/work/build-k1"

usage() {
  cat <<EOF

Usage:
  # MODE A (RECOMMENDED) — flash complete EVL disk image to SD card:
  $0 --image <evl-sdcard-k1-*.img> <device>

  # MODE B — inject EVL kernel into boot partition of an existing Jupiter SD card:
  $0 <device> [build_dir]

Arguments (Mode A):
  --image <img>   Complete EVL SD card image built by make-full-sdcard-img.sh
  <device>        SD card block device (e.g. /dev/sdb)

Arguments (Mode B):
  <device>        SD card block device (e.g. /dev/sdb)
  [build_dir]     Kernel build output dir (default: ~/work/build-k1)
                  Must contain arch/riscv/boot/Image and dts/spacemit/*.dtb

NOTE: Mode B ONLY works if the SD card already has a valid bootloader (U-Boot SPL)
      written at the correct raw sector offset.  A blank SD card will not boot.
      Use Mode A for first-time flashing.

EOF
  exit 1
}

# Parse arguments
if [[ "${1:-}" == "--image" ]]; then
  MODE="image"
  DISK_IMAGE="${2:-}"
  DEVICE="${3:-}"
  [[ -n "${DISK_IMAGE}" && -n "${DEVICE}" ]] || usage
else
  DEVICE="${1:-}"
  BUILD_DIR="${2:-${HOME}/work/build-k1}"
  [[ -n "${DEVICE}" ]] || usage
fi

# ---------------------------------------------------------------------------
# Common safety checks
# ---------------------------------------------------------------------------
[[ -b "${DEVICE}" ]] || die "Device ${DEVICE} is not a block device."

if lsblk -no MOUNTPOINT "${DEVICE}" 2>/dev/null | grep -qE "^/$|^/boot|^/home|^/usr"; then
  die "Device ${DEVICE} appears to be a system disk. Aborting for safety."
fi

# ===========================================================================
# MODE A: dd the complete disk image onto the SD card
# ===========================================================================
if [[ "${MODE}" == "image" ]]; then
  [[ -f "${DISK_IMAGE}" ]] || die "Disk image not found: ${DISK_IMAGE}"

  IMG_SIZE=$(du -sh "${DISK_IMAGE}" | cut -f1)
  echo ""
  warn "=========================================================="
  warn "  MODE A — Flash complete EVL disk image"
  warn "  Image  : ${DISK_IMAGE} (${IMG_SIZE})"
  warn "  Device : ${DEVICE}"
  warn "  This will OVERWRITE ALL DATA on ${DEVICE}!"
  warn "=========================================================="
  echo ""
  read -rp "Type 'yes' to continue, anything else to abort: " CONFIRM
  [[ "${CONFIRM}" == "yes" ]] || { info "Aborted."; exit 0; }

  info "Writing image to ${DEVICE} ..."
  sudo dd if="${DISK_IMAGE}" of="${DEVICE}" bs=4M status=progress conv=fsync
  sync
  ok "Image written to ${DEVICE}."

  echo ""
  echo "============================================================"
  echo "  SD card ready!"
  echo "  Insert into Milk-V Jupiter and power on."
  echo "  See docs/testing.md for boot verification steps."
  echo "============================================================"
  exit 0
fi

# ===========================================================================
# MODE B: Inject EVL kernel into boot partition of an existing SD card
# ===========================================================================
KERNEL_IMAGE="${BUILD_DIR}/arch/riscv/boot/Image"
DTB_DIR="${BUILD_DIR}/arch/riscv/boot/dts/spacemit"
MODULES_DIR="${BUILD_DIR}/modules_install"
EXTLINUX_CONF="${REPO_ROOT}/configs/extlinux.conf"

[[ -f "${KERNEL_IMAGE}" ]] || die "Kernel image not found: ${KERNEL_IMAGE}
       Run scripts/build/03-build-kernel.sh first."
[[ -d "${DTB_DIR}" ]]      || die "DTB directory not found: ${DTB_DIR}"

# ---------------------------------------------------------------------------
# Confirm with user
# ---------------------------------------------------------------------------
echo ""
warn "=========================================================="
warn "  MODE B — Inject EVL kernel into existing SD card"
warn "  Device : ${DEVICE}"
warn "  Kernel : ${KERNEL_IMAGE}"
warn "  DTBs   : ${DTB_DIR}"
warn "  This will OVERWRITE the boot partition on ${DEVICE}!"
warn "  The SD card must already have a working U-Boot bootloader."
warn "=========================================================="
echo ""
read -rp "Type 'yes' to continue, anything else to abort: " CONFIRM
[[ "${CONFIRM}" == "yes" ]] || { info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Detect boot partition
# ---------------------------------------------------------------------------
BOOT_PART="${DEVICE}1"
[[ -b "${BOOT_PART}" ]] || die "Boot partition not found: ${BOOT_PART}
       Is the SD card inserted and partitioned?"

# ---------------------------------------------------------------------------
# Mount boot partition
# ---------------------------------------------------------------------------
MOUNT_POINT=$(mktemp -d /tmp/sdcard-boot-XXXXXX)
trap "sudo umount '${MOUNT_POINT}' 2>/dev/null || true; rmdir '${MOUNT_POINT}' 2>/dev/null || true" EXIT

info "Mounting ${BOOT_PART} at ${MOUNT_POINT} ..."
sudo mount "${BOOT_PART}" "${MOUNT_POINT}"
ok "Mounted."

# ---------------------------------------------------------------------------
# Copy kernel image
# ---------------------------------------------------------------------------
info "Copying kernel Image ($(du -sh "${KERNEL_IMAGE}" | cut -f1)) ..."
sudo cp "${KERNEL_IMAGE}" "${MOUNT_POINT}/Image"
ok "Kernel copied."

# ---------------------------------------------------------------------------
# Copy DTBs
# ---------------------------------------------------------------------------
info "Copying DTBs ..."
sudo mkdir -p "${MOUNT_POINT}/dtbs/spacemit"
DTB_COUNT=0
for dtb in "${DTB_DIR}"/*.dtb; do
  [[ -f "${dtb}" ]] || continue
  sudo cp "${dtb}" "${MOUNT_POINT}/dtbs/spacemit/$(basename "${dtb}")"
  (( DTB_COUNT++ )) || true
done
if [[ "${DTB_COUNT}" -gt 0 ]]; then
  ok "${DTB_COUNT} DTBs copied."
else
  warn "No DTBs found in ${DTB_DIR} — skipping."
fi

# ---------------------------------------------------------------------------
# Copy extlinux.conf
# ---------------------------------------------------------------------------
if [[ -f "${EXTLINUX_CONF}" ]]; then
  info "Copying extlinux.conf ..."
  sudo mkdir -p "${MOUNT_POINT}/extlinux"
  sudo cp "${EXTLINUX_CONF}" "${MOUNT_POINT}/extlinux/extlinux.conf"
  ok "extlinux.conf copied."
else
  warn "extlinux.conf not found at ${EXTLINUX_CONF} — skipping."
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
    trap "sudo umount '${ROOTFS_MOUNT}' 2>/dev/null || true; rmdir '${ROOTFS_MOUNT}' 2>/dev/null || true" EXIT
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
