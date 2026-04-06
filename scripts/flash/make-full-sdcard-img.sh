#!/usr/bin/env bash
# =============================================================================
# make-full-sdcard-img.sh
#
# Produce a COMPLETE, BOOTABLE SD card image for Milk-V Jupiter by:
#   1. Copying a SpacemiT/buildroot base image (which contains U-Boot SPL,
#      partition table, and rootfs) verbatim.
#   2. Mounting the FAT32 boot partition (p1) from that copy via a loop device.
#   3. Replacing the kernel Image, DTBs, extlinux.conf, and env_k1-x.txt with
#      the freshly built EVL-patched versions.
#   4. Injecting EVL kernel modules into the rootfs (ext4) partition.
#   5. Patching the rootfs for EVL compatibility (disable Weston, set passwords,
#      add serial/HDMI getty).
#
# The result is a drop-in replacement for buildroot-k1_rt-sdcard.img — flash it
# to an SD card with dd/Balena Etcher/Rufus and it will boot on Jupiter.
#
# Usage:
#   sudo bash scripts/flash/make-full-sdcard-img.sh <base_image> [build_dir] [output_dir]
#
#   bash scripts/flash/make-full-sdcard-img.sh \
#    <repo>/.build/jupiter-linux/output/k1_v2/images/bianbu-linux-k1_v2-sdcard.img \
#    <repo>/.build/build-k1 \
#    <repo>/.build/images
#
# Environment knobs:
#   TEST_PROFILE   Preset for staged boot testing. One of:
#                  kernel-only  (default)
#                  kernel-modules
#                  env-debug
#                  boot-debug
#                  full-evl
#   IMAGE_TAG      Optional extra suffix in output filename.
#
# Arguments:
#   base_image   Full SpacemiT buildroot SD card image to use as the base.
#                Download from:
#                  https://www.spacemit.com/community/document/info?lang=zh
#                    &nodepath=software/SDK/buildroot/k1_buildroot/source.md
#                Example: ~/Downloads/buildroot-k1_rt-sdcard.img
#                Also obtainable by running scripts/build/04-build-sdk.sh
#
#   build_dir    Kernel build output directory (default: <repo>/.build/build-k1)
#                Must contain:
#                  arch/riscv/boot/Image
#                  arch/riscv/boot/dts/spacemit/*.dtb
#                  modules_install/lib/modules/<version>/
#
#   output_dir   Where to write the finished image (default: /tmp)
#
# Output:
#   evl-sdcard-k1-YYYYMMDD.img  — complete bootable SD card image
#
# Dependencies:
#   util-linux  (losetup, lsblk, blkid, tune2fs)
#   mount/umount, e2fsck, resize2fs
#   gdisk       (sgdisk, for GPT repair/resize after image growth)
#   sudo  — required for loop/mount operations
#
# Flash the output image to an SD card:
#   Linux:   sudo dd if=evl-sdcard-k1-*.img of=/dev/sdX bs=4M status=progress conv=fsync
#   Windows: use Balena Etcher or Rufus (write as raw disk image, NOT partition)
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
sep()  { echo -e "\033[1;36m────────────────────────────────────────────────────\033[0m"; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_IMAGE="${1:-}"
BUILD_DIR="${2:-${REPO_ROOT}/.build/build-k1}"
OUTPUT_DIR="${3:-${REPO_ROOT}/.build/images}"
BUILD_ENV_FILE="${REPO_ROOT}/scripts/build/env.sh"
TEST_PROFILE="${TEST_PROFILE:-kernel-only}"
PRESERVE_BOOTFLOW="${PRESERVE_BOOTFLOW:-1}"
PATCH_ROOTFS="${PATCH_ROOTFS:-0}"
INJECT_MODULES="${INJECT_MODULES:-0}"
PATCH_EXTLINUX="${PATCH_EXTLINUX:-0}"
PATCH_ENV="${PATCH_ENV:-0}"
PATCH_INITRD="${PATCH_INITRD:-0}"
IMAGE_TAG="${IMAGE_TAG:-}"

case "${TEST_PROFILE}" in
  kernel-only)
    PRESERVE_BOOTFLOW=1
    PATCH_EXTLINUX=0
    PATCH_ENV=0
    PATCH_INITRD=0
    INJECT_MODULES=0
    PATCH_ROOTFS=0
    ;;
  kernel-modules)
    PRESERVE_BOOTFLOW=1
    PATCH_EXTLINUX=0
    PATCH_ENV=0
    PATCH_INITRD=0
    INJECT_MODULES=1
    PATCH_ROOTFS=0
    ;;
  env-debug)
    PRESERVE_BOOTFLOW=0
    PATCH_EXTLINUX=0
    PATCH_ENV=1
    PATCH_INITRD=0
    INJECT_MODULES=0
    PATCH_ROOTFS=0
    ;;
  boot-debug)
    PRESERVE_BOOTFLOW=0
    PATCH_EXTLINUX=1
    PATCH_ENV=1
    PATCH_INITRD=1
    INJECT_MODULES=0
    PATCH_ROOTFS=0
    ;;
  full-evl)
    PRESERVE_BOOTFLOW=0
    PATCH_EXTLINUX=1
    PATCH_ENV=1
    PATCH_INITRD=1
    INJECT_MODULES=1
    PATCH_ROOTFS=1
    ;;
  *)
    die "Unknown TEST_PROFILE='${TEST_PROFILE}'. Use: kernel-only, kernel-modules, env-debug, boot-debug, full-evl"
    ;;
esac

