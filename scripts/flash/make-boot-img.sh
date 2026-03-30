#!/usr/bin/env bash
# =============================================================================
# make-boot-img.sh
#
# ⚠️  DEPRECATED / LIMITED USE — READ BEFORE USING  ⚠️
#
# This script produces a 64 MiB FAT32 *partition* image containing only the
# EVL kernel, DTBs, and extlinux.conf.  It does NOT produce a bootable SD card
# image because:
#
#   • It contains NO partition table (GPT/MBR).
#   • It contains NO U-Boot SPL or bootloader binaries.
#   • It contains NO rootfs.
#
# The SpacemiT K1 ROM / FSBL requires U-Boot SPL at a specific raw sector
# offset inside a properly partitioned disk image.  Writing this bare FAT32
# blob to an SD card results in NO BOOT — exactly as observed on Jupiter.
#
# ─────────────────────────────────────────────────────────────────────────────
# CORRECT WORKFLOW
# ─────────────────────────────────────────────────────────────────────────────
# Use make-full-sdcard-img.sh instead, which:
#   1. Copies the full SpacemiT buildroot base image (U-Boot + rootfs included).
#   2. Injects the EVL kernel/DTBs/extlinux.conf into partition 1 of that copy.
#   3. Produces a complete, bootable disk image ready for dd/Etcher.
#
#   bash scripts/flash/make-full-sdcard-img.sh \
#       ~/Downloads/buildroot-k1_rt-sdcard.img \
#       ~/work/build-k1 \
#       ~/Downloads
#
# ─────────────────────────────────────────────────────────────────────────────
# WHEN IS THIS SCRIPT STILL USEFUL?
# ─────────────────────────────────────────────────────────────────────────────
# Only when you already have a working Jupiter SD card and want a standalone
# FAT32 blob to inspect or manually dd onto the first *partition* (not the
# whole disk) of an SD card that already has a valid bootloader at sector 0.
#
# Usage:
#   bash scripts/flash/make-boot-img.sh [build_dir] [output_dir]
#
# Output:
#   evl-boot-k1-YYYYMMDD.img  (64 MiB FAT32 partition image, label EVL_BOOT)
#
# Dependencies:
#   mtools (mmd, mcopy, mdir) — sudo apt-get install mtools
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

KERNEL_IMAGE="${BUILD_DIR}/arch/riscv/boot/Image"
DTB_DIR="${BUILD_DIR}/arch/riscv/boot/dts/spacemit"
EXTLINUX_CONF="${REPO_ROOT}/configs/extlinux.conf"

# ---------------------------------------------------------------------------
# Check dependencies
# ---------------------------------------------------------------------------
if ! command -v mcopy &>/dev/null; then
    info "Installing mtools ..."
    sudo apt-get install -y mtools -qq
fi

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
[[ -f "${KERNEL_IMAGE}" ]] || die "Kernel image not found: ${KERNEL_IMAGE}"
[[ -d "${DTB_DIR}" ]]      || die "DTB directory not found: ${DTB_DIR}"
[[ -d "${OUTPUT_DIR}" ]]   || die "Output directory not found: ${OUTPUT_DIR}"

info "Build dir  : ${BUILD_DIR}"
info "Output     : ${IMG}"
info "Repo root  : ${REPO_ROOT}"

# ---------------------------------------------------------------------------
# Create FAT32 image
# ---------------------------------------------------------------------------
info "Creating 64 MiB FAT32 image ..."
dd if=/dev/zero of="${IMG}" bs=1M count=64 status=none
mkfs.vfat -F 32 -n "EVL_BOOT" "${IMG}" >/dev/null
ok "FAT32 image created."

# ---------------------------------------------------------------------------
# Populate using mtools (no sudo/loop mount needed)
# ---------------------------------------------------------------------------
info "Creating directory structure ..."
mmd -i "${IMG}" ::dtbs
mmd -i "${IMG}" ::dtbs/spacemit
mmd -i "${IMG}" ::extlinux

info "Copying kernel Image ($(du -sh "${KERNEL_IMAGE}" | cut -f1)) ..."
mcopy -i "${IMG}" "${KERNEL_IMAGE}" ::Image
ok "Kernel copied."

info "Copying DTBs ..."
DTB_COUNT=0
for dtb in "${DTB_DIR}"/*.dtb; do
    [[ -f "${dtb}" ]] || continue
    mcopy -i "${IMG}" "${dtb}" "::dtbs/spacemit/$(basename "${dtb}")"
    (( DTB_COUNT++ )) || true
done
if [[ "${DTB_COUNT}" -gt 0 ]]; then
    ok "${DTB_COUNT} DTBs copied."
else
    warn "No DTBs found in ${DTB_DIR} — skipping."
fi

if [[ -f "${EXTLINUX_CONF}" ]]; then
    info "Copying extlinux.conf ..."
    mcopy -i "${IMG}" "${EXTLINUX_CONF}" ::extlinux/extlinux.conf
    ok "extlinux.conf copied."
fi

# ---------------------------------------------------------------------------
# Verify and show contents
# ---------------------------------------------------------------------------
info "Image contents:"
mdir -i "${IMG}" -/ :: 2>/dev/null | grep -v "^$" | head -50

ok "Image ready: ${IMG} ($(du -sh "${IMG}" | cut -f1))"

echo ""
echo "============================================================"
echo "  To flash from Windows — write image to SD card partition:"
echo ""
echo "  Option 1: PowerShell (Admin) via WSL dd:"
echo "    wsl dd if=\"\$(wslpath '${IMG}')\" of=/dev/sdd1 bs=4M"
echo "    (replace sdd1 with your SD card first partition)"
echo ""
echo "  Option 2: Use Rufus or Win32DiskImager"
echo "    Point it at: ${IMG}"
echo "============================================================"
