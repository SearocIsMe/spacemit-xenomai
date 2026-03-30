#!/usr/bin/env bash
# =============================================================================
# make-full-sdcard-img.sh
#
# Produce a COMPLETE, BOOTABLE SD card image for Milk-V Jupiter by:
#   1. Copying a SpacemiT/buildroot base image (which contains U-Boot SPL,
#      partition table, and rootfs) verbatim.
#   2. Mounting the FAT32 boot partition (p1) from that copy via a loop device.
#   3. Replacing the kernel Image, DTBs, and extlinux.conf with the freshly
#      built EVL-patched versions.
#
# The result is a drop-in replacement for buildroot-k1_rt-sdcard.img — flash it
# to an SD card with dd/Balena Etcher/Rufus and it will boot on Jupiter.
#
# Usage:
#   bash scripts/flash/make-full-sdcard-img.sh <base_image> [build_dir] [output_dir]
#   bash scripts/flash/make-full-sdcard-img.sh \
#    ~/Downloads/buildroot-k1_rt-sdcard.img \
#    ~/work/build-k1 \
#    /tmp

# Arguments:
#   base_image   Full SpacemiT buildroot SD card image to use as the base.
#                Download from:
#                  https://www.spacemit.com/community/document/info?lang=zh
#                    &nodepath=software/SDK/buildroot/k1_buildroot/source.md
#                Example: ~/Downloads/buildroot-k1_rt-sdcard.img
#
#   build_dir    Kernel build output directory (default: ~/work/build-k1)
#                Must contain:
#                  arch/riscv/boot/Image
#                  arch/riscv/boot/dts/spacemit/*.dtb
#
#   output_dir   Where to write the finished image (default: /tmp)
#
# Output:
#   evl-sdcard-k1-YYYYMMDD.img  — complete bootable SD card image
#
# Dependencies:
#   util-linux  (losetup, lsblk)     — usually pre-installed
#   mount/umount                     — standard
#   sudo                             — required for loop mount
#
# Flash the output image to an SD card:
#   # Linux:
#   sudo dd if=evl-sdcard-k1-*.img of=/dev/sdX bs=4M status=progress conv=fsync
#   # Windows: use Balena Etcher or Rufus (write as raw disk image, NOT partition)
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
info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
BASE_IMAGE="${1:-}"
BUILD_DIR="${2:-${HOME}/work/build-k1}"
OUTPUT_DIR="${3:-/tmp}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -z "${BASE_IMAGE}" ]]; then
  echo ""
  echo "Usage: $0 <base_image> [build_dir] [output_dir]"
  echo ""
  echo "  base_image  SpacemiT buildroot full disk image (e.g. buildroot-k1_rt-sdcard.img)"
  echo "  build_dir   EVL kernel build output dir (default: ~/work/build-k1)"
  echo "  output_dir  Where to write the finished image (default: /tmp)"
  echo ""
  echo "Download the base image from:"
  echo "  https://www.spacemit.com/community/document/info?lang=zh"
  echo "    &nodepath=software/SDK/buildroot/k1_buildroot/source.md"
  echo ""
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
[[ -f "${BASE_IMAGE}" ]]   || die "Base image not found: ${BASE_IMAGE}"

KERNEL_IMAGE="${BUILD_DIR}/arch/riscv/boot/Image"
DTB_DIR="${BUILD_DIR}/arch/riscv/boot/dts/spacemit"
EXTLINUX_CONF="${REPO_ROOT}/configs/extlinux.conf"

[[ -f "${KERNEL_IMAGE}" ]] || die "Kernel image not found: ${KERNEL_IMAGE}
       Run scripts/build/03-build-kernel.sh first."
[[ -d "${DTB_DIR}" ]]      || die "DTB directory not found: ${DTB_DIR}"
[[ -f "${EXTLINUX_CONF}" ]] || die "extlinux.conf not found: ${EXTLINUX_CONF}"
[[ -d "${OUTPUT_DIR}" ]]   || die "Output directory not found: ${OUTPUT_DIR}"

IMG_NAME="evl-sdcard-k1-$(date +%Y%m%d).img"
IMG="${OUTPUT_DIR}/${IMG_NAME}"

info "Base image : ${BASE_IMAGE} ($(du -sh "${BASE_IMAGE}" | cut -f1))"
info "Build dir  : ${BUILD_DIR}"
info "Kernel     : ${KERNEL_IMAGE} ($(du -sh "${KERNEL_IMAGE}" | cut -f1))"
info "Output     : ${IMG}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Copy base image
# ---------------------------------------------------------------------------
info "Copying base image to output location ..."
info "(This may take a minute — the image is large.)"
cp --sparse=auto "${BASE_IMAGE}" "${IMG}"
ok "Image copied: ${IMG} ($(du -sh "${IMG}" | cut -f1))"

