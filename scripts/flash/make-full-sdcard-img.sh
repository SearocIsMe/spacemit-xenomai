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
#    ~/work/jupiter-linux/output/k1_v2/images/bianbu-linux-k1_v2-sdcard.img \
#    ~/work/build-k1
#    /tmp

# sudo ./scripts/flash/make-full-sdcard-img.sh ~/work/jupiter-linux/output/k1_v2/images/bianbu-linux-k1_v2-sdcard.img ~/work/build-k1 ~/work


# Arguments:
#   base_image   Full SpacemiT buildroot SD card image to use as the base.
#                Download from:
#                  https://www.spacemit.com/community/document/info?lang=zh
#                    &nodepath=software/SDK/buildroot/k1_buildroot/source.md
#                Example: ~/Downloads/buildroot-k1_rt-sdcard.img
#                also can build it out as based
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
#
# Bianbu / SpacemiT U-Boot loads DTBs from the BOOTFS ROOT (flat layout), NOT
# from a subdirectory.  e.g. U-Boot loads /k1-x_milkv-jupiter.dtb directly.
# We copy the Jupiter DTB to the root AND also maintain a dtbs/spacemit/
# subdirectory as a fallback for extlinux-based boot.
# ---------------------------------------------------------------------------
JUPITER_DTB="${DTB_DIR}/k1-x_milkv-jupiter.dtb"
DTB_COUNT=0

if [[ -f "${JUPITER_DTB}" ]]; then
  info "Copying Jupiter DTB to bootfs root (U-Boot flat layout) ..."
  sudo cp "${JUPITER_DTB}" "${MOUNT_POINT}/k1-x_milkv-jupiter.dtb"
  ok "Copied: k1-x_milkv-jupiter.dtb → bootfs root"
  (( DTB_COUNT++ )) || true
else
  warn "Jupiter DTB not found: ${JUPITER_DTB}"
  warn "Checking for any available SpacemiT DTB ..."
fi

