#!/usr/bin/env bash
# =============================================================================
# build-kernel-bisect.sh
#
# Build a matrix of kernel variants to bisect Jupiter boot failures:
#   1. vanilla-k1    - locally-built baseline kernel, EVL/Dovetail disabled
#   2. dovetail-only - IRQ pipeline enabled, EVL disabled
#   3. evl-off       - same idea as dovetail-only, reserved for future EVL-only
#                      toggles while keeping the script interface stable
#   4. full-evl      - current EVL configuration
#
# Usage:
#   bash scripts/build/build-kernel-bisect.sh [variant]
#   bash scripts/build/build-kernel-bisect.sh all
#
# Environment:
#   JOBS         Parallel jobs for Image/dtbs builds (forwarded to 03-build-kernel.sh)
#   MODULE_JOBS  Parallel jobs for modules build/install (default remains whatever
#                03-build-kernel.sh chooses; recommend 1 unless testing races)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env.sh not found. Run scripts/build/00-setup-env.sh first."
  exit 1
fi
source "${ENV_FILE}"

TARGET="${1:-all}"
CLEAN_BUILD="${CLEAN_BUILD:-1}"
JOBS="${JOBS:-}"
MODULE_JOBS="${MODULE_JOBS:-}"

variants=(
  "vanilla-k1:${REPO_ROOT}/configs/k1_vanilla_defconfig:${WORK_DIR}/build-k1-vanilla"
  "irq-pipeline-only:${REPO_ROOT}/configs/k1_irq_pipeline_only_defconfig:${WORK_DIR}/build-k1-irq-pipeline"
  "irq-pipeline-nosmp:${REPO_ROOT}/configs/k1_irq_pipeline_nosmp_defconfig:${WORK_DIR}/build-k1-irq-pipeline-nosmp"
  "irq-pipeline-noidle:${REPO_ROOT}/configs/k1_irq_pipeline_noidle_defconfig:${WORK_DIR}/build-k1-irq-pipeline-noidle"
  "irq-pipeline-minimal:${REPO_ROOT}/configs/k1_irq_pipeline_minimal_defconfig:${WORK_DIR}/build-k1-irq-pipeline-minimal"
  "dovetail-nosmp:${REPO_ROOT}/configs/k1_dovetail_nosmp_defconfig:${WORK_DIR}/build-k1-dovetail-nosmp"
  "dovetail-noidle:${REPO_ROOT}/configs/k1_dovetail_noidle_defconfig:${WORK_DIR}/build-k1-dovetail-noidle"
  "dovetail-only:${REPO_ROOT}/configs/k1_dovetail_only_defconfig:${WORK_DIR}/build-k1-dovetail"
  "evl-off:${REPO_ROOT}/configs/k1_evl_off_defconfig:${WORK_DIR}/build-k1-evl-off"
  "full-evl:${REPO_ROOT}/configs/k1_evl_defconfig:${WORK_DIR}/build-k1-evl"
)

run_variant() {
  local name="$1"
  local fragment="$2"
  local outdir="$3"

  echo ""
  echo "============================================================"
  echo "Building kernel variant: ${name}"
  echo "  fragment : ${fragment}"
  echo "  outdir   : ${outdir}"
  echo "============================================================"

  if [[ "${CLEAN_BUILD}" == "1" && -d "${outdir}" ]]; then
    echo "Cleaning previous build dir: ${outdir}"
    rm -rf "${outdir}"
  fi

  BUILD_DIR_OVERRIDE="${outdir}" \
  CONFIG_FRAGMENT="${fragment}" \
    bash "${SCRIPT_DIR}/02-configure.sh"

  BUILD_DIR_OVERRIDE="${outdir}" \
  MODULES_INSTALL_DIR_OVERRIDE="${outdir}/modules_install" \
  JOBS="${JOBS}" \
  MODULE_JOBS="${MODULE_JOBS}" \
    bash "${SCRIPT_DIR}/03-build-kernel.sh"
}

matched=0
for entry in "${variants[@]}"; do
  IFS=":" read -r name fragment outdir <<<"${entry}"
  if [[ "${TARGET}" == "all" || "${TARGET}" == "${name}" ]]; then
    matched=1
    run_variant "${name}" "${fragment}" "${outdir}"
  fi
done

if [[ "${matched}" != "1" ]]; then
  echo "ERROR: Unknown variant '${TARGET}'."
  echo "Valid values: all, vanilla-k1, irq-pipeline-only, irq-pipeline-nosmp, irq-pipeline-noidle, irq-pipeline-minimal, dovetail-nosmp, dovetail-noidle, dovetail-only, evl-off, full-evl"
  exit 1
fi

echo ""
echo "Kernel bisect builds completed."
