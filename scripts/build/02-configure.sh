#!/usr/bin/env bash
# =============================================================================
# 02-configure.sh
# Configure the EVL-patched SpacemiT linux-6.6 kernel for Jupiter (K1).
#
# Steps:
#   1. Start from spacemit_k1_v2_defconfig
#   2. Merge EVL kernel config fragment (configs/k1_evl_defconfig)
#   3. Optionally open menuconfig for manual review
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

EVL_FRAGMENT="${REPO_ROOT}/configs/k1_evl_defconfig"
OPEN_MENUCONFIG="${OPEN_MENUCONFIG:-0}"   # set to 1 to open menuconfig

# ---------------------------------------------------------------------------
# Verify prerequisites
# ---------------------------------------------------------------------------
[[ -d "${KERNEL_DIR}/.git" ]] || die "Kernel not found at ${KERNEL_DIR}."
[[ -f "${EVL_FRAGMENT}" ]]    || die "EVL config fragment not found at ${EVL_FRAGMENT}."

cd "${KERNEL_DIR}"

# ---------------------------------------------------------------------------
# Step 1: Apply base SpacemiT defconfig
# ---------------------------------------------------------------------------
info "Applying base defconfig: spacemit_k1_v2_defconfig ..."
make \
  ARCH="${ARCH}" \
  CROSS_COMPILE="${CROSS_COMPILE}" \
  O="${BUILD_DIR}" \
  spacemit_k1_v2_defconfig
ok "Base defconfig applied."

# ---------------------------------------------------------------------------
# Step 2: Merge EVL config fragment
# ---------------------------------------------------------------------------
info "Merging EVL config fragment: ${EVL_FRAGMENT} ..."

# Use kernel's merge_config.sh script
MERGE_SCRIPT="${KERNEL_DIR}/scripts/kconfig/merge_config.sh"
if [[ -f "${MERGE_SCRIPT}" ]]; then
  ARCH="${ARCH}" \
  CROSS_COMPILE="${CROSS_COMPILE}" \
  KCONFIG_CONFIG="${BUILD_DIR}/.config" \
    bash "${MERGE_SCRIPT}" \
      -m \
      "${BUILD_DIR}/.config" \
      "${EVL_FRAGMENT}"
  # Resolve any new symbols introduced by the fragment
  make \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    olddefconfig
  ok "EVL fragment merged."
else
  warn "merge_config.sh not found — appending fragment manually."
  cat "${EVL_FRAGMENT}" >> "${BUILD_DIR}/.config"
  make \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    olddefconfig
  ok "EVL fragment appended and resolved."
fi

# ---------------------------------------------------------------------------
# Step 3: Optional menuconfig
# ---------------------------------------------------------------------------
if [[ "${OPEN_MENUCONFIG}" == "1" ]]; then
  info "Opening menuconfig for manual review ..."
  make \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    menuconfig
fi

# ---------------------------------------------------------------------------
# Step 4: Verify critical EVL options are set
# ---------------------------------------------------------------------------
info "Verifying critical kernel config options ..."
CONFIG_FILE="${BUILD_DIR}/.config"
MISSING=()

check_config() {
  local opt="$1"
  local expected="$2"
  local actual
  actual=$(grep -E "^${opt}=" "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2 || echo "NOT_SET")
  if [[ "${actual}" != "${expected}" ]]; then
    MISSING+=("${opt}=${expected} (got: ${actual})")
  fi
}

check_config "CONFIG_EVL_CORE"          "y"
check_config "CONFIG_DOVETAIL"          "y"
check_config "CONFIG_IRQ_PIPELINE"      "y"
check_config "CONFIG_HIGH_RES_TIMERS"   "y"
check_config "CONFIG_HZ_1000"           "y"
check_config "CONFIG_PREEMPT"           "y"

if [[ ${#MISSING[@]} -gt 0 ]]; then
  warn "The following required options are not set correctly:"
  for m in "${MISSING[@]}"; do
    warn "  - ${m}"
  done
  warn "Run with OPEN_MENUCONFIG=1 to fix manually:"
  warn "  OPEN_MENUCONFIG=1 bash scripts/build/02-configure.sh"
else
  ok "All critical EVL config options verified."
fi

echo ""
echo "============================================================"
echo "  Kernel configured at: ${BUILD_DIR}/.config"
echo ""
echo "  Next step:"
echo "    bash scripts/build/03-build-kernel.sh"
echo "============================================================"
