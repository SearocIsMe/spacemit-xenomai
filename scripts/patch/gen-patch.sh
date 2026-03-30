#!/usr/bin/env bash
# =============================================================================
# gen-patch.sh
# Helper to extract patches from the EVL kernel tree (or any git tree)
# and save them into the patches/ directory of this repo.
#
# Usage:
#   bash scripts/patch/gen-patch.sh [options]
#
# Options:
#   --from <commit>   Base commit (exclusive) — default: merge-base with upstream
#   --to   <commit>   End commit (inclusive)  — default: HEAD
#   --tree <dir>      Git tree to extract from — default: $EVL_KERNEL_DIR
#   --out  <dir>      Output directory         — default: patches/
#   --grep <pattern>  Only include commits matching pattern in subject
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/../build/env.sh"

# ---------------------------------------------------------------------------
# Load environment (optional — for default paths)
# ---------------------------------------------------------------------------
if [[ -f "${ENV_FILE}" ]]; then
  source "${ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
GIT_TREE="${EVL_KERNEL_DIR:-${HOME}/work/linux-evl}"
OUTPUT_DIR="${REPO_ROOT}/patches"
FROM_COMMIT=""
TO_COMMIT="HEAD"
GREP_PATTERN=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)  FROM_COMMIT="$2"; shift 2 ;;
    --to)    TO_COMMIT="$2";   shift 2 ;;
    --tree)  GIT_TREE="$2";    shift 2 ;;
    --out)   OUTPUT_DIR="$2";  shift 2 ;;
    --grep)  GREP_PATTERN="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
[[ -d "${GIT_TREE}/.git" ]] || die "Git tree not found: ${GIT_TREE}"
mkdir -p "${OUTPUT_DIR}"

cd "${GIT_TREE}"

# ---------------------------------------------------------------------------
# Determine base commit if not specified
# ---------------------------------------------------------------------------
if [[ -z "${FROM_COMMIT}" ]]; then
  # Try to find merge-base with v6.6 tag
  if git rev-parse "v6.6" &>/dev/null; then
    FROM_COMMIT=$(git merge-base "v6.6" "${TO_COMMIT}")
    info "Auto-detected base commit (merge-base with v6.6): ${FROM_COMMIT:0:12}"
  else
    die "Cannot auto-detect base commit. Use --from <commit>."
  fi
fi

# ---------------------------------------------------------------------------
# List commits to extract
# ---------------------------------------------------------------------------
info "Listing commits from ${FROM_COMMIT:0:12}..${TO_COMMIT} in ${GIT_TREE} ..."

GREP_ARGS=()
if [[ -n "${GREP_PATTERN}" ]]; then
  GREP_ARGS=(--grep="${GREP_PATTERN}")
fi

COMMITS=$(git log \
  --oneline \
  --reverse \
  "${GREP_ARGS[@]}" \
  "${FROM_COMMIT}..${TO_COMMIT}" \
  -- \
  arch/riscv/ \
  include/asm-generic/dovetail.h \
  include/linux/dovetail.h \
  include/linux/irq_pipeline.h \
  kernel/dovetail/ \
  kernel/evl/ \
  2>/dev/null)

if [[ -z "${COMMITS}" ]]; then
  warn "No commits found matching the criteria."
  warn "Try adjusting --from, --to, or --grep options."
  warn ""
  warn "To list all EVL-related commits manually:"
  warn "  cd ${GIT_TREE}"
  warn "  git log --oneline v6.6..HEAD -- arch/riscv/ kernel/evl/"
  exit 0
fi

COMMIT_COUNT=$(echo "${COMMITS}" | wc -l)
info "Found ${COMMIT_COUNT} commit(s):"
echo "${COMMITS}" | while read -r line; do
  echo "    ${line}"
done

# ---------------------------------------------------------------------------
# Generate patches
# ---------------------------------------------------------------------------
echo ""
read -rp "Generate ${COMMIT_COUNT} patch file(s) to ${OUTPUT_DIR}/? [y/N]: " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

info "Generating patches ..."
git format-patch \
  --output-directory "${OUTPUT_DIR}" \
  --numbered \
  "${GREP_ARGS[@]}" \
  "${FROM_COMMIT}..${TO_COMMIT}" \
  -- \
  arch/riscv/ \
  include/asm-generic/dovetail.h \
  include/linux/dovetail.h \
  include/linux/irq_pipeline.h \
  kernel/dovetail/ \
  kernel/evl/

ok "Patches written to ${OUTPUT_DIR}/"
ls -1 "${OUTPUT_DIR}"/*.patch 2>/dev/null | while read -r p; do
  echo "    $(basename "${p}")"
done

echo ""
echo "============================================================"
echo "  Done! Review patches in ${OUTPUT_DIR}/"
echo "  Then run: bash scripts/build/01-apply-patches.sh"
echo "============================================================"
