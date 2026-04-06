#!/usr/bin/env bash
# =============================================================================
# 00b-deploy-overlay.sh
#
# Deploy the EVL kernel overlay (kernel-overlay/) to the SpacemiT linux-k1
# source tree before building.
#
# The overlay directory mirrors the kernel source tree and contains:
#   - New EVL/Dovetail headers (from linux-evl):
#       include/evl/
#       include/dovetail/
#       include/asm-generic/evl/
#       include/uapi/evl/
#       include/linux/irq_pipeline.h
#       include/linux/dovetail.h
#       include/linux/spinlock_pipeline.h
#   - RISC-V arch hooks (new/modified files):
#       arch/riscv/include/asm/irqflags.h   (defines native_*() hardware ops; includes irq_pipeline.h at end)
#       arch/riscv/include/asm/dovetail.h
#       arch/riscv/include/asm/irq_pipeline.h  (defines arch_local_*() → stall-bit when CONFIG_IRQ_PIPELINE,
#                                               → native_*() when !CONFIG_IRQ_PIPELINE)
#       arch/riscv/include/dovetail/thread_info.h
#   - Modified existing files:
#       arch/riscv/include/asm/thread_info.h  (adds oob_thread_state)
#       arch/riscv/kernel/traps.c             (routes IRQs through pipeline)
#       arch/riscv/Kconfig                    (adds HAVE_DOVETAIL selects)
#       kernel/irq/Kconfig                    (adds IRQ_PIPELINE config)
#       kernel/evl/Kconfig                    (adds DOVETAIL + EVL config)
#       Kconfig                               (sources kernel/evl/Kconfig)
#
# Usage:
#   bash scripts/build/00b-deploy-overlay.sh
#   bash scripts/build/00b-deploy-overlay.sh --dry-run  (preview only)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OVERLAY_DIR="${REPO_ROOT}/kernel-overlay"
ENV_FILE="${SCRIPT_DIR}/env.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

require_overlay_file() {
  local path="$1"
  [[ -e "${OVERLAY_DIR}/${path}" ]] || die \
    "Overlay is incomplete: missing ${path} in ${OVERLAY_DIR}. Refusing to deploy a partial EVL tree."
}

require_overlay_any() {
  local paths=("$@")
  local path
  for path in "${paths[@]}"; do
    if [[ -e "${OVERLAY_DIR}/${path}" ]]; then
      return 0
    fi
  done

  die "Overlay is incomplete: missing one of [${paths[*]}] in ${OVERLAY_DIR}. Refusing to deploy a partial EVL tree."
}

# ---------------------------------------------------------------------------
# Load kernel dir from env.sh, or use default
# ---------------------------------------------------------------------------
KERNEL_DIR="${HOME}/work/linux-k1"
if [[ -f "${ENV_FILE}" ]]; then
  source "${ENV_FILE}"
fi

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
[[ -d "${OVERLAY_DIR}" ]] || die "Overlay directory not found: ${OVERLAY_DIR}"
[[ -d "${KERNEL_DIR}" ]]  || die "Kernel source not found: ${KERNEL_DIR}"

# A partial EVL overlay is worse than no overlay at all: it can leave the
# kernel tree in a state where Kconfig references EVL menus that do not exist.
# Validate a few must-have files before we touch the target tree.
require_overlay_file "arch/riscv/include/asm/irq_pipeline.h"
require_overlay_file "include/dovetail/irq.h"
require_overlay_file "include/evl/thread.h"
require_overlay_file "include/uapi/evl/thread-abi.h"
require_overlay_file "kernel/evl/Kconfig"
require_overlay_any "kernel/Kconfig.evl" "kernel/evl/Kconfig"
require_overlay_any "kernel/Kconfig.dovetail" "kernel/evl/Kconfig"

FILE_COUNT=$(find "${OVERLAY_DIR}" -type f | wc -l)
info "Deploying ${FILE_COUNT} overlay files → ${KERNEL_DIR}"
info "Overlay source: ${OVERLAY_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Deploy using rsync (idempotent, preserves timestamps)
# ---------------------------------------------------------------------------
RSYNC_OPTS="-a --itemize-changes"
[[ "${DRY_RUN}" == "1" ]] && RSYNC_OPTS="${RSYNC_OPTS} --dry-run"

rsync ${RSYNC_OPTS} "${OVERLAY_DIR}/" "${KERNEL_DIR}/"

echo ""
if [[ "${DRY_RUN}" == "1" ]]; then
  info "Dry run complete. Remove --dry-run to apply."
else
  ok "Overlay deployed to ${KERNEL_DIR}"
  echo ""
  echo "  Next: run 02-configure.sh to merge EVL config options"
  echo "        then 03-build-kernel.sh to build the kernel"
fi
