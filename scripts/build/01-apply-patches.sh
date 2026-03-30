#!/usr/bin/env bash
# =============================================================================
# 01-apply-patches.sh
# Apply EVL Dovetail patches (and any K1-specific fixes) to the SpacemiT
# linux-6.6 kernel tree.
#
# Patch application order:
#   Layer 1 — RISC-V Dovetail base (interrupt pipeline)
#   Layer 2 — RISC-V FPU context for OOB threads
#   Layer 3 — SpacemiT K1 / Jupiter board-specific EVL fixes
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

PATCHES_DIR="${REPO_ROOT}/patches"

# ---------------------------------------------------------------------------
# Verify kernel source exists
# ---------------------------------------------------------------------------
[[ -d "${KERNEL_DIR}/.git" ]] || die "Kernel not found at ${KERNEL_DIR}. Run 00-setup-env.sh first."

cd "${KERNEL_DIR}"

# ---------------------------------------------------------------------------
# Check if patches already applied (idempotency)
# ---------------------------------------------------------------------------
APPLIED_MARKER="${KERNEL_DIR}/.evl-patches-applied"
if [[ -f "${APPLIED_MARKER}" ]]; then
  warn "EVL patches appear to have been applied already (marker found)."
  warn "To re-apply, delete ${APPLIED_MARKER} and run again."
  exit 0
fi

# ---------------------------------------------------------------------------
# Create a working branch
# ---------------------------------------------------------------------------
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
EVL_BRANCH="evl-port-$(date +%Y%m%d)"

if git show-ref --verify --quiet "refs/heads/${EVL_BRANCH}"; then
  warn "Branch ${EVL_BRANCH} already exists — checking it out."
  git checkout "${EVL_BRANCH}"
else
  info "Creating branch ${EVL_BRANCH} from ${CURRENT_BRANCH} ..."
  git checkout -b "${EVL_BRANCH}"
fi

# ---------------------------------------------------------------------------
# Apply patches in order
# ---------------------------------------------------------------------------
PATCH_FILES=($(find "${PATCHES_DIR}" -name "*.patch" | sort))

if [[ ${#PATCH_FILES[@]} -eq 0 ]]; then
  info "No .patch files found in ${PATCHES_DIR}."
  info "Attempting to generate patches from EVL tree via gen-patch.sh ..."
  echo ""

  GEN_PATCH_SCRIPT="${REPO_ROOT}/scripts/patch/gen-patch.sh"
  if [[ ! -f "${GEN_PATCH_SCRIPT}" ]]; then
    die "gen-patch.sh not found at ${GEN_PATCH_SCRIPT}"
  fi

  if [[ ! -d "${EVL_KERNEL_DIR}/.git" ]]; then
    warn "EVL kernel tree not found at ${EVL_KERNEL_DIR}."
    warn "Run 00-setup-env.sh first to clone it."
    warn ""
    warn "If RISC-V Dovetail patches are not yet in the EVL tree, obtain them"
    warn "from the EVL mailing list: https://xenomai.org/pipermail/xenomai/"
    warn "Search: 'riscv dovetail' — save .patch files to ${PATCHES_DIR}/"
    warn "See docs/porting-notes.md section 2 for full details."
    exit 0
  fi

  # Run gen-patch.sh non-interactively; it will auto-unshallow if needed
  bash "${GEN_PATCH_SCRIPT}" --yes

  # Re-scan for patches after generation
  PATCH_FILES=($(find "${PATCHES_DIR}" -name "*.patch" | sort))

  if [[ ${#PATCH_FILES[@]} -eq 0 ]]; then
    warn ""
    warn "gen-patch.sh found no RISC-V Dovetail commits in the EVL tree."
    warn ""
    warn "STATUS: As of 2026-03, RISC-V Dovetail arch hooks (arch/riscv/ hooks,"
    warn "        include/asm-generic/dovetail.h) are NOT yet in any stable EVL"
    warn "        branch. The EVL tree contains kernel/evl/ and kernel/dovetail/"
    warn "        but no arch/riscv/ Dovetail integration."
    warn ""
    warn "NEXT STEPS — obtain patches manually:"
    warn "  1. Check EVL mailing list: https://xenomai.org/pipermail/xenomai/"
    warn "     Search: 'riscv dovetail' — save .patch files to ${PATCHES_DIR}/"
    warn "  2. Re-run: bash scripts/build/01-apply-patches.sh"
    warn ""
    warn "  See docs/porting-notes.md section 2 for full details."
    exit 0
  fi

  info "Generated ${#PATCH_FILES[@]} patch(es). Proceeding to apply ..."
  echo ""
fi

info "Applying ${#PATCH_FILES[@]} patch(es) ..."
FAILED_PATCHES=()

for patch in "${PATCH_FILES[@]}"; do
  patch_name=$(basename "${patch}")
  info "  Applying: ${patch_name}"

  if git apply --check "${patch}" 2>/dev/null; then
    git apply "${patch}"
    ok "    Applied: ${patch_name}"
  else
    warn "    CONFLICT: ${patch_name} — attempting 3-way merge ..."
    if git apply --3way "${patch}" 2>/dev/null; then
      ok "    Applied (3-way): ${patch_name}"
    else
      warn "    FAILED: ${patch_name} — manual resolution required."
      FAILED_PATCHES+=("${patch_name}")
    fi
  fi
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ ${#FAILED_PATCHES[@]} -gt 0 ]]; then
  echo ""
  warn "The following patches failed to apply:"
  for p in "${FAILED_PATCHES[@]}"; do
    warn "  - ${p}"
  done
  warn "Resolve conflicts manually, then run:"
  warn "  touch ${APPLIED_MARKER}"
  warn "  bash scripts/build/02-configure.sh"
  exit 1
fi

touch "${APPLIED_MARKER}"
ok "All patches applied successfully."

echo ""
echo "============================================================"
echo "  Patches applied on branch: ${EVL_BRANCH}"
echo ""
echo "  Next step:"
echo "    bash scripts/build/02-configure.sh"
echo "============================================================"
