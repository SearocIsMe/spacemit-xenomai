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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Number of parallel jobs — default to nproc, cap at 16 for WSL2 stability
NPROC=$(nproc)
JOBS="${JOBS:-$((NPROC > 16 ? 16 : NPROC))}"
MODULES_INSTALL_DIR="${BUILD_DIR}/modules_install"

# ---------------------------------------------------------------------------
# Verify prerequisites
# ---------------------------------------------------------------------------
[[ -d "${KERNEL_DIR}/.git" ]]      || die "Kernel not found at ${KERNEL_DIR}."
[[ -f "${BUILD_DIR}/.config" ]]    || die ".config not found. Run 02-configure.sh first."
command -v "${CROSS_COMPILE}gcc" &>/dev/null || \
  die "Cross-compiler not found: ${CROSS_COMPILE}gcc"

cd "${KERNEL_DIR}"

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
  O="${BUILD_DIR}" \
  -j"${JOBS}" \
  Image

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ok "Kernel built in ${ELAPSED}s → ${BUILD_DIR}/arch/riscv/boot/Image"

# ---------------------------------------------------------------------------
# Step 2: Build device tree blobs
# ---------------------------------------------------------------------------
info "Building device tree blobs ..."
make \
  ARCH="${ARCH}" \
  CROSS_COMPILE="${CROSS_COMPILE}" \
  O="${BUILD_DIR}" \
  -j"${JOBS}" \
  dtbs
ok "DTBs built → ${BUILD_DIR}/arch/riscv/boot/dts/"

# ---------------------------------------------------------------------------
# Step 3: Build kernel modules
# ---------------------------------------------------------------------------
info "Building kernel modules ..."
make \
  ARCH="${ARCH}" \
  CROSS_COMPILE="${CROSS_COMPILE}" \
  O="${BUILD_DIR}" \
  -j"${JOBS}" \
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
  O="${BUILD_DIR}" \
  INSTALL_MOD_PATH="${MODULES_INSTALL_DIR}" \
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
