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

# Give the kernel a moment to create partition device nodes
sleep 1

# ---------------------------------------------------------------------------
# Step 2b: Print partition table for visibility
# ---------------------------------------------------------------------------
info "Partition layout of base image:"
sudo fdisk -l "${LOOP}" 2>/dev/null | grep -E "^Device|^/dev"
echo ""
info "Partition filesystem types (blkid):"
sudo blkid "${LOOP}"p* 2>/dev/null || true
echo ""

# ---------------------------------------------------------------------------
# Step 2c: Auto-detect the FAT32 boot partition (PARTLABEL=bootfs or vfat)
#          SpacemiT/Bianbu images have the layout:
#            p1 fsbl  (raw)    p2 env (raw)  p3 opensbi (raw)  p4 uboot (raw)
#            p5 bootfs (FAT32) p6 rootfs (ext4)
#          buildroot images have:
#            p1 boot (FAT32)   p2 rootfs (ext4)
#          We auto-detect by scanning for the vfat partition.
# ---------------------------------------------------------------------------
BOOT_PART=""
ROOTFS_PART=""

for part in "${LOOP}"p*; do
  [[ -b "${part}" ]] || continue
  FSTYPE=$(sudo blkid -o value -s TYPE "${part}" 2>/dev/null || true)
  PARTLABEL=$(sudo blkid -o value -s PARTLABEL "${part}" 2>/dev/null || true)
  LABEL=$(sudo blkid -o value -s LABEL "${part}" 2>/dev/null || true)

  if [[ "${FSTYPE}" == "vfat" ]]; then
    # Prefer partition explicitly labelled "bootfs" if there are multiple vfat
    if [[ -z "${BOOT_PART}" || "${PARTLABEL,,}" == "bootfs" || "${LABEL,,}" == "bootfs" ]]; then
      BOOT_PART="${part}"
      info "  Detected FAT32 boot partition : ${part} (PARTLABEL=${PARTLABEL} LABEL=${LABEL})"
    fi
  elif [[ "${FSTYPE}" == "ext4" ]]; then
    if [[ -z "${ROOTFS_PART}" || "${PARTLABEL,,}" == "rootfs" || "${LABEL,,}" == "rootfs" ]]; then
      ROOTFS_PART="${part}"
      ROOTFS_UUID=$(sudo blkid -o value -s UUID "${part}" 2>/dev/null || true)
      info "  Detected ext4 rootfs partition: ${part} (UUID=${ROOTFS_UUID} PARTLABEL=${PARTLABEL})"
    fi
  fi
done

if [[ -z "${BOOT_PART}" ]]; then
  sudo losetup -d "${LOOP}" 2>/dev/null || true
  die "No FAT32 (vfat) boot partition found in ${IMG}.
       Run: sudo blkid \$(sudo losetup -Pf --show ${IMG})p*
       to inspect the partition layout manually."
fi

ok "Boot partition : ${BOOT_PART}"
[[ -n "${ROOTFS_PART}" ]] && ok "Rootfs partition: ${ROOTFS_PART} (UUID=${ROOTFS_UUID:-unknown})"
echo ""

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
# Step 4: Read and display original extlinux.conf from base image
#         Extract root= device and initrd path so we can preserve them.
# ---------------------------------------------------------------------------
ORIG_EXTLINUX=""
for try_path in \
    "${MOUNT_POINT}/extlinux/extlinux.conf" \
    "${MOUNT_POINT}/boot/extlinux/extlinux.conf"; do
  if [[ -f "${try_path}" ]]; then
    ORIG_EXTLINUX="${try_path}"
    break
  fi
done

ORIG_ROOT=""
ORIG_INITRD=""
ORIG_FDT=""

if [[ -n "${ORIG_EXTLINUX}" ]]; then
  info "─────────────────────────────────────────────────────"
  info "Original extlinux.conf from base image:"
  cat "${ORIG_EXTLINUX}"
  info "─────────────────────────────────────────────────────"
  echo ""

  # Extract root= value (take the first append line's root=...)
  ORIG_ROOT=$(grep -m1 'root=' "${ORIG_EXTLINUX}" | \
              grep -oE 'root=[^ ]+' | head -1 | sed 's/root=//' || true)

  # Extract initrd path (first initrd line)
  ORIG_INITRD=$(grep -m1 -iE '^\s*initrd' "${ORIG_EXTLINUX}" | \
                awk '{print $2}' || true)

  # Extract fdt/dtb path (first fdt line)
  ORIG_FDT=$(grep -m1 -iE '^\s*fdt\b' "${ORIG_EXTLINUX}" | \
             awk '{print $2}' || true)

  [[ -n "${ORIG_ROOT}" ]]   && info "Detected root device : ${ORIG_ROOT}"
  [[ -n "${ORIG_INITRD}" ]] && info "Detected initrd      : ${ORIG_INITRD}"
  [[ -n "${ORIG_FDT}" ]]    && info "Detected fdt         : ${ORIG_FDT}"