if [[ -z "${BASE_IMAGE}" ]]; then
  echo ""
  echo "Usage: $0 <base_image> [build_dir] [output_dir]"
  echo ""
  echo "  base_image  SpacemiT buildroot full disk image (e.g. buildroot-k1_rt-sdcard.img)"
  echo "  build_dir   EVL kernel build output dir (default: <repo>/.build/build-k1)"
  echo "  output_dir  Where to write the finished image (default: <repo>/.build/images)"
  echo ""
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
[[ -f "${BASE_IMAGE}" ]]   || die "Base image not found: ${BASE_IMAGE}"

KERNEL_IMAGE="${BUILD_DIR}/arch/riscv/boot/Image"
DTB_DIR="${BUILD_DIR}/arch/riscv/boot/dts/spacemit"
EXTLINUX_TMPL="${REPO_ROOT}/configs/extlinux.conf"
MODULES_DIR="${BUILD_DIR}/modules_install"

[[ -f "${KERNEL_IMAGE}" ]]  || die "Kernel image not found: ${KERNEL_IMAGE}
       Run scripts/build/03-build-kernel.sh first."
[[ -d "${DTB_DIR}" ]]       || die "DTB directory not found: ${DTB_DIR}"
[[ -f "${EXTLINUX_TMPL}" ]] || die "extlinux.conf template not found: ${EXTLINUX_TMPL}"
mkdir -p "${OUTPUT_DIR}"
[[ -d "${OUTPUT_DIR}" ]]    || die "Output directory not found: ${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Verify the kernel version string has no trailing '+' before we start
# ---------------------------------------------------------------------------
sep
ACTUAL_VER=$(strings "${KERNEL_IMAGE}" 2>/dev/null | \
             grep "^Linux version" | head -1 | awk '{print $3}')
info "Kernel image version: ${ACTUAL_VER}"
if [[ "${ACTUAL_VER}" == *"+"* ]]; then
  die "Kernel version has trailing '+': ${ACTUAL_VER}
       The Bianbu initramfs expects lib/modules/${ACTUAL_VER%+*} (no + suffix).
       Rebuild the kernel with: touch \${KERNEL_DIR}/.scmversion
       Then re-run: bash scripts/build/03-build-kernel.sh"
fi
ok "Kernel version '${ACTUAL_VER}' has no '+' suffix — good."

# ---------------------------------------------------------------------------
# Verify module version matches kernel version
# ---------------------------------------------------------------------------
EVL_MOD_VER=$(ls "${MODULES_DIR}/lib/modules/" 2>/dev/null | head -1 || true)
if [[ -z "${EVL_MOD_VER}" ]]; then
  die "No modules found in ${MODULES_DIR}/lib/modules/
       Run scripts/build/03-build-kernel.sh to build and install modules first.
       Without correct modules, initramfs will fail to load kernel drivers
       and the board will hang."
fi
if [[ "${EVL_MOD_VER}" != "${ACTUAL_VER}" ]]; then
  die "MODULE VERSION MISMATCH:
       Kernel image reports : ${ACTUAL_VER}
       Modules directory    : ${EVL_MOD_VER}
       The initramfs will look for lib/modules/${ACTUAL_VER} and FAIL.
       Rebuild the kernel and modules:
         bash scripts/build/03-build-kernel.sh
       Then re-run this script."
fi
ok "Module version '${EVL_MOD_VER}' matches kernel version — good."
sep

IMG_SUFFIX="${TEST_PROFILE}"
if [[ -n "${IMAGE_TAG}" ]]; then
  IMG_SUFFIX="${IMG_SUFFIX}-${IMAGE_TAG}"
fi
IMG_NAME="evl-sdcard-k1-${IMG_SUFFIX}-$(date +%Y%m%d).img"
IMG="${OUTPUT_DIR}/${IMG_NAME}"

info "Base image : ${BASE_IMAGE} ($(du -sh "${BASE_IMAGE}" | cut -f1))"
info "Build dir  : ${BUILD_DIR}"
info "Kernel     : ${KERNEL_IMAGE} ($(du -sh "${KERNEL_IMAGE}" | cut -f1))"
info "Modules    : ${MODULES_DIR}/lib/modules/${EVL_MOD_VER}"
info "Output     : ${IMG}"
info "Profile    : ${TEST_PROFILE}"
info "Bootflow   : $([[ "${PRESERVE_BOOTFLOW}" == "1" ]] && echo 'preserve base image boot config' || echo 'rewrite boot config')"
info "Rootfs mods : $([[ "${PATCH_ROOTFS}" == "1" ]] && echo 'enabled' || echo 'disabled')"
info "Modules    : $([[ "${INJECT_MODULES}" == "1" ]] && echo 'inject into rootfs' || echo 'preserve base rootfs modules')"
info "Boot files : extlinux=$([[ "${PATCH_EXTLINUX}" == "1" ]] && echo on || echo off) env=$([[ "${PATCH_ENV}" == "1" ]] && echo on || echo off) initrd=$([[ "${PATCH_INITRD}" == "1" ]] && echo on || echo off)"
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
# Step 2c: Auto-detect the FAT32 boot partition and ext4 rootfs partition.
#          SpacemiT/Bianbu images have the layout:
#            p1 fsbl  (raw)    p2 env (raw)  p3 opensbi (raw)  p4 uboot (raw)
#            p5 bootfs (FAT32) p6 rootfs (ext4)
#          buildroot images have:
#            p1 boot (FAT32)   p2 rootfs (ext4)
#          We auto-detect by scanning for the vfat/ext4 partition.
# ---------------------------------------------------------------------------
BOOT_PART=""
ROOTFS_PART=""
ROOTFS_UUID=""
ENV_PART=""

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

