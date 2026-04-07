#!/usr/bin/env bash
# =============================================================================
# build-qemu-virt-bisect.sh
#
# Build a generic QEMU riscv64 `virt` kernel matrix from the same repository so
# we can separate generic RISC-V bring-up problems from SpacemiT K1 board-only
# problems.
#
# Usage:
#   bash scripts/build/build-qemu-virt-bisect.sh [variant]
#   bash scripts/build/build-qemu-virt-bisect.sh all
#
# Variants:
#   vanilla-qemu        Generic RISC-V baseline with EVL/Dovetail disabled
#   irq-pipeline-qemu   IRQ pipeline only
#   irq-pipeline-nosmp-qemu  IRQ pipeline only, SMP disabled
#   irq-pipeline-noidle-qemu IRQ pipeline only, idle tweaks applied
#   irq-pipeline-minimal-qemu Smallest practical IRQ pipeline slice
#   dovetail-qemu       IRQ pipeline + Dovetail
#   full-evl-qemu       IRQ pipeline + Dovetail + EVL
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
QEMU_BUILD_ROOT="${QEMU_BUILD_ROOT:-${WORK_DIR}/qemu-virt}"
QEMU_FRAGMENT_BASE="${REPO_ROOT}/configs/qemu_virt_evl_defconfig"

variants=(
  "vanilla-qemu:${REPO_ROOT}/configs/k1_vanilla_defconfig:${QEMU_BUILD_ROOT}/vanilla"
  "irq-pipeline-qemu:${REPO_ROOT}/configs/k1_irq_pipeline_only_defconfig:${QEMU_BUILD_ROOT}/irq-pipeline"
  "irq-pipeline-nosmp-qemu:${REPO_ROOT}/configs/k1_irq_pipeline_nosmp_defconfig:${QEMU_BUILD_ROOT}/irq-pipeline-nosmp"
  "irq-pipeline-noidle-qemu:${REPO_ROOT}/configs/k1_irq_pipeline_noidle_defconfig:${QEMU_BUILD_ROOT}/irq-pipeline-noidle"
  "irq-pipeline-minimal-qemu:${REPO_ROOT}/configs/k1_irq_pipeline_minimal_defconfig:${QEMU_BUILD_ROOT}/irq-pipeline-minimal"
  "dovetail-qemu:${REPO_ROOT}/configs/k1_dovetail_only_defconfig:${QEMU_BUILD_ROOT}/dovetail"
  "full-evl-qemu:${REPO_ROOT}/configs/k1_evl_defconfig:${QEMU_BUILD_ROOT}/full-evl"
)

run_variant() {
  local name="$1"
  local evl_fragment="$2"
  local outdir="$3"
  local merged_fragment

  merged_fragment="$(mktemp)"
  trap 'rm -f "${merged_fragment}"' RETURN

  cat "${QEMU_FRAGMENT_BASE}" "${evl_fragment}" > "${merged_fragment}"

  echo ""
  echo "============================================================"
  echo "Building QEMU virt kernel variant: ${name}"
  echo "  base defconfig : defconfig"
  echo "  fragment       : ${evl_fragment}"
  echo "  merged config  : ${merged_fragment}"
  echo "  outdir         : ${outdir}"
  echo "============================================================"

  if [[ "${CLEAN_BUILD}" == "1" && -d "${outdir}" ]]; then
    echo "Cleaning previous build dir: ${outdir}"
    rm -rf "${outdir}"
  fi

  BUILD_DIR_OVERRIDE="${outdir}" \
  BASE_DEFCONFIG=defconfig \
  CONFIG_FRAGMENT="${merged_fragment}" \
    bash "${SCRIPT_DIR}/02-configure.sh"

  BUILD_DIR_OVERRIDE="${outdir}" \
  MODULES_INSTALL_DIR_OVERRIDE="${outdir}/modules_install" \
  JOBS="${JOBS}" \
  MODULE_JOBS="${MODULE_JOBS}" \
    bash "${SCRIPT_DIR}/03-build-kernel.sh"

  rm -f "${merged_fragment}"
  trap - RETURN
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
  echo "Valid values: all, vanilla-qemu, irq-pipeline-qemu, irq-pipeline-nosmp-qemu, irq-pipeline-noidle-qemu, irq-pipeline-minimal-qemu, dovetail-qemu, full-evl-qemu"
  exit 1
fi

echo ""
echo "QEMU virt kernel bisect builds completed."