# Copy all DTBs to dtbs/spacemit/ as well (extlinux fallback / future use)
sudo mkdir -p "${MOUNT_POINT}/dtbs/spacemit"
for dtb in "${DTB_DIR}"/*.dtb; do
  [[ -f "${dtb}" ]] || continue
  sudo cp "${dtb}" "${MOUNT_POINT}/dtbs/spacemit/$(basename "${dtb}")"
  (( DTB_COUNT++ )) || true
done

if [[ "${DTB_COUNT}" -gt 0 ]]; then
  ok "${DTB_COUNT} DTB file(s) processed."
else
  warn "No DTBs found in ${DTB_DIR} — skipping."
fi

# ---------------------------------------------------------------------------
# Step 7: Patch env_k1-x.txt for correct plain Image boot
#
# The Bianbu U-Boot environment text file (env_k1-x.txt) is loaded from the
# FAT32 bootfs partition and merged into the running U-Boot environment via
# "env import -t".  Variables here override the compiled-in defaults stored
# in the env partition (p2).
#
# What we change and why:
#
# knl_name=Image
#   The p2 env default is knl_name=Image.itb (FIT image).  We replace the
#   FIT image with a plain uncompressed Image, so we must override this.
#   (The original env_k1-x.txt already sets knl_name=Image — we keep it.)
#
# kernel_addr_r=0x200000  (KEEP the original value)
#   The original Bianbu env uses 0x200000.  Our 36MB EVL kernel loaded at
#   0x200000 ends at ~0x2600000, well below the splash BMP at 0x11000000.
#   No overlap.  We keep 0x200000 to match the working original image.
#   NOTE: U-Boot's start_kernel uses "booti" for plain Image (not bootm),
#   so the load address just needs to be in free RAM — 0x200000 is fine.
#
# console=ttyS0,115200  (KEEP — do not add console=tty1)
#   The SpacemiT DRM driver initialises late.  Adding console=tty1 before
#   the DRM driver is ready causes no output at all.  Keep UART-only for
#   now; once SSH access is confirmed we can add tty1 back.
# ---------------------------------------------------------------------------
ENV_FILE="${MOUNT_POINT}/env_k1-x.txt"
if [[ -f "${ENV_FILE}" ]]; then
  info "Original env_k1-x.txt:"
  sudo cat "${ENV_FILE}"
  echo ""

  # Ensure knl_name=Image (not Image.itb)
  if sudo grep -q 'knl_name=Image\.itb' "${ENV_FILE}" 2>/dev/null; then
    sudo sed -i 's|knl_name=Image\.itb|knl_name=Image|g' "${ENV_FILE}"
    ok "Fixed knl_name: Image.itb → Image"
  else
    ok "knl_name already set to Image — no change needed"
  fi

  # Ensure kernel_addr_r=0x200000 (original value — do NOT change to 0x20000000)
  # Our 36MB kernel at 0x200000 ends at ~0x2600000, safely below splash at 0x11000000.
  if ! sudo grep -q 'kernel_addr_r' "${ENV_FILE}" 2>/dev/null; then
    echo "kernel_addr_r=0x200000" | sudo tee -a "${ENV_FILE}" > /dev/null
    ok "Added kernel_addr_r=0x200000"
  elif sudo grep -q 'kernel_addr_r=0x20000000\|kernel_addr_r=0x10000000' "${ENV_FILE}" 2>/dev/null; then
    sudo sed -i 's|kernel_addr_r=0x[0-9a-fA-F]*|kernel_addr_r=0x200000|g' "${ENV_FILE}"
    ok "Restored kernel_addr_r to 0x200000 (original working value)"
  else
    ok "kernel_addr_r already set — no change needed"
  fi

  info "Updated env_k1-x.txt:"
  sudo cat "${ENV_FILE}"
  echo ""
else
  warn "env_k1-x.txt not found in bootfs — cannot patch boot parameters."
  warn "HDMI output may not be visible; use serial UART to debug."
fi

# ---------------------------------------------------------------------------
# Step 7b: initramfs — Bianbu uses initramfs-generic.img for rootfs mounting.
#          We do NOT replace it; the existing one from the base image is kept.
#          Note: if the EVL kernel has different module versions from the
#          Bianbu initramfs, rootfs pivot may fail — see docs/porting-notes.md
# ---------------------------------------------------------------------------
if [[ -f "${MOUNT_POINT}/initramfs-generic.img" ]]; then
  INITRD_SIZE=$(du -sh "${MOUNT_POINT}/initramfs-generic.img" | cut -f1)
  ok "initramfs-generic.img preserved from base image (${INITRD_SIZE}) — NOT replaced."
else
  warn "initramfs-generic.img not found in bootfs — Bianbu rootfs mount may fail."
fi

# ---------------------------------------------------------------------------
# Step 8: Show final boot partition contents
# ---------------------------------------------------------------------------
info "Final boot partition contents:"
ls -lh "${MOUNT_POINT}/" 2>/dev/null
echo ""

# ---------------------------------------------------------------------------
# Step 9: Sync and unmount
# ---------------------------------------------------------------------------
info "Syncing bootfs ..."
sync
sudo umount "${MOUNT_POINT}"
rmdir "${MOUNT_POINT}"
ok "Bootfs unmounted."

# ---------------------------------------------------------------------------
# Step 10: Inject EVL kernel modules into rootfs (ext4 partition)
#
# The Bianbu initramfs loads modules from lib/modules/<kernel-version>/
# on the rootfs partition.  Our EVL kernel must have the same version string
# as the modules directory name, otherwise module loading fails silently and
# the boot hangs after initramfs pivot_root.
#
# IMPORTANT: The EVL kernel MUST be built with CONFIG_LOCALVERSION=""
# (set in configs/k1_evl_defconfig) so its version is "6.6.63" not "6.6.63+".
# ---------------------------------------------------------------------------
MODULES_DIR="${BUILD_DIR}/modules_install"

if [[ -n "${ROOTFS_PART}" && -b "${ROOTFS_PART}" ]]; then
  if [[ -d "${MODULES_DIR}" ]]; then

    # -------------------------------------------------------------------------
    # Pre-flight: check how much space the new modules need vs what's available
    # in the rootfs partition.  If there isn't enough room, grow the image file
    # and resize the ext4 filesystem before mounting.
    # -------------------------------------------------------------------------
    EVL_MOD_VER=$(ls "${MODULES_DIR}/lib/modules/" 2>/dev/null | head -1)
    if [[ -n "${EVL_MOD_VER}" ]]; then
      NEW_MOD_KB=$(du -sk "${MODULES_DIR}/lib/modules/${EVL_MOD_VER}" | cut -f1)
      # Get current free space on the rootfs partition (without mounting)
      ROOTFS_FREE_KB=$(sudo tune2fs -l "${ROOTFS_PART}" 2>/dev/null \
        | awk '/Free blocks/{fb=$3} /Block size/{bs=$3} END{printf "%d", fb*bs/1024}')

      info "New modules size : $((NEW_MOD_KB / 1024)) MB"
      info "Rootfs free space: $((ROOTFS_FREE_KB / 1024)) MB"

      # We need at least NEW_MOD_KB + 64MB headroom
      NEEDED_KB=$(( NEW_MOD_KB + 65536 ))
      if [[ "${ROOTFS_FREE_KB}" -lt "${NEEDED_KB}" ]]; then
        GROW_MB=$(( (NEEDED_KB - ROOTFS_FREE_KB) / 1024 + 256 ))
        warn "Rootfs partition too small — growing image by ${GROW_MB} MB ..."

        # 1. Detach loop device so we can resize the image file
        sudo losetup -d "${LOOP}" 2>/dev/null || true
        trap - EXIT

        # 2. Extend the image file
        dd if=/dev/zero bs=1M count="${GROW_MB}" >> "${IMG}" 2>/dev/null
        ok "Image file extended by ${GROW_MB} MB."

        # 3. Re-attach loop device
        LOOP=$(sudo losetup -Pf --show "${IMG}")
        LOOP_REF="${LOOP}"
        trap cleanup EXIT
        sleep 1

        # Re-resolve partition device nodes after re-attach
        ROOTFS_PART="${LOOP}p$(echo "${ROOTFS_PART}" | grep -oE '[0-9]+$')"
        info "Re-attached loop device: ${LOOP}, rootfs: ${ROOTFS_PART}"

        # 4. Grow the partition table entry to fill the new space
        #    parted resizepart <partnum> 100%
        ROOTFS_PARTNUM=$(echo "${ROOTFS_PART}" | grep -oE '[0-9]+$')
        sudo parted -s "${LOOP}" resizepart "${ROOTFS_PARTNUM}" 100% 2>/dev/null \
          && ok "Partition ${ROOTFS_PARTNUM} extended to fill new space." \
          || warn "parted resizepart failed — trying without (resize2fs may still work)."
        sleep 1

        # 5. Check and resize the ext4 filesystem
        sudo e2fsck -f -y "${ROOTFS_PART}" 2>/dev/null || true
        sudo resize2fs "${ROOTFS_PART}" 2>/dev/null \
          && ok "ext4 filesystem resized to fill partition." \
          || warn "resize2fs failed — proceeding anyway (may still have enough space)."
      else
        info "Rootfs has sufficient free space — no resize needed."
      fi
    fi

    ROOTFS_MOUNT=$(mktemp -d /tmp/evl-rootfs-XXXXXX)

    info "Mounting rootfs partition ${ROOTFS_PART} ..."
    sudo mount "${ROOTFS_PART}" "${ROOTFS_MOUNT}"

    # Detect the kernel version the modules were installed under
    EVL_MOD_VER=$(ls "${MODULES_DIR}/lib/modules/" 2>/dev/null | head -1)
    if [[ -n "${EVL_MOD_VER}" ]]; then
      info "Injecting EVL modules for kernel ${EVL_MOD_VER} into rootfs ..."

      # Remove existing modules directory for this version to free space first.
      if [[ -d "${ROOTFS_MOUNT}/lib/modules/${EVL_MOD_VER}" ]]; then
        sudo rm -rf "${ROOTFS_MOUNT}/lib/modules/${EVL_MOD_VER}"
        info "  Removed old modules/${EVL_MOD_VER} to free space."
      fi

      sudo mkdir -p "${ROOTFS_MOUNT}/lib/modules"
      sudo cp -a "${MODULES_DIR}/lib/modules/${EVL_MOD_VER}" \
                 "${ROOTFS_MOUNT}/lib/modules/"
      ok "EVL modules (${EVL_MOD_VER}) injected into rootfs."
    else
      warn "No modules found in ${MODULES_DIR}/lib/modules/ — skipping rootfs module injection."
      warn "Run: make modules_install INSTALL_MOD_PATH=\${BUILD_DIR}/modules_install"
    fi

    # -------------------------------------------------------------------------
    # Step 10b: Rootfs post-processing for EVL compatibility
    #
    # The Bianbu buildroot rootfs needs a few tweaks to work with our EVL
    # kernel:
    #
    # 1. Disable Weston autostart
    #    Weston uses MESA_LOADER_DRIVER_OVERRIDE=pvr (PowerVR GPU).  The
    #    PowerVR kernel driver is not available in our EVL kernel build.
    #    Weston crashes immediately on start, causing a display crash loop.
    #    We disable it by removing the execute bit from S30weston-setup.sh.
    #    Re-enable later with: chmod +x /etc/init.d/S30weston-setup.sh
    #
    # 2. Set root password to a known value
    #    The original Bianbu image has an unknown root password.  We set it
    #    to "root" so SSH access works for first-boot diagnosis.
    #    Change it after first login: passwd root
    #
    # 3. Add ttyS0 getty for serial console access
    #    Adds a login prompt on UART0 (115200 baud) so a serial cable can
    #    be used for diagnosis if SSH is not available.
    # -------------------------------------------------------------------------
    info "Applying rootfs post-processing for EVL compatibility ..."

    # 1. Disable Weston (PowerVR GPU not available with EVL kernel)
    WESTON_INIT="${ROOTFS_MOUNT}/etc/init.d/S30weston-setup.sh"
    if [[ -f "${WESTON_INIT}" ]]; then
      sudo chmod -x "${WESTON_INIT}"
      ok "Weston autostart disabled (S30weston-setup.sh — chmod -x)."
      ok "  Re-enable after confirming EVL works: chmod +x /etc/init.d/S30weston-setup.sh"
    else
      info "S30weston-setup.sh not found — skipping Weston disable."
    fi

    # 2. Set root password to "root" for first-boot SSH access
    SHADOW_FILE="${ROOTFS_MOUNT}/etc/shadow"
    if [[ -f "${SHADOW_FILE}" ]]; then
      # Generate SHA-512 hash for "root" using Python (available on most hosts)
      ROOT_HASH=$(python3 -c \
        "import crypt; print(crypt.crypt('root', crypt.mksalt(crypt.METHOD_SHA512)))" \
        2>/dev/null || true)
      if [[ -n "${ROOT_HASH}" ]]; then
        sudo sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "${SHADOW_FILE}"
        ok "Root password set to 'root' for first-boot SSH access."
        ok "  Change after login: passwd root"
      else
        warn "Could not generate password hash (python3 not available) — root password unchanged."
      fi
    else
      warn "/etc/shadow not found in rootfs — cannot set root password."
    fi

    # 3. Add ttyS0 getty for serial console access
    INITTAB="${ROOTFS_MOUNT}/etc/inittab"
    if [[ -f "${INITTAB}" ]]; then
      if ! sudo grep -q 'ttyS0' "${INITTAB}" 2>/dev/null; then
        echo "ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100" | \
          sudo tee -a "${INITTAB}" > /dev/null
        ok "Added ttyS0 getty to /etc/inittab (serial console at 115200 baud)."
      else
        ok "ttyS0 getty already present in /etc/inittab."
      fi
    else
      warn "/etc/inittab not found in rootfs — cannot add ttyS0 getty."
    fi

    sync
    sudo umount "${ROOTFS_MOUNT}"
    rmdir "${ROOTFS_MOUNT}"
    ok "Rootfs unmounted."
  else
    warn "Modules directory not found: ${MODULES_DIR}"
    warn "Run scripts/build/03-build-kernel.sh to build and install modules first."
    warn "Without correct modules, initramfs may fail to load kernel drivers."
  fi
else
  warn "No ext4 rootfs partition detected — skipping module injection."
fi

# ---------------------------------------------------------------------------
# Detach loop device
# ---------------------------------------------------------------------------
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
echo "  IMPORTANT: Before flashing, verify the kernel version:"
echo "    strings ${BUILD_DIR}/arch/riscv/boot/Image | grep '^Linux version'"
echo "  It must report '6.6.63' (no + suffix) to match the Bianbu initramfs."
echo "  If it shows '6.6.63+', rebuild the kernel — CONFIG_LOCALVERSION=\"\""
echo "  is now set in configs/k1_evl_defconfig."
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