# Detect the raw U-Boot environment partition in Bianbu images.
# The official SpacemiT layout is:
#   p1 fsbl, p2 env, p3 opensbi, p4 uboot, p5 bootfs, p6 rootfs
# We only touch it when the FAT boot partition is not p1, which avoids
# treating simple two-partition images as if they had a raw env slot.
if [[ -b "${LOOP}p2" && "${BOOT_PART}" != "${LOOP}p1" ]]; then
  ENV_PART="${LOOP}p2"
  info "  Detected raw U-Boot env partition: ${ENV_PART}"
fi

if [[ -z "${BOOT_PART}" ]]; then
  sudo losetup -d "${LOOP}" 2>/dev/null || true
  die "No FAT32 (vfat) boot partition found in ${IMG}.
       Run: sudo blkid \$(sudo losetup -Pf --show ${IMG})p*
       to inspect the partition layout manually."
fi

ok "Boot partition : ${BOOT_PART}"
[[ -n "${ROOTFS_PART}" ]] && ok "Rootfs partition: ${ROOTFS_PART} (UUID=${ROOTFS_UUID:-unknown})"
[[ -n "${ENV_PART}" ]] && ok "Env partition   : ${ENV_PART}"
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
# Step 4: Read and display original extlinux.conf from base image.
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
  sep
  info "Original extlinux.conf from base image (${ORIG_EXTLINUX}):"
  cat "${ORIG_EXTLINUX}"
  sep
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
  warn "Will generate extlinux.conf from template with default root=/dev/mmcblk0p2."
  warn "This may need to be corrected if the rootfs UUID differs."
fi
echo ""

info "Existing boot partition contents:"
ls -lh "${MOUNT_POINT}/" 2>/dev/null | head -30 || true
echo ""

# ---------------------------------------------------------------------------
# Step 5: Inject EVL kernel Image
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

if [[ "${PRESERVE_BOOTFLOW}" == "1" ]]; then
  info "Preserving base image bootflow files: extlinux.conf, env_k1-x.txt, initramfs-generic.img"