else
  warn "No extlinux.conf found in base image boot partition."
  warn "Will use configs/extlinux.conf from repo unchanged."
fi
echo ""

info "Existing boot partition contents:"
ls -lh "${MOUNT_POINT}/" 2>/dev/null | head -30 || true
echo ""

# ---------------------------------------------------------------------------
# Step 5: Inject EVL kernel
# ---------------------------------------------------------------------------
info "Copying EVL kernel Image ($(du -sh "${KERNEL_IMAGE}" | cut -f1)) ..."
sudo cp "${KERNEL_IMAGE}" "${MOUNT_POINT}/Image"
ok "Kernel injected."

# ---------------------------------------------------------------------------
# Step 6: Inject DTBs
#         Try to place them where the base image's extlinux.conf expects them.
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
# Step 7: Build and inject extlinux.conf
#
# Priority of values used in the generated extlinux.conf:
#   root=    → from base image's original extlinux.conf (if detected),
#              otherwise fall back to repo configs/extlinux.conf value
#   initrd   → from base image's original extlinux.conf (if detected),
#              otherwise omitted
#   fdt      → always /dtbs/spacemit/k1-x_milkv-jupiter.dtb (EVL DTB)
#   console  → always "console=tty1 console=ttyS0,115200" (HDMI + serial)
# ---------------------------------------------------------------------------
info "Building extlinux.conf ..."

# Determine root= value.  Priority (highest to lowest):
#   1. root= from base image's original extlinux.conf  (most accurate)
#   2. UUID= from blkid of the detected ext4 rootfs partition
#   3. Fallback to value in repo configs/extlinux.conf
if [[ -n "${ORIG_ROOT}" ]]; then
  BOOT_ROOT="${ORIG_ROOT}"
  info "  Using root= from base image extlinux.conf: ${BOOT_ROOT}"
elif [[ -n "${ROOTFS_UUID:-}" ]]; then
  BOOT_ROOT="UUID=${ROOTFS_UUID}"
  info "  Using root= from blkid of rootfs partition: ${BOOT_ROOT}"
else
  BOOT_ROOT=$(grep -m1 'root=' "${EXTLINUX_CONF}" | \
              grep -oE 'root=[^ ]+' | head -1 | sed 's/root=//' || echo "/dev/mmcblk0p2")
  warn "  Could not detect root from base image — using fallback: ${BOOT_ROOT}"
fi

# Determine initrd line (optional)
INITRD_LINE=""
if [[ -n "${ORIG_INITRD}" ]]; then
  INITRD_LINE="    initrd ${ORIG_INITRD}"
  info "  Using initrd from base image: ${ORIG_INITRD}"
fi

# Detect additional kernel args from base image (e.g. rd.debug, loglevel, etc.)
ORIG_EXTRA_ARGS=""
if [[ -n "${ORIG_EXTLINUX}" ]]; then
  # Extract everything after 'append' except root=, console=, earlycon=, rootwait, rw
  ORIG_EXTRA_ARGS=$(grep -m1 'append' "${ORIG_EXTLINUX}" | \
    sed 's/.*append//' | \
    sed -E 's/root=[^ ]+//g' | \
    sed -E 's/console=[^ ]+//g' | \
    sed -E 's/earlycon=[^ ]+//g' | \
    sed -E 's/\brootwait\b//g' | \
    sed -E 's/\brw\b//g' | \
    tr -s ' ' | sed 's/^ //' | sed 's/ $//' || true)
  [[ -n "${ORIG_EXTRA_ARGS}" ]] && info "  Extra args from base image: ${ORIG_EXTRA_ARGS}"
fi

# Write the merged extlinux.conf
DEST_EXTLINUX="${MOUNT_POINT}/extlinux/extlinux.conf"
sudo mkdir -p "${MOUNT_POINT}/extlinux"

sudo tee "${DEST_EXTLINUX}" > /dev/null <<EXTLINUX_EOF
# Generated by make-full-sdcard-img.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Base image : $(basename "${BASE_IMAGE}")
# EVL kernel : $(basename "${KERNEL_IMAGE}") — built $(date +%Y-%m-%d)
#
# console=tty1 enables HDMI output.  console=ttyS0,115200 enables serial UART.
# Both are listed so output goes to both simultaneously.

default EVL
timeout 30
prompt 1

label EVL
    menu label SpacemiT K1 + EVL Xenomai4 kernel
    linux /Image
${INITRD_LINE:+${INITRD_LINE}
}    fdt /dtbs/spacemit/k1-x_milkv-jupiter.dtb
    append earlycon=sbi console=tty1 console=ttyS0,115200 root=${BOOT_ROOT} rootwait rw${ORIG_EXTRA_ARGS:+ ${ORIG_EXTRA_ARGS}}
EXTLINUX_EOF

info "Generated extlinux.conf:"
cat "${DEST_EXTLINUX}"
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
