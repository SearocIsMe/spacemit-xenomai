#!/usr/bin/env bash
# =============================================================================
# 03-build-kernel.sh
# Cross-compile the EVL-enabled kernel for SpacemiT K1 (RISC-V).
#
# Produces:
#   ${BUILD_DIR}/arch/riscv/boot/Image        — uncompressed kernel
#   ${BUILD_DIR}/arch/riscv/boot/dts/.../*.dtb — device trees
#   ${BUILD_DIR}/modules_install/              — kernel modules
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.sh"

# ---------------------------------------------------------------------------
# Guard: refuse to run under /mnt/c/
# ---------------------------------------------------------------------------
if [[ "$PWD" == /mnt/* ]]; then
  echo "ERROR: Running from Windows-mounted path. Use WSL2 native FS."
  exit 1
fi

# ---------------------------------------------------------------------------
# Load environment
# ---------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env.sh not found. Run 00-setup-env.sh first."
  exit 1
fi
source "${ENV_FILE}"
BUILD_DIR="${BUILD_DIR_OVERRIDE:-${BUILD_DIR}}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

ensure_writable_build_dir() {
  if mkdir -p "${BUILD_DIR}" 2>/dev/null && [[ -w "${BUILD_DIR}" ]]; then
    return 0
  fi

  if [[ -n "${BUILD_DIR_OVERRIDE:-}" ]]; then
    die "Build directory is not writable: ${BUILD_DIR}"
  fi

  local fallback
  fallback="$(cd "${SCRIPT_DIR}/../.." && pwd)/.build/build-k1"
  warn "Build directory is not writable: ${BUILD_DIR}"
  warn "Falling back to a repo-local build directory: ${fallback}"
  mkdir -p "${fallback}" || die "Cannot create fallback build directory: ${fallback}"
  BUILD_DIR="${fallback}"
  MODULES_INSTALL_DIR="${BUILD_DIR}/modules_install"
}

verify_irq_pipeline_overlay_state() {
  local irq_header="${KERNEL_DIR}/include/linux/irq.h"
  local irq_settings="${KERNEL_DIR}/kernel/irq/settings.h"

  [[ -f "${irq_header}" ]] || die "Missing kernel header: ${irq_header}"
  [[ -f "${irq_settings}" ]] || die "Missing IRQ settings header: ${irq_settings}"

  if grep -q 'IRQ_OOB' "${irq_settings}" 2>/dev/null; then
    grep -q 'IRQ_OOB' "${irq_header}" 2>/dev/null || die "$(cat <<EOF
Kernel tree is missing IRQ pipeline flag definitions in ${irq_header}.

Detected:
  - ${irq_settings} references IRQ_OOB / IRQ_CHAINED
  - ${irq_header} does not define them

This usually means the EVL overlay was only partially deployed, or the source
tree was updated after overlay deployment.

Next step:
  1. Re-run bash scripts/build/00b-deploy-overlay.sh
  2. Verify ${irq_header} contains IRQ_OOB and IRQ_CHAINED
  3. Re-run this build script
EOF
)"
  fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Number of parallel jobs — default to nproc, cap at 16 for WSL2 stability
NPROC=$(nproc)
JOBS="${JOBS:-$((NPROC > 16 ? 16 : NPROC))}"
MODULE_JOBS="${MODULE_JOBS:-1}"
MODULES_INSTALL_DIR="${MODULES_INSTALL_DIR_OVERRIDE:-${BUILD_DIR}/modules_install}"

# LOCALVERSION must be passed on the make command line (not just via config).
# scripts/setlocalversion independently appends '+' when git tree is dirty,
# regardless of CONFIG_LOCALVERSION / CONFIG_LOCALVERSION_AUTO settings.
# Passing LOCALVERSION="" here suppresses that suffix so the kernel version
# string is exactly "6.6.63" — matching the Bianbu initramfs lib/modules path.
LOCALVERSION=""

# ---------------------------------------------------------------------------
# Verify prerequisites
# ---------------------------------------------------------------------------
[[ -d "${KERNEL_DIR}/.git" ]]      || die "Kernel not found at ${KERNEL_DIR}."
command -v "${CROSS_COMPILE}gcc" &>/dev/null || \
  die "Cross-compiler not found: ${CROSS_COMPILE}gcc"

ensure_writable_build_dir
[[ -f "${BUILD_DIR}/.config" ]]    || die ".config not found. Run 02-configure.sh first."

verify_irq_pipeline_overlay_state

cd "${KERNEL_DIR}"

# ---------------------------------------------------------------------------
# Suppress automatic version suffix (+)
#
# scripts/setlocalversion appends '+' when the git tree has uncommitted
# changes, regardless of CONFIG_LOCALVERSION / CONFIG_LOCALVERSION_AUTO.
# Two measures together guarantee the suffix is stripped:
#   1. Create ${KERNEL_DIR}/.scmversion (empty file) — setlocalversion stops
#      at this file and skips all git-describe checks.
#   2. Delete the cached ${BUILD_DIR}/include/config/kernel.release — without
#      this, make reuses the old version string from cache even after .scmversion
#      is created.
#
# This is critical: the Bianbu initramfs expects lib/modules/6.6.63 exactly.
# A kernel reporting 6.6.63+ will not find its modules and hang at boot.
# ---------------------------------------------------------------------------
if [[ ! -f "${KERNEL_DIR}/.scmversion" ]]; then
  info "Creating .scmversion to suppress git '+' suffix in kernel version ..."
  touch "${KERNEL_DIR}/.scmversion"
  ok "Created ${KERNEL_DIR}/.scmversion"
else
  info ".scmversion already exists — git version suffix suppressed."
fi

# Always remove cached kernel.release to force version string recalculation
if [[ -f "${BUILD_DIR}/include/config/kernel.release" ]]; then
  rm -f "${BUILD_DIR}/include/config/kernel.release"
  info "Removed cached kernel.release — version string will be recalculated."
fi

# ---------------------------------------------------------------------------
# Print build summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Build Configuration"
echo "  Kernel source : ${KERNEL_DIR}"
echo "  Build output  : ${BUILD_DIR}"
echo "  ARCH          : ${ARCH}"
echo "  CROSS_COMPILE : ${CROSS_COMPILE}"
echo "  Jobs          : ${JOBS}"
echo "  Module jobs   : ${MODULE_JOBS}"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Build kernel image
# ---------------------------------------------------------------------------
info "Building kernel Image (${JOBS} jobs) ..."
START_TIME=$(date +%s)

make \
  ARCH="${ARCH}" \
  CROSS_COMPILE="${CROSS_COMPILE}" \
  LOCALVERSION="${LOCALVERSION}" \
  O="${BUILD_DIR}" \
  -j"${JOBS}" \
  Image

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ok "Kernel built in ${ELAPSED}s → ${BUILD_DIR}/arch/riscv/boot/Image"

# Verify the version string has no trailing + suffix
ACTUAL_VER=$(strings "${BUILD_DIR}/arch/riscv/boot/Image" 2>/dev/null | \
             grep "^Linux version" | head -1 | awk '{print $3}')
if [[ "${ACTUAL_VER}" == *"+"* ]]; then
  warn "Kernel version has trailing '+': ${ACTUAL_VER}"
  warn "This means the git tree is dirty AND scripts/setlocalversion appended '+'."
  warn "The LOCALVERSION=\"\" override should prevent this — if you still see '+',',"
  warn "run: touch \${KERNEL_DIR}/.scmversion  (creates an empty version marker)"
else
  ok "Kernel version: ${ACTUAL_VER} (no + suffix — matches initramfs)"
fi

# ---------------------------------------------------------------------------
# Step 2: Build device tree blobs
# ---------------------------------------------------------------------------
info "Building device tree blobs ..."
make \
  ARCH="${ARCH}" \
  CROSS_COMPILE="${CROSS_COMPILE}" \
  LOCALVERSION="${LOCALVERSION}" \
  O="${BUILD_DIR}" \
  -j"${JOBS}" \
  dtbs
ok "DTBs built → ${BUILD_DIR}/arch/riscv/boot/dts/"

# ---------------------------------------------------------------------------
# Step 3: Build kernel modules
# NOTE:
#   This tree sporadically hits fixdep races under parallel O= module builds
#   ("error opening file ... .*.o.d: No such file or directory"). Building
#   modules single-threaded is slower, but reliably avoids those transient
#   dependency-file failures.
# ---------------------------------------------------------------------------
info "Building kernel modules (${MODULE_JOBS} job(s)) ..."
make \
  ARCH="${ARCH}" \
  CROSS_COMPILE="${CROSS_COMPILE}" \
  LOCALVERSION="${LOCALVERSION}" \
  O="${BUILD_DIR}" \
  -j"${MODULE_JOBS}" \
  modules
ok "Modules built."

# ---------------------------------------------------------------------------
# Step 4: Install modules to staging directory
# ---------------------------------------------------------------------------
info "Installing modules to ${MODULES_INSTALL_DIR} ..."
mkdir -p "${MODULES_INSTALL_DIR}"
make \
  ARCH="${ARCH}" \
  CROSS_COMPILE="${CROSS_COMPILE}" \
  LOCALVERSION="${LOCALVERSION}" \
  O="${BUILD_DIR}" \
  INSTALL_MOD_PATH="${MODULES_INSTALL_DIR}" \
  INSTALL_MOD_STRIP=1 \
  modules_install
ok "Modules installed."

# ---------------------------------------------------------------------------
# Step 5: Print artefact summary
# ---------------------------------------------------------------------------
KERNEL_IMAGE="${BUILD_DIR}/arch/riscv/boot/Image"
KERNEL_SIZE=$(du -sh "${KERNEL_IMAGE}" 2>/dev/null | cut -f1 || echo "?")

echo ""
echo "============================================================"
echo "  Build Complete!"
echo ""
echo "  Kernel image : ${KERNEL_IMAGE} (${KERNEL_SIZE})"
echo "  DTBs         : ${BUILD_DIR}/arch/riscv/boot/dts/spacemit/"
echo "  Modules      : ${MODULES_INSTALL_DIR}"
echo ""
echo "  Next step:"
echo "    bash scripts/flash/flash-sdcard.sh /dev/sdX ${BUILD_DIR}"
echo "  (replace /dev/sdX with your actual SD card device)"
echo "============================================================"