else
  if [[ "${PATCH_EXTLINUX}" == "1" ]]; then
    # -----------------------------------------------------------------------
    # Step 7: Generate and write extlinux.conf to bootfs
    # -----------------------------------------------------------------------
    sep
    info "Generating EVL extlinux.conf from template ..."

    if [[ -n "${ORIG_ROOT}" ]]; then
      EFFECTIVE_ROOT="${ORIG_ROOT}"
      info "Using root device from base image: ${EFFECTIVE_ROOT}"
    elif [[ -n "${ROOTFS_UUID}" ]]; then
      EFFECTIVE_ROOT="UUID=${ROOTFS_UUID}"
      info "Using detected rootfs UUID: ${EFFECTIVE_ROOT}"
    else
      EFFECTIVE_ROOT="/dev/mmcblk0p2"
      warn "Could not detect root device — falling back to: ${EFFECTIVE_ROOT}"
      warn "Edit /extlinux/extlinux.conf on the SD card if this is wrong."
    fi

    TMP_EXTLINUX=$(mktemp /tmp/extlinux-XXXXXX.conf)
    cp "${EXTLINUX_TMPL}" "${TMP_EXTLINUX}"
    sed -i "s|ROOT_PLACEHOLDER|${EFFECTIVE_ROOT}|g" "${TMP_EXTLINUX}"

    if [[ -n "${ORIG_INITRD}" ]]; then
      if grep -qE '^\s*#\s*initrd' "${TMP_EXTLINUX}"; then
        sed -i "s|^\s*#\s*initrd.*|    initrd ${ORIG_INITRD}|" "${TMP_EXTLINUX}"
        info "Enabled initrd line: ${ORIG_INITRD}"
      elif grep -qiE '^\s*initrd' "${TMP_EXTLINUX}"; then
        sed -i "s|^\s*initrd.*|    initrd ${ORIG_INITRD}|i" "${TMP_EXTLINUX}"
        info "Updated initrd line: ${ORIG_INITRD}"
      else
        sed -i "/^\s*fdt\b/a\\    initrd ${ORIG_INITRD}" "${TMP_EXTLINUX}"
        info "Appended initrd line: ${ORIG_INITRD}"
      fi
    else
      info "No initrd in base image — initrd line stays commented out."
    fi

    sep
    info "Final extlinux.conf to be written:"
    cat "${TMP_EXTLINUX}"
    sep
    echo ""

    EXTLINUX_WRITTEN=0
    for ext_dir in \
        "${MOUNT_POINT}/extlinux" \
        "${MOUNT_POINT}/boot/extlinux"; do
      sudo mkdir -p "${ext_dir}"
      sudo cp "${TMP_EXTLINUX}" "${ext_dir}/extlinux.conf"
      ok "Written: ${ext_dir}/extlinux.conf"
      EXTLINUX_WRITTEN=$(( EXTLINUX_WRITTEN + 1 ))
    done

    rm -f "${TMP_EXTLINUX}"
    ok "extlinux.conf written to ${EXTLINUX_WRITTEN} location(s) in bootfs."
    echo ""
  else
    info "Preserving base image extlinux.conf"
  fi

  # -------------------------------------------------------------------------
  # Step 8: Patch env_k1-x.txt for plain Image boot
  # -------------------------------------------------------------------------
  ENV_FILE="${MOUNT_POINT}/env_k1-x.txt"
  if [[ "${PATCH_ENV}" != "1" ]]; then
    info "Preserving base image env_k1-x.txt"
  elif [[ -n "${ENV_PART}" ]]; then
    ENV_SIZE=$(sudo blockdev --getsize64 "${ENV_PART}")
    ENV_TXT=$(mktemp /tmp/uboot-env-XXXXXX.txt)
    ENV_BIN=$(mktemp /tmp/uboot-env-XXXXXX.bin)
    MKENVIMAGE=""

    if [[ -f "${BUILD_ENV_FILE}" ]]; then
      # shellcheck disable=SC1090
      source "${BUILD_ENV_FILE}"
      if [[ -n "${WORK_DIR:-}" && -x "${WORK_DIR}/jupiter-linux/output/k1_v2/build/uboot-custom/tools/mkenvimage" ]]; then
        MKENVIMAGE="${WORK_DIR}/jupiter-linux/output/k1_v2/build/uboot-custom/tools/mkenvimage"
      fi
    fi

    if [[ -z "${MKENVIMAGE}" ]]; then
      for candidate in \
        "/home/${SUDO_USER:-}/work/jupiter-linux/output/k1_v2/build/uboot-custom/tools/mkenvimage" \
        "/home/${USER}/work/jupiter-linux/output/k1_v2/build/uboot-custom/tools/mkenvimage"; do
        if [[ -x "${candidate}" ]]; then
          MKENVIMAGE="${candidate}"
          break
        fi
      done
    fi

    if [[ -z "${MKENVIMAGE}" ]] && command -v mkenvimage >/dev/null 2>&1; then
      MKENVIMAGE="$(command -v mkenvimage)"
    fi

    [[ -n "${MKENVIMAGE}" && -x "${MKENVIMAGE}" ]] || \
      die "mkenvimage not found. Checked ${WORK_DIR:-unset}/jupiter-linux/... and PATH."

    info "Extracting active U-Boot env from ${ENV_PART} ..."
    sudo dd if="${ENV_PART}" bs=1 count="${ENV_SIZE}" status=none | \
      tail -c +5 | tr '\000' '\n' | sed -e '/^\s*$/d' > "${ENV_TXT}"

    sep
    info "Original U-Boot env (from raw env partition):"
    sed -n '1,120p' "${ENV_TXT}"
    sep
    echo ""

    if grep -q '^knl_name=Image\.itb$' "${ENV_TXT}"; then
      sed -i 's|^knl_name=Image\.itb$|knl_name=Image|g' "${ENV_TXT}"
      ok "Fixed knl_name in raw env: Image.itb -> Image"
    else
      ok "knl_name already set to Image in raw env"
    fi

    if ! grep -q '^kernel_addr_r=' "${ENV_TXT}"; then
      printf '%s\n' 'kernel_addr_r=0x200000' >> "${ENV_TXT}"
      ok "Added kernel_addr_r=0x200000 to raw env"
    elif grep -q '^kernel_addr_r=0x20000000$\|^kernel_addr_r=0x10000000$' "${ENV_TXT}"; then
      sed -i 's|^kernel_addr_r=0x[0-9a-fA-F]*$|kernel_addr_r=0x200000|g' "${ENV_TXT}"
      ok "Restored kernel_addr_r to 0x200000 in raw env"
    else
      ok "kernel_addr_r already set in raw env"
    fi

    CLEAN_COMMONARGS='commonargs=setenv bootargs earlyprintk keep_bootcon ignore_loglevel loglevel=8 initcall_debug no_console_suspend consoleblank=0 fbcon=nodefer vt.global_cursor_default=0 logo.nologo systemd.show_status=1 systemd.log_level=debug rd.udev.log_priority=debug nosplash plymouth.enable=0 rd.plymouth=0 clk_ignore_unused swiotlb=65536 workqueue.default_affinity_scope=${workqueue.default_affinity_scope}'
    if grep -q '^commonargs=' "${ENV_TXT}"; then
      sed -i "s|^commonargs=.*|${CLEAN_COMMONARGS}|" "${ENV_TXT}"
      ok "Replaced commonargs in raw env"
    else
      printf '%s\n' "${CLEAN_COMMONARGS}" >> "${ENV_TXT}"
      ok "Added commonargs to raw env"
    fi

    SET_CONSOLE='set_console=setenv bootargs ${bootargs} console=tty0 console=ttyS0,115200'
    if grep -q '^set_console=' "${ENV_TXT}"; then
      sed -i "s|^set_console=.*|${SET_CONSOLE}|" "${ENV_TXT}"
      ok "Updated set_console in raw env"
    else
      printf '%s\n' "${SET_CONSOLE}" >> "${ENV_TXT}"
      ok "Added set_console to raw env"
    fi

    for stream_var in stdout stderr; do
      if grep -q "^${stream_var}=" "${ENV_TXT}"; then
        sed -i "s|^${stream_var}=.*|${stream_var}=serial,vidconsole|" "${ENV_TXT}"
        ok "Updated ${stream_var} to serial,vidconsole in raw env"
      else
        printf '%s\n' "${stream_var}=serial,vidconsole" >> "${ENV_TXT}"
        ok "Added ${stream_var}=serial,vidconsole to raw env"
      fi
    done

    for splash_var in splashimage splashsource splashfile silent; do
      if grep -q "^${splash_var}=" "${ENV_TXT}"; then
        sed -i "/^${splash_var}=/d" "${ENV_TXT}"
        ok "Removed ${splash_var} from raw env to unmute HDMI/U-Boot console"
      fi
    done

    "${MKENVIMAGE}" -s "${ENV_SIZE}" -o "${ENV_BIN}" "${ENV_TXT}"
    sudo dd if="${ENV_BIN}" of="${ENV_PART}" conv=fsync,notrunc status=none
    ok "Patched raw U-Boot env partition: ${ENV_PART}"

    sep
    info "Updated U-Boot env (text form):"
    sed -n '1,120p' "${ENV_TXT}"
    sep
    echo ""

    rm -f "${ENV_TXT}" "${ENV_BIN}"

    if [[ -f "${ENV_FILE}" ]]; then
      info "Also mirroring debug bootargs into bootfs/env_k1-x.txt for consistency"
      sudo sed -i 's|knl_name=Image\.itb|knl_name=Image|g' "${ENV_FILE}" 2>/dev/null || true
    fi
  elif [[ -f "${ENV_FILE}" ]]; then
    sep
    info "Original env_k1-x.txt:"
    sudo cat "${ENV_FILE}"
    sep
    echo ""

    if sudo grep -q 'knl_name=Image\.itb' "${ENV_FILE}" 2>/dev/null; then
      sudo sed -i 's|knl_name=Image\.itb|knl_name=Image|g' "${ENV_FILE}"
      ok "Fixed knl_name: Image.itb → Image"
    else
      ok "knl_name already set to Image — no change needed"
    fi

    if ! sudo grep -q 'kernel_addr_r' "${ENV_FILE}" 2>/dev/null; then
      echo "kernel_addr_r=0x200000" | sudo tee -a "${ENV_FILE}" > /dev/null
      ok "Added kernel_addr_r=0x200000"
    elif sudo grep -q 'kernel_addr_r=0x20000000\|kernel_addr_r=0x10000000' "${ENV_FILE}" 2>/dev/null; then
      sudo sed -i 's|kernel_addr_r=0x[0-9a-fA-F]*|kernel_addr_r=0x200000|g' "${ENV_FILE}"
      ok "Restored kernel_addr_r to 0x200000 (original working value)"
    else
      ok "kernel_addr_r already set — no change needed"
    fi

    CLEAN_COMMONARGS='commonargs=setenv bootargs earlyprintk keep_bootcon ignore_loglevel loglevel=8 initcall_debug no_console_suspend consoleblank=0 fbcon=nodefer vt.global_cursor_default=0 logo.nologo systemd.show_status=1 systemd.log_level=debug rd.udev.log_priority=debug nosplash plymouth.enable=0 rd.plymouth=0 clk_ignore_unused swiotlb=65536'
    if sudo grep -q '^commonargs=' "${ENV_FILE}" 2>/dev/null; then
      sudo sed -i "s|^commonargs=.*|${CLEAN_COMMONARGS}|" "${ENV_FILE}"
      ok "Replaced commonargs: removed quiet/splash/plymouth, added debug verbosity"
    else
      printf '%s\n' "${CLEAN_COMMONARGS}" | sudo tee -a "${ENV_FILE}" > /dev/null
      ok "Added commonargs to env_k1-x.txt (no splash, full debug verbosity)"
    fi

    for key_pattern in 'bootargs=' 'extraargs=' 'othbootargs='; do
      if sudo grep -q "^${key_pattern}" "${ENV_FILE}" 2>/dev/null; then
        sudo sed -i \
          -e "s|\bquiet\b||g" \
          -e "s|\bsplash\b||g" \
          -e "s|\bnosplash\b||g" \
          -e "s|plymouth\.[^ ]*||g" \
          -e "s|rd\.plymouth=[^ ]*||g" \
          -e "s|  *| |g" \
          "${ENV_FILE}"
        ok "Stripped splash/quiet/plymouth from ${key_pattern}* lines"
      fi
    done

    SET_CONSOLE='set_console=setenv bootargs ${bootargs} console=tty0 console=ttyS0,115200'
    if ! sudo grep -q '^set_console=' "${ENV_FILE}" 2>/dev/null; then
      printf '%s\n' "${SET_CONSOLE}" | sudo tee -a "${ENV_FILE}" > /dev/null
      ok "Added set_console to env_k1-x.txt (HDMI tty0 + serial ttyS0)"
    else
      sudo sed -i "s|^set_console=.*|${SET_CONSOLE}|" "${ENV_FILE}"
      ok "Updated set_console in env_k1-x.txt"
    fi

    for stream_var in stdout stderr; do
      if ! sudo grep -q "^${stream_var}=" "${ENV_FILE}" 2>/dev/null; then
        printf '%s\n' "${stream_var}=serial,vidconsole" | sudo tee -a "${ENV_FILE}" > /dev/null
        ok "Added ${stream_var}=serial,vidconsole to env_k1-x.txt"
      else
        sudo sed -i "s|^${stream_var}=.*|${stream_var}=serial,vidconsole|" "${ENV_FILE}"
        ok "Updated ${stream_var} to serial,vidconsole in env_k1-x.txt"
      fi
    done

    for splash_var in splashimage splashsource splashfile silent; do
      if sudo grep -q "^${splash_var}=" "${ENV_FILE}" 2>/dev/null; then
        sudo sed -i "/^${splash_var}=/d" "${ENV_FILE}"
        ok "Removed ${splash_var} from env_k1-x.txt"
      fi
    done

    sep
    info "Updated env_k1-x.txt:"
    sudo cat "${ENV_FILE}"
    sep
    echo ""
  else
    warn "env_k1-x.txt not found in bootfs — cannot patch boot parameters."
  fi

  # -------------------------------------------------------------------------
  # Step 8b: Patch initramfs-generic.img
  # -------------------------------------------------------------------------
  INITRD_IMG="${MOUNT_POINT}/initramfs-generic.img"
  if [[ "${PATCH_INITRD}" != "1" ]]; then
    info "Preserving base image initramfs-generic.img"
  elif [[ -f "${INITRD_IMG}" ]]; then
    INITRD_SIZE=$(du -sh "${INITRD_IMG}" | cut -f1)
    info "Patching initramfs-generic.img (${INITRD_SIZE}) to disable Plymouth ..."

    INITRD_WORK=$(mktemp -d /tmp/evl-initrd-XXXXXX)
    INITRD_PATCHED=$(mktemp /tmp/evl-initrd-patched-XXXXXX.img)
    INITRD_PATCH_OK=0

    INITRD_FMT=$(file "${INITRD_IMG}" | grep -oE 'gzip|XZ|lz4|bzip2|LZMA|Zstandard' | head -1 || true)
    info "  initramfs compression: ${INITRD_FMT:-unknown — assuming gzip}"

    (
      cd "${INITRD_WORK}"
      case "${INITRD_FMT}" in
        XZ|LZMA)   sudo sh -c "xzcat  '${INITRD_IMG}' | cpio -id --quiet 2>/dev/null" ;;
        lz4)       sudo sh -c "lz4cat '${INITRD_IMG}' | cpio -id --quiet 2>/dev/null" ;;
        bzip2)     sudo sh -c "bzcat  '${INITRD_IMG}' | cpio -id --quiet 2>/dev/null" ;;
        Zstandard) sudo sh -c "zstdcat '${INITRD_IMG}'| cpio -id --quiet 2>/dev/null" ;;
        *)         sudo sh -c "gunzip -c '${INITRD_IMG}' | cpio -id --quiet 2>/dev/null" ;;
      esac
    ) && INITRD_PATCH_OK=1 || warn "  initramfs extraction failed — keeping original."

    if [[ "${INITRD_PATCH_OK}" -eq 1 ]]; then
      PLYMOUTH_DISABLED=0

      for hook_path in \
          "${INITRD_WORK}/scripts/plymouth" \
          "${INITRD_WORK}/scripts/init-premount/plymouth" \
          "${INITRD_WORK}/scripts/init-bottom/plymouth" \
          "${INITRD_WORK}/usr/share/initramfs-tools/scripts/plymouth"; do
        if [[ -f "${hook_path}" ]]; then
          info "  Disabling Plymouth hook: ${hook_path#${INITRD_WORK}/}"
          sudo bash -c "printf '#!/bin/sh\n# Plymouth disabled by EVL image builder\n[ \"\${1:-}\" = prereqs ] && echo \"\" && exit 0\nexit 0\n' > '${hook_path}'"
          sudo chmod +x "${hook_path}"
          PLYMOUTH_DISABLED=$(( PLYMOUTH_DISABLED + 1 ))
        fi
      done

      for plym_bin in \
          "${INITRD_WORK}/bin/plymouth" \
          "${INITRD_WORK}/usr/bin/plymouth" \
          "${INITRD_WORK}/sbin/plymouthd" \
          "${INITRD_WORK}/usr/sbin/plymouthd"; do
        if [[ -f "${plym_bin}" ]] && [[ ! -L "${plym_bin}" ]]; then
          info "  Replacing Plymouth binary with stub: ${plym_bin#${INITRD_WORK}/}"
          sudo bash -c "printf '#!/bin/sh\nexit 0\n' > '${plym_bin}'"
          sudo chmod +x "${plym_bin}"
          PLYMOUTH_DISABLED=$(( PLYMOUTH_DISABLED + 1 ))
        fi
      done

      if [[ "${PLYMOUTH_DISABLED}" -gt 0 ]]; then
        ok "  ${PLYMOUTH_DISABLED} Plymouth component(s) disabled inside initramfs."
      else
        warn "  No Plymouth hooks/binaries found inside initramfs."
      fi

      info "  Repacking initramfs (gzip+cpio) ..."
      (
        cd "${INITRD_WORK}"
        sudo find . | sudo cpio -o -H newc --quiet 2>/dev/null | gzip -9 > "${INITRD_PATCHED}"
      ) && ok "  Repacked: $(du -sh "${INITRD_PATCHED}" | cut -f1)" \
        || { warn "  Repack failed — keeping original initramfs."; INITRD_PATCH_OK=0; }
    fi

    if [[ "${INITRD_PATCH_OK}" -eq 1 && -s "${INITRD_PATCHED}" ]]; then
      sudo cp "${INITRD_PATCHED}" "${INITRD_IMG}"
      ok "initramfs-generic.img replaced with Plymouth-disabled version ($(du -sh "${INITRD_IMG}" | cut -f1))."
    else
      ok "initramfs-generic.img kept from base image (${INITRD_SIZE}) — Plymouth patch skipped."
    fi

    sudo rm -rf "${INITRD_WORK}" 2>/dev/null || true
    rm -f "${INITRD_PATCHED}" 2>/dev/null || true
  else
    warn "initramfs-generic.img not found in bootfs — Bianbu rootfs mount may fail."
  fi