# ---------------------------------------------------------------------------
# Step 2: Attach image as a loop device with partition scanning
# ---------------------------------------------------------------------------
info "Attaching image as loop device ..."
LOOP=$(sudo losetup -Pf --show "${IMG}")
ok "Loop device: ${LOOP}"

# Ensure loop partitions are visible
# losetup -P scans them, but give udev a moment on some systems
sleep 1

BOOT_PART="${LOOP}p1"
if [[ ! -b "${BOOT_PART}" ]]; then
  # Fallback: try kpartx
  if command -v kpartx &>/dev/null; then
    warn "${BOOT_PART} not found — trying kpartx ..."
    sudo kpartx -av "${LOOP}" >/dev/null
    BOOT_PART="/dev/mapper/$(basename "${LOOP}")p1"
    sleep 1
  fi
fi
[[ -b "${BOOT_PART}" ]] || {
  sudo losetup -d "${LOOP}" 2>/dev/null || true
  die "Boot partition device not found: ${BOOT_PART}
       Ensure the base image has a valid GPT/MBR partition table."
}

# ---------------------------------------------------------------------------
# Step 3: Mount the boot partition
# ---------------------------------------------------------------------------
MOUNT_POINT=$(mktemp -d /tmp/evl-boot-XXXXXX)
LOOP_REF="${LOOP}"   # capture for cleanup

cleanup() {
  info "Cleaning up ..."
  sudo umount "${MOUNT_POINT}" 2>/dev/null || true
  rmdir "${MOUNT_POINT}" 2>/dev/null || true
  sudo losetup -d "${LOOP_REF}" 2>/dev/null || true
  if command -v kpartx &>/dev/null; then
    sudo kpartx -dv "${LOOP_REF}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

info "Mounting ${BOOT_PART} at ${MOUNT_POINT} ..."
sudo mount "${BOOT_PART}" "${MOUNT_POINT}"
ok "Boot partition mounted."

# ---------------------------------------------------------------------------
# Step 4: Show existing boot partition contents
# ---------------------------------------------------------------------------
info "Existing boot partition contents:"
ls -lh "${MOUNT_POINT}/" 2>/dev/null | head -20 || true
echo ""

# ---------------------------------------------------------------------------
# Step 5: Inject EVL kernel
# ---------------------------------------------------------------------------
info "Copying EVL kernel Image ($(du -sh "${KERNEL_IMAGE}" | cut -f1)) ..."
sudo cp "${KERNEL_IMAGE}" "${MOUNT_POINT}/Image"
ok "Kernel injected."

# ---------------------------------------------------------------------------
# Step 6: Inject DTBs
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
  ok "${DTB_COUNT} DTBs injected."
else
  warn "No DTBs found in ${DTB_DIR} — skipping."
fi

# ---------------------------------------------------------------------------
# Step 7: Inject extlinux.conf
# ---------------------------------------------------------------------------
info "Injecting extlinux.conf ..."
sudo mkdir -p "${MOUNT_POINT}/extlinux"
sudo cp "${EXTLINUX_CONF}" "${MOUNT_POINT}/extlinux/extlinux.conf"
ok "extlinux.conf injected."

# ---------------------------------------------------------------------------
# Step 8: Show final boot partition contents
# ---------------------------------------------------------------------------
info "Final boot partition contents:"
ls -lh "${MOUNT_POINT}/" 2>/dev/null
echo ""

# ---------------------------------------------------------------------------
# Step 9: Sync and unmount
# ---------------------------------------------------------------------------
info "Syncing ..."
sync
sudo umount "${MOUNT_POINT}"
rmdir "${MOUNT_POINT}"
sudo losetup -d "${LOOP}"
trap - EXIT
ok "Image finalised."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Output image : ${IMG}"
echo "  Size         : $(du -sh "${IMG}" | cut -f1)"
echo ""
echo "  Flash to SD card (Linux):"
echo "    sudo dd if=\"${IMG}\" of=/dev/sdX bs=4M status=progress conv=fsync"
echo "    (replace /dev/sdX with your SD card device — check with lsblk)"
echo ""
echo "  Flash to SD card (Windows):"
echo "    Use Balena Etcher or Rufus — write as raw disk image."
echo "    Do NOT write as partition image."
echo ""
echo "  Insert SD card into Milk-V Jupiter and power on."
echo "============================================================"
