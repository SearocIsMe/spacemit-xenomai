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
#   --base-tree <dir> Vanilla kernel tree to diff against (filesystem diff mode)
#                     default: $KERNEL_DIR (SpacemiT kernel)
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
BASE_TREE="${KERNEL_DIR:-${HOME}/work/linux-k1}"
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
    --from)       FROM_COMMIT="$2"; shift 2 ;;
    --to)         TO_COMMIT="$2";   shift 2 ;;
    --tree)       GIT_TREE="$2";    shift 2 ;;
    --base-tree)  BASE_TREE="$2";   shift 2 ;;
    --out)        OUTPUT_DIR="$2";  shift 2 ;;
    --grep)       GREP_PATTERN="$2"; shift 2 ;;
    --yes|-y)     YES=1; shift ;;
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
# Check shallow clone — note it but do NOT attempt unshallow automatically.
# Unshallowing a kernel repo downloads ~1 GB and is unreliable on slow links.
# The filesystem diff fallback works fine with a shallow clone.
# To unshallow manually: cd ~/work/linux-evl && git fetch --unshallow
# ---------------------------------------------------------------------------
_STILL_SHALLOW=0
if git rev-parse --is-shallow-repository 2>/dev/null | grep -q "true"; then
  _STILL_SHALLOW=1
  info "EVL repo is a shallow clone — will use filesystem diff (no unshallow needed)."
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
# List commits to extract (skip if still shallow — go straight to fs diff)
# ---------------------------------------------------------------------------
_STILL_SHALLOW=0
git rev-parse --is-shallow-repository 2>/dev/null | grep -q "true" && _STILL_SHALLOW=1

GREP_ARGS=()
if [[ -n "${GREP_PATTERN}" ]]; then
  GREP_ARGS=(--grep="${GREP_PATTERN}")
fi

COMMITS=""
if [[ ${_STILL_SHALLOW} -eq 1 ]]; then
  warn "Repository is still shallow — skipping git log, using filesystem diff."
else
  info "Listing commits from ${FROM_COMMIT}..${TO_COMMIT} in ${GIT_TREE} ..."
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
fi

if [[ -z "${COMMITS}" ]]; then
  warn "No commits found via git log (repo may still be shallow or RISC-V"
  warn "Dovetail hooks not yet present in this EVL branch)."
  warn ""

  # ---------------------------------------------------------------------------
  # Fallback: filesystem diff between EVL tree and SpacemiT kernel tree
  # This works even with a shallow clone — no git history needed.
  # ---------------------------------------------------------------------------
  if [[ -d "${BASE_TREE}" ]]; then
    info "Falling back to filesystem diff: EVL tree vs SpacemiT kernel tree ..."
    info "  EVL tree  : ${GIT_TREE}"
    info "  Base tree : ${BASE_TREE}"

    _DIFF_PATHS=(
      "kernel/dovetail"
      "kernel/evl"
      "include/linux/dovetail.h"
      "include/linux/irq_pipeline.h"
      "include/asm-generic/dovetail.h"
      "arch/riscv/include/asm/dovetail.h"
    )

    _diff_output=""
    for _path in "${_DIFF_PATHS[@]}"; do
      _evl_path="${GIT_TREE}/${_path}"
      _base_path="${BASE_TREE}/${_path}"
      if [[ -e "${_evl_path}" ]]; then
        if [[ -e "${_base_path}" ]]; then
          # File/dir exists in both — diff them
          _diff_output+=$(diff -ruN "${_base_path}" "${_evl_path}" \
            --label "a/${_path}" --label "b/${_path}" 2>/dev/null || true)
        else
          # New file/dir in EVL — diff against /dev/null
          if [[ -d "${_evl_path}" ]]; then
            while IFS= read -r -d '' _f; do
              _rel="${_f#${GIT_TREE}/}"
              _diff_output+=$(diff -uN /dev/null "${_f}" \
                --label "a/${_rel}" --label "b/${_rel}" 2>/dev/null || true)
            done < <(find "${_evl_path}" -type f -print0)
          else
            _rel="${_evl_path#${GIT_TREE}/}"
            _diff_output+=$(diff -uN /dev/null "${_evl_path}" \
              --label "a/${_rel}" --label "b/${_rel}" 2>/dev/null || true)
          fi
        fi
      fi
    done

    if [[ -z "${_diff_output}" ]]; then
      warn "Filesystem diff also found no EVL-specific files."
      warn "RISC-V Dovetail arch hooks are not yet in this EVL tree."
      warn ""
      warn "Obtain patches from the EVL mailing list:"
      warn "  https://xenomai.org/pipermail/xenomai/"
      warn "  Search: 'riscv dovetail' — save .patch files to ${OUTPUT_DIR}/"
      warn "  See docs/porting-notes.md section 2 for full details."
      exit 0
    fi

    _patch_file="${OUTPUT_DIR}/0001-evl-dovetail-from-filesystem-diff.patch"
    echo "From: gen-patch.sh filesystem diff" > "${_patch_file}"
    echo "Date: $(date -R)" >> "${_patch_file}"
    echo "Subject: [PATCH] EVL Dovetail infrastructure (filesystem diff)" >> "${_patch_file}"
    echo "" >> "${_patch_file}"
    echo "Generated by gen-patch.sh filesystem diff mode." >> "${_patch_file}"
    echo "EVL tree: ${GIT_TREE}" >> "${_patch_file}"
    echo "Base tree: ${BASE_TREE}" >> "${_patch_file}"
    echo "---" >> "${_patch_file}"
    echo "${_diff_output}" >> "${_patch_file}"

    ok "Filesystem diff patch written to ${_patch_file}"
    echo ""
    echo "============================================================"
    echo "  Done! Review patch in ${OUTPUT_DIR}/"
    echo "  Then run: bash scripts/build/01-apply-patches.sh"
    echo "============================================================"
    exit 0
  else
    warn "Base kernel tree not found at ${BASE_TREE}."
    warn "Run 00-setup-env.sh first, or use --base-tree <dir>."
    warn ""
    warn "To list all EVL-related commits manually:"
    warn "  cd ${GIT_TREE}"
    warn "  git log --oneline ${FROM_COMMIT}..HEAD -- arch/riscv/ kernel/evl/"
    exit 0
  fi
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