fi

# ---------------------------------------------------------------------------
# Step 8c: Show final boot partition contents
# ---------------------------------------------------------------------------
info "Final boot partition contents:"
ls -lh "${MOUNT_POINT}/" 2>/dev/null
echo ""

# ---------------------------------------------------------------------------
# Step 9: Sync and unmount bootfs
# ---------------------------------------------------------------------------
info "Syncing bootfs ..."
sync
sudo umount "${MOUNT_POINT}"
rmdir "${MOUNT_POINT}"
ok "Bootfs unmounted."

# ---------------------------------------------------------------------------
# Step 10: Grow image and inject EVL kernel modules into rootfs (ext4)
#
# The Bianbu initramfs loads modules from lib/modules/<kernel-version>/
# on the rootfs partition.  Our EVL kernel must have exactly the same version
# string as the modules directory, otherwise module loading fails and the
# boot hangs.
#
# The version match was already verified at the top of this script.
# ---------------------------------------------------------------------------
if [[ "${INJECT_MODULES}" != "1" ]]; then
  info "Skipping rootfs module injection to keep the base image userspace untouched."
elif [[ -n "${ROOTFS_PART}" && -b "${ROOTFS_PART}" ]]; then

  # -------------------------------------------------------------------------
  # Pre-flight: check how much space the new modules need vs what's available
  # in the rootfs partition.  If there isn't enough room, grow the image file
  # and resize the ext4 filesystem before mounting.
  # -------------------------------------------------------------------------
  NEW_MOD_KB=$(du -sk "${MODULES_DIR}/lib/modules/${EVL_MOD_VER}" | cut -f1)
  ROOTFS_FREE_KB=$(sudo tune2fs -l "${ROOTFS_PART}" 2>/dev/null \
    | awk '/Free blocks/{fb=$3} /Block size/{bs=$3} END{printf "%d", fb*bs/1024}')

  info "New modules size : $((NEW_MOD_KB / 1024)) MB"
  info "Rootfs free space: $((ROOTFS_FREE_KB / 1024)) MB"

  # We need at least NEW_MOD_KB + 64MB headroom
  NEEDED_KB=$(( NEW_MOD_KB + 65536 ))
  if [[ "${ROOTFS_FREE_KB}" -lt "${NEEDED_KB}" ]]; then
    GROW_MB=$(( (NEEDED_KB - ROOTFS_FREE_KB) / 1024 + 256 ))
    warn "Rootfs partition too small — growing image by ${GROW_MB} MB ..."

    command -v sgdisk >/dev/null 2>&1 || \
      die "sgdisk not found. Install the gdisk package before growing images."

    ROOTFS_PARTNUM=$(echo "${ROOTFS_PART}" | grep -oE '[0-9]+$')
    ROOTFS_INFO=$(sudo sgdisk -i "${ROOTFS_PARTNUM}" "${IMG}")
    ROOTFS_START_SECTOR=$(printf '%s\n' "${ROOTFS_INFO}" | \
      awk -F': *' '/First sector:/ {print $2}' | awk '{print $1}')
    ROOTFS_TYPECODE=$(printf '%s\n' "${ROOTFS_INFO}" | \
      awk -F': *' '/Partition GUID code:/ {print $2}' | awk '{print $1}')
    ROOTFS_PARTNAME=$(printf '%s\n' "${ROOTFS_INFO}" | \
      sed -n "s/^Partition name: '\\(.*\\)'$/\\1/p")

    [[ -n "${ROOTFS_START_SECTOR}" ]] || \
      die "Could not determine rootfs start sector for GPT resize."
    [[ -n "${ROOTFS_TYPECODE}" ]] || \
      die "Could not determine rootfs GPT type code for resize."
    [[ -n "${ROOTFS_PARTNAME}" ]] || ROOTFS_PARTNAME="rootfs"

    # 1. Detach loop device so we can resize the image file
    sudo losetup -d "${LOOP}" 2>/dev/null || true
    trap - EXIT

    # 2. Extend the image file
    dd if=/dev/zero bs=1M count="${GROW_MB}" >> "${IMG}" 2>/dev/null
    ok "Image file extended by ${GROW_MB} MB."

    # 3. Repair the GPT backup header location and grow the rootfs partition
    sudo sgdisk -e "${IMG}" >/dev/null
    sudo sgdisk \
      -d "${ROOTFS_PARTNUM}" \
      -n "${ROOTFS_PARTNUM}:${ROOTFS_START_SECTOR}:0" \
      -t "${ROOTFS_PARTNUM}:${ROOTFS_TYPECODE}" \
      -c "${ROOTFS_PARTNUM}:${ROOTFS_PARTNAME}" \
      "${IMG}" >/dev/null
    ok "GPT repaired and partition ${ROOTFS_PARTNUM} grown to the end of the image."

    # 4. Re-attach loop device
    LOOP=$(sudo losetup -Pf --show "${IMG}")
    LOOP_REF="${LOOP}"
    trap cleanup EXIT
    sleep 1

    # Re-resolve partition device nodes after re-attach
    ROOTFS_PART="${LOOP}p$(echo "${ROOTFS_PART}" | grep -oE '[0-9]+$')"
    info "Re-attached loop device: ${LOOP}, rootfs: ${ROOTFS_PART}"

    # 5. Check and resize the ext4 filesystem
    sudo e2fsck -f -y "${ROOTFS_PART}" 2>/dev/null || true
    sudo resize2fs "${ROOTFS_PART}" 2>/dev/null \
      && ok "ext4 filesystem resized to fill the grown partition." \
      || die "resize2fs failed after GPT resize."
  else
    info "Rootfs has sufficient free space — no resize needed."
  fi

  ROOTFS_MOUNT=$(mktemp -d /tmp/evl-rootfs-XXXXXX)

  info "Mounting rootfs partition ${ROOTFS_PART} ..."
  sudo mount "${ROOTFS_PART}" "${ROOTFS_MOUNT}"

  # -------------------------------------------------------------------------
  # Inject EVL modules
  # -------------------------------------------------------------------------
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

  if [[ "${PATCH_ROOTFS}" == "1" ]]; then
    info "Applying optional rootfs post-processing for EVL compatibility ..."

    WESTON_INIT="${ROOTFS_MOUNT}/etc/init.d/S30weston-setup.sh"
    if [[ -f "${WESTON_INIT}" ]]; then
      sudo chmod -x "${WESTON_INIT}"
      ok "Weston autostart disabled (S30weston-setup.sh — chmod -x)."
      ok "  Re-enable later: chmod +x /etc/init.d/S30weston-setup.sh"
    else
      info "S30weston-setup.sh not found — skipping Weston disable."
    fi

    for weston_script in \
        "${ROOTFS_MOUNT}/etc/init.d/"*weston* \
        "${ROOTFS_MOUNT}/etc/init.d/"*wayland*; do
      [[ -f "${weston_script}" ]] || continue
      sudo chmod -x "${weston_script}"
      ok "Disabled: $(basename "${weston_script}")"
    done

    for plymouth_script in \
        "${ROOTFS_MOUNT}/etc/init.d/"*plymouth* \
        "${ROOTFS_MOUNT}/etc/init.d/"*splash*; do
      [[ -f "${plymouth_script}" ]] || continue
      sudo chmod -x "${plymouth_script}"
      ok "Disabled Plymouth/splash init script: $(basename "${plymouth_script}")"
    done

    SHADOW_FILE="${ROOTFS_MOUNT}/etc/shadow"
    if [[ -f "${SHADOW_FILE}" ]]; then
      ROOT_HASH=$(python3 -c \
        "import crypt; print(crypt.crypt('root', crypt.mksalt(crypt.METHOD_SHA512)))" \
        2>/dev/null || true)
      if [[ -n "${ROOT_HASH}" ]]; then
        sudo sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "${SHADOW_FILE}"
        ok "Root password set to 'root' for first-boot access. Change with: passwd root"
      else
        warn "Could not generate password hash — root password unchanged."
      fi
    else
      warn "/etc/shadow not found in rootfs — cannot set root password."
    fi

    INITTAB="${ROOTFS_MOUNT}/etc/inittab"
    if [[ -f "${INITTAB}" ]]; then
      if ! sudo grep -q 'ttyS0' "${INITTAB}" 2>/dev/null; then
        echo "ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100" | \
          sudo tee -a "${INITTAB}" > /dev/null
        ok "Added ttyS0 getty to /etc/inittab (serial console at 115200 baud)."
      else
        ok "ttyS0 getty already present in /etc/inittab."
      fi

      if ! sudo grep -q 'tty1' "${INITTAB}" 2>/dev/null; then
        echo "tty1::respawn:/sbin/getty 38400 tty1" | \
          sudo tee -a "${INITTAB}" > /dev/null
        ok "Added tty1 getty to /etc/inittab (HDMI login prompt)."
      else
        ok "tty1 getty already present in /etc/inittab."
      fi
    else
      warn "/etc/inittab not found in rootfs — cannot add ttyS0/tty1 getty."
    fi
  else
    info "Preserving base image rootfs userspace configuration."
  fi

  sync
  sudo umount "${ROOTFS_MOUNT}"
  rmdir "${ROOTFS_MOUNT}"
  ok "Rootfs unmounted."
