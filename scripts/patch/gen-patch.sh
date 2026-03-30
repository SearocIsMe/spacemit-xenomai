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
#   --from <commit>   Base commit (exclusive) — default: v6.6.63 tag
#   --to   <commit>   End commit (inclusive)  — default: HEAD
#   --tree <dir>      Git tree to extract from — default: $EVL_KERNEL_DIR
#   --out  <dir>      Output directory         — default: patches/
#   --grep <pattern>  Only include commits matching pattern in subject
#   --yes             Non-interactive: skip confirmation prompt
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
YES=0

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
    --yes|-y) YES=1; shift ;;
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
# Handle shallow clone — unshallow if needed
# ---------------------------------------------------------------------------
if git rev-parse --is-shallow-repository 2>/dev/null | grep -q "true"; then
  warn "Repository is a shallow clone. Fetching full history (this may take a while) ..."
  git fetch --unshallow 2>&1 | grep -E "^(remote:|Receiving|Resolving|Updating)" || true
  if git rev-parse --is-shallow-repository 2>/dev/null | grep -q "true"; then
    warn "Unshallow may still be in progress or failed. Continuing with available history."
  else
    ok "Unshallow complete."
  fi
fi

# ---------------------------------------------------------------------------
# Determine base commit if not specified
# ---------------------------------------------------------------------------
if [[ -z "${FROM_COMMIT}" ]]; then
  # Try plain kernel version tags first (v6.6.63, v6.6, v6.6.0)
  for _base_tag in "v6.6.63" "v6.6" "v6.6.0"; do
    if git rev-parse "${_base_tag}" &>/dev/null; then
      FROM_COMMIT="${_base_tag}"
      info "Auto-detected base commit: ${_base_tag}"
      break
    fi
  done

  # If not found, try to derive base from EVL rebase tag (e.g. v6.6.63-evl2-rebase)
  # The base is the parent of the oldest EVL commit on top of the vanilla kernel
  if [[ -z "${FROM_COMMIT}" ]]; then
    # Look for a tag matching v<x>.<y>.<z>-evl*-rebase and strip the EVL suffix
    _evl_tag=$(git tag | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+-evl[0-9]*-rebase$" | sort -V | tail -1)
    if [[ -n "${_evl_tag}" ]]; then
      # The vanilla base version embedded in the tag name (e.g. v6.6.63-evl2-rebase → v6.6.63)
      _base_ver=$(echo "${_evl_tag}" | sed 's/-evl[0-9]*-rebase$//')
      info "EVL rebase tag found: ${_evl_tag} — using embedded base version: ${_base_ver}"
      # Find the oldest ancestor commit whose subject doesn't start with "evl/" or "dovetail/"
      # i.e. the vanilla kernel tip this was rebased on
      _base_commit=$(git log --oneline --reverse "${_evl_tag}" \
        | grep -v -E "^[0-9a-f]+ (evl/|dovetail/|irq_pipeline:|Dovetail:)" \
        | tail -1 | awk '{print $1}')
      if [[ -n "${_base_commit}" ]]; then
        FROM_COMMIT="${_base_commit}"
        info "Auto-detected vanilla base commit from EVL tag: ${FROM_COMMIT} (${_base_ver})"
      else
        # Fallback: use the parent of the first commit in the log
        FROM_COMMIT=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
        if [[ -n "${FROM_COMMIT}" ]]; then
          info "Using root commit as base: ${FROM_COMMIT:0:12}"
        fi
      fi
    fi
  fi

  if [[ -z "${FROM_COMMIT}" ]]; then
    die "Cannot auto-detect base commit. Use --from <commit> (e.g. --from v6.6.63)."
  fi
fi

# ---------------------------------------------------------------------------
# List commits to extract
# ---------------------------------------------------------------------------
info "Listing commits from ${FROM_COMMIT}..${TO_COMMIT} in ${GIT_TREE} ..."

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
  warn "  git log --oneline ${FROM_COMMIT}..HEAD -- arch/riscv/ kernel/evl/"
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
if [[ ${YES} -eq 0 ]]; then
  read -rp "Generate ${COMMIT_COUNT} patch file(s) to ${OUTPUT_DIR}/? [y/N]: " CONFIRM
  [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
else
  info "Non-interactive mode (--yes): generating ${COMMIT_COUNT} patch file(s) ..."
fi

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
