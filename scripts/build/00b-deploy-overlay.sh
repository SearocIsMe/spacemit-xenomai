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
#       arch/riscv/include/asm/irqflags.h   (defines native_*() + arch_local_*() as hw ops)
#       arch/riscv/include/asm/dovetail.h
#       arch/riscv/include/asm/irq_pipeline.h  (pipeline hooks; no arch_local_*() defs)
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

# ---------------------------------------------------------------------------
# Patch include/linux/sched.h: add stall_bits to task_struct for EVL
# This is a targeted injection rather than a full file copy since sched.h is
# a large, complex base-kernel file that should not be replaced wholesale.
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" != "1" ]]; then
  SCHED_H="${KERNEL_DIR}/include/linux/sched.h"
  if ! grep -q "stall_bits" "${SCHED_H}"; then
    info "Patching include/linux/sched.h (adding stall_bits for EVL IRQ pipeline)..."
    python3 - "${SCHED_H}" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Insert after the CONFIG_PREEMPT_RT block (softirq_disable_cnt)
old = '#ifdef CONFIG_PREEMPT_RT\n\tint\t\t\t\tsoftirq_disable_cnt;\n#endif'
new = (old +
       '\n\n#ifdef CONFIG_IRQ_PIPELINE\n'
       '\tunsigned long\t\t\tstall_bits;\n'
       '#endif')

if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("  sched.h: stall_bits inserted OK")
else:
    # Fallback: find the block by the irq_config line
    old2 = '#ifdef CONFIG_PREEMPT_RT\n\tint\t\t\t\tsoftirq_disable_cnt;\n#endif\n\n#ifdef CONFIG_LOCKDEP'
    new2 = ('#ifdef CONFIG_PREEMPT_RT\n\tint\t\t\t\tsoftirq_disable_cnt;\n#endif\n'
            '\n#ifdef CONFIG_IRQ_PIPELINE\n'
            '\tunsigned long\t\t\tstall_bits;\n'
            '#endif\n\n#ifdef CONFIG_LOCKDEP')
    if old2 in content:
        content = content.replace(old2, new2, 1)
        with open(path, 'w') as f:
            f.write(content)
        print("  sched.h: stall_bits inserted OK (fallback)")
    else:
        print("WARNING: could not locate insertion point in sched.h", file=sys.stderr)
        sys.exit(1)
PYEOF
    grep -q "stall_bits" "${SCHED_H}" \
      && ok "sched.h patched: stall_bits added" \
      || die "sched.h patch failed - stall_bits not found after patch"
  else
    info "sched.h already has stall_bits - skipping"
  fi
fi

# ---------------------------------------------------------------------------
# Patch kernel/sched/core.c: add #include <linux/irqstage.h>
# Required so EVL irqstage.h helpers (init_task_stall_bits etc.) are visible.
# NOTE: init_task_stall_bits(p) is intentionally NOT called from __sched_fork()
# because stall_bits is zero-initialized (INBAND_STALL_BIT=0 = IRQs enabled),
# which is the correct default.  Calling it was a regression that caused a
# boot hang (kernel froze at Bianbu splash) — reverted Apr 2026.
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" != "1" ]]; then
  CORE_C="${KERNEL_DIR}/kernel/sched/core.c"
  if ! grep -q "irqstage.h" "${CORE_C}"; then
    info "Patching kernel/sched/core.c (adding irqstage.h include for EVL)..."
    python3 - "${CORE_C}" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Add #include <linux/irqstage.h> at the top (before first #include)
irqstage_block = '#ifdef CONFIG_IRQ_PIPELINE\n#include <linux/irqstage.h>\n#endif\n'
first_include = '#include <linux/highmem.h>'
if irqstage_block not in content and first_include in content:
    content = content.replace(first_include,
                              irqstage_block + first_include, 1)
    print("  core.c: irqstage.h include injected OK")
elif irqstage_block in content:
    print("  core.c: irqstage.h include already present")
else:
    print("WARNING: could not locate '#include <linux/highmem.h>' in core.c",
          file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
PYEOF
    grep -q "irqstage.h" "${CORE_C}" \
      && ok "kernel/sched/core.c patched: irqstage.h include added" \
      || die "core.c patch failed - irqstage.h not found after patch"
  else
    info "kernel/sched/core.c already has irqstage.h include - skipping"
  fi
fi

echo ""
if [[ "${DRY_RUN}" == "1" ]]; then
  info "Dry run complete. Remove --dry-run to apply."
else
  ok "Overlay deployed to ${KERNEL_DIR}"
  echo ""
  echo "  Next: run 02-configure.sh to merge EVL config options"
  echo "        then 03-build-kernel.sh to build the kernel"
fi