else
  warn "No ext4 rootfs partition detected — skipping module injection."
  warn "This is expected for minimal buildroot images without a separate rootfs partition."
fi

# ---------------------------------------------------------------------------
# Detach loop device
# ---------------------------------------------------------------------------
sudo losetup -d "${LOOP}"
trap - EXIT
ok "Image finalised."

GPT_VERIFY_OUTPUT=$(sudo sgdisk -v "${IMG}" 2>&1 || true)
if grep -q "No problems found" <<<"${GPT_VERIFY_OUTPUT}"; then
  ok "GPT verification passed."
else
  warn "GPT verification reported issues:"
  printf '%s\n' "${GPT_VERIFY_OUTPUT}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
sep
echo ""
echo "  Output image : ${IMG}"
echo "  Size         : $(du -sh "${IMG}" | cut -f1)"
echo "  Kernel       : ${ACTUAL_VER}"
echo "  Modules      : ${EVL_MOD_VER}"
echo ""
echo "  Test profile : ${TEST_PROFILE}"
echo ""
if [[ "${INJECT_MODULES}" == "1" ]]; then
  echo "  Rootfs modules:"
  echo "    Injected EVL modules into the image rootfs"
else
  echo "  Rootfs modules:"
  echo "    Preserved from base image (no module injection)"
