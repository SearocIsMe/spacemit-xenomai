#!/usr/bin/env bash
# =============================================================================
# make-boot-img.sh
# Create a FAT32 boot partition image containing the EVL kernel, DTBs, and
# extlinux.conf. The resulting .img can be written to the SD card's first
# partition from Windows (Rufus, Win32DiskImager, or PowerShell dd).
#
# Usage:
#   bash scripts/flash/make-boot-img.sh [build_dir] [output_dir]
#
# Examples:
#   bash scripts/flash/make-boot-img.sh
#   bash scripts/flash/make-boot-img.sh ~/work/build-k1 /mnt/c/Users/haipeng/Downloads
#
# Output:
#   evl-boot-k1-YYYYMMDD.img  (64 MiB FAT32, label EVL_BOOT)
#
# Windows flashing (PowerShell, Admin):
#   # Write image to SD card first partition using dd:
#   wsl dd if=/mnt/c/Users/haipeng/Downloads/evl-boot-k1-*.img of=\\.\PhysicalDrive1 bs=4M
#   # Or use Rufus / Win32DiskImager to write to the partition directly.
# =============================================================================
set -euo pipefail

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
BUILD_DIR="${1:-${HOME}/work/build-k1}"
OUTPUT_DIR="${2:-/tmp}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

IMG_NAME="evl-boot-k1-$(date +%Y%m%d).img"
IMG="${OUTPUT_DIR}/${IMG_NAME}"
MOUNT=$(mktemp -d /tmp/evl-boot-XXXXXX)

KERNEL_IMAGE="${BUILD_DIR}/arch/riscv/boot/Image"
DTB_DIR="${BUILD_DIR}/arch/riscv/boot/dts/spacemit"
EXTLINUX_CONF="${REPO_ROOT}/configs/extlinux.conf"

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
[[ -f "${KERNEL_IMAGE}" ]] || die "Kernel image not found: ${KERNEL_IMAGE}"
[[ -d "${DTB_DIR}" ]]      || die "DTB directory not found: ${DTB_DIR}"
[[ -d "${OUTPUT_DIR}" ]]   || die "Output directory not found: ${OUTPUT_DIR}"

info "Build dir  : ${BUILD_DIR}"
info "Output     : ${IMG}"
info "Repo root  : ${REPO_ROOT}"

# ---------------------------------------------------------------------------
# Create image
# ---------------------------------------------------------------------------
info "Creating 64 MiB FAT32 image ..."
dd if=/dev/zero of="${IMG}" bs=1M count=64 status=none
mkfs.vfat -F 32 -n "EVL_BOOT" "${IMG}" >/dev/null
ok "FAT32 image created."

# ---------------------------------------------------------------------------
# Mount and populate
# ---------------------------------------------------------------------------
trap "sudo umount '${MOUNT}' 2>/dev/null || true; rmdir '${MOUNT}'" EXIT
sudo mount -o loop "${IMG}" "${MOUNT}"

info "Copying kernel Image ($(du -sh "${KERNEL_IMAGE}" | cut -f1)) ..."
sudo cp "${KERNEL_IMAGE}" "${MOUNT}/Image"
ok "Kernel copied."

info "Copying DTBs ..."
sudo mkdir -p "${MOUNT}/dtbs/spacemit"
DTB_COUNT=$(ls "${DTB_DIR}"/*.dtb 2>/dev/null | wc -l)
if [[ "${DTB_COUNT}" -gt 0 ]]; then
    sudo cp "${DTB_DIR}"/*.dtb "${MOUNT}/dtbs/spacemit/"
    ok "${DTB_COUNT} DTBs copied."
else
    warn "No DTBs found in ${DTB_DIR} — skipping."
fi

if [[ -f "${EXTLINUX_CONF}" ]]; then
    info "Copying extlinux.conf ..."
    sudo mkdir -p "${MOUNT}/extlinux"
    sudo cp "${EXTLINUX_CONF}" "${MOUNT}/extlinux/extlinux.conf"
    ok "extlinux.conf copied."
fi

# ---------------------------------------------------------------------------
# Show contents
# ---------------------------------------------------------------------------
info "Image contents:"
find "${MOUNT}" -type f | sort | while read -r f; do
    printf "  %-50s %s\n" "${f#${MOUNT}/}" "$(du -sh "${f}" | cut -f1)"
done

# ---------------------------------------------------------------------------
# Sync and unmount
# ---------------------------------------------------------------------------
sync
sudo umount "${MOUNT}"
rmdir "${MOUNT}"
trap - EXIT

ok "Image ready: ${IMG} ($(du -sh "${IMG}" | cut -f1))"

echo ""
echo "============================================================"
echo "  To flash from Windows PowerShell (Admin):"
echo "  1. Find SD card disk number:"
echo "     Get-Disk | Where-Object BusType -eq USB"
echo "  2. Write image to first partition:"
echo "     wsl dd if=\"\$(wslpath '${IMG}')\" of=/dev/sdd1 bs=4M"
echo "     (replace sdd1 with your SD card partition)"
echo "  Or use Rufus / Win32DiskImager to write the .img file."
echo "============================================================"