fi
echo ""
if [[ "${PRESERVE_BOOTFLOW}" == "1" ]]; then
  echo "  Bootflow:"
  echo "    Preserved from base image (env_k1-x.txt / extlinux.conf / initramfs unchanged)"
else
  echo "  Bootflow overrides:"
  echo "    extlinux.conf      : $([[ "${PATCH_EXTLINUX}" == "1" ]] && echo patched || echo preserved)"
  echo "    env_k1-x.txt       : $([[ "${PATCH_ENV}" == "1" ]] && echo patched || echo preserved)"
  echo "    initramfs-generic  : $([[ "${PATCH_INITRD}" == "1" ]] && echo patched || echo preserved)"
fi
echo ""
echo "  Flash to SD card (Linux):"
echo "    sudo dd if=\"${IMG}\" of=/dev/sdX bs=4M status=progress conv=fsync"
echo "    (replace /dev/sdX with your SD card device — check with lsblk)"
echo ""
echo "  Flash to SD card (Windows):"
echo "    Use Balena Etcher or Rufus — write as raw disk image."
echo "    Do NOT write as partition image."
echo ""
echo "  What to expect on first boot:"
echo "    - HDMI screen shows kernel boot log (not Bianbu splash)"
echo "    - Module loading progress visible on screen"
echo "    - Login prompt appears on both HDMI (tty1) and serial (ttyS0)"
echo "    - Login: root / root  (change password after first login)"
sep
