#!/usr/bin/env bash
# =============================================================================
# 00-setup-env.sh
# Clone SpacemiT linux-6.6 kernel and EVL sources into a repo-local .build/
# workspace on a native Linux filesystem.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Guard: refuse to run under /mnt/c/ or any Windows-mounted path
# ---------------------------------------------------------------------------
if [[ "$PWD" == /mnt/* ]]; then
  echo "ERROR: You are running from a Windows-mounted path: $PWD"
  echo "       This will cause slow I/O and build failures."
  echo "       Please run from the WSL2 native filesystem, e.g.:"
  echo "         cd ~ && git clone <this-repo> && cd spacemit-xenomai"
  exit 1
fi

# ---------------------------------------------------------------------------
# Configuration — edit these if needed
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

WORK_DIR="${REPO_ROOT}/.build"
KERNEL_DIR="${WORK_DIR}/linux-k1"
EVL_KERNEL_DIR="${WORK_DIR}/linux-evl"
LIBEVL_DIR="${WORK_DIR}/libevl"
BUILD_DIR="${WORK_DIR}/build-k1"
TOOLCHAIN_DIR="${WORK_DIR}/toolchain"

KERNEL_REPO="https://gitee.com/spacemit-buildroot/linux-6.6-v2.1.y.git"
# k1-bl-v2.1.y is the SpacemiT development branch with all K1-specific
# configs, drivers, and defconfigs (spacemit_k1_v2_defconfig etc.).
# The v6.6.63 tag only points to the vanilla Linux merge base — it has
# no SpacemiT-specific content.
KERNEL_BRANCH="k1-bl-v2.1.y"

# source.denx.de mirror (primary — git.evlproject.org is often unreachable)
# Use the tag that matches our SpacemiT kernel base (v6.6.63)
EVL_KERNEL_REPO="https://source.denx.de/Xenomai/xenomai4/linux-evl.git"
EVL_KERNEL_REPO_FALLBACK="https://git.evlproject.org/linux-evl.git"
# v6.6.63-evl2-rebase: EVL patches rebased on v6.6.63 (matches SpacemiT base)
# Fallback branch for git.evlproject.org which uses different naming
EVL_KERNEL_BRANCH="v6.6.63-evl2-rebase"
EVL_KERNEL_BRANCH_FALLBACK="evl/master"

LIBEVL_REPO="https://source.denx.de/Xenomai/xenomai4/libevl.git"
LIBEVL_REPO_FALLBACK="https://git.evlproject.org/libevl.git"

# RISC-V cross-compiler prefix (riscv-collab pre-built toolchain)
CROSS_COMPILE="${TOOLCHAIN_DIR}/bin/riscv64-unknown-linux-gnu-"
# System toolchain fallback prefix
SYSTEM_CROSS="riscv64-linux-gnu-"
# Minimum GCC version required (SpacemiT K1 uses zicond, needs GCC 13+)
GCC_MIN_VERSION=13
# riscv-collab pre-built toolchain download (Ubuntu 22.04, GCC 14, glibc)
TOOLCHAIN_URL="https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2026.03.28/riscv64-glibc-ubuntu-22.04-gcc.tar.xz"
TOOLCHAIN_ARCHIVE="${WORK_DIR}/riscv64-glibc-gcc.tar.xz"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Create work directories
# ---------------------------------------------------------------------------
info "Creating work directories under ${WORK_DIR} ..."
mkdir -p "${WORK_DIR}" "${BUILD_DIR}" "${TOOLCHAIN_DIR}"

# ---------------------------------------------------------------------------
# 2. Clone SpacemiT kernel (shallow clone to save space)
# ---------------------------------------------------------------------------
if [[ -d "${KERNEL_DIR}/.git" ]]; then
  warn "Kernel already cloned at ${KERNEL_DIR} — skipping."
else
  info "Cloning SpacemiT linux-6.6 (branch: ${KERNEL_BRANCH}) ..."
  info "This may take several minutes depending on your connection."
  git clone \
    --depth=1 \
    --branch "${KERNEL_BRANCH}" \
    "${KERNEL_REPO}" \
    "${KERNEL_DIR}"
  ok "Kernel cloned to ${KERNEL_DIR}"
fi

# ---------------------------------------------------------------------------
# 3. Clone EVL kernel (for reference / cherry-pick of Dovetail patches)
# ---------------------------------------------------------------------------
if [[ -d "${EVL_KERNEL_DIR}/.git" ]]; then
  warn "EVL kernel already cloned at ${EVL_KERNEL_DIR} — skipping."
else
  info "Cloning EVL kernel (branch: ${EVL_KERNEL_BRANCH}) ..."
  info "NOTE: This is a large repo — using --depth=1 for speed."
  _evl_cloned=0
  # Try primary repo with preferred branch, then fallback repo with fallback branch
  for _combo in \
    "${EVL_KERNEL_REPO}|${EVL_KERNEL_BRANCH}" \
    "${EVL_KERNEL_REPO_FALLBACK}|${EVL_KERNEL_BRANCH_FALLBACK}"; do
    _repo="${_combo%%|*}"
    _branch="${_combo##*|}"
    info "Trying ${_repo} (branch/tag: ${_branch}) ..."
    if git clone --depth=1 --branch "${_branch}" "${_repo}" "${EVL_KERNEL_DIR}" 2>/dev/null; then
      ok "EVL kernel cloned from ${_repo} @ ${_branch}"
      _evl_cloned=1
      break
    else
      warn "Clone from ${_repo} @ ${_branch} failed — trying next."
      rm -rf "${EVL_KERNEL_DIR}"
    fi
  done
  if [[ ${_evl_cloned} -eq 0 ]]; then
    warn "EVL kernel clone failed from all mirrors."
    warn "You can manually cherry-pick Dovetail patches later."
    warn "See docs/porting-notes.md for patch sources."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Clone libevl (userspace EVL library)
# ---------------------------------------------------------------------------
if [[ -d "${LIBEVL_DIR}/.git" ]]; then
  warn "libevl already cloned at ${LIBEVL_DIR} — skipping."
else
  info "Cloning libevl ..."
  _libevl_cloned=0
  for _repo in "${LIBEVL_REPO}" "${LIBEVL_REPO_FALLBACK}"; do
    info "Trying ${_repo} ..."
    if git clone "${_repo}" "${LIBEVL_DIR}" 2>/dev/null; then
      ok "libevl cloned from ${_repo}"
      _libevl_cloned=1
      break
    else
      warn "Clone from ${_repo} failed — trying next mirror."
      rm -rf "${LIBEVL_DIR}"
    fi
  done
  if [[ ${_libevl_cloned} -eq 0 ]]; then
    warn "libevl clone failed from all mirrors. You can clone it manually later."
  fi
fi

# ---------------------------------------------------------------------------
# 5. Check / install RISC-V cross-compiler
# ---------------------------------------------------------------------------
info "Checking RISC-V cross-compiler ..."

# Helper: extract GCC major version number
_gcc_major() { "$1" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1; }

_use_custom_toolchain=0

# Check if custom toolchain already installed
if [[ -x "${TOOLCHAIN_DIR}/bin/riscv64-unknown-linux-gnu-gcc" ]]; then
  _ver=$(_gcc_major "${TOOLCHAIN_DIR}/bin/riscv64-unknown-linux-gnu-gcc")
  if [[ "${_ver:-0}" -ge "${GCC_MIN_VERSION}" ]]; then
    ok "Custom toolchain found (GCC ${_ver}): ${TOOLCHAIN_DIR}/bin/riscv64-unknown-linux-gnu-gcc"
    CROSS_COMPILE="${TOOLCHAIN_DIR}/bin/riscv64-unknown-linux-gnu-"
    _use_custom_toolchain=1
  else
    warn "Custom toolchain GCC ${_ver} is too old (need >= ${GCC_MIN_VERSION}) — will re-download."
  fi
fi

# Check system toolchain version
if [[ ${_use_custom_toolchain} -eq 0 ]] && command -v "${SYSTEM_CROSS}gcc" &>/dev/null; then
  _ver=$(_gcc_major "${SYSTEM_CROSS}gcc")
  if [[ "${_ver:-0}" -ge "${GCC_MIN_VERSION}" ]]; then
    ok "System RISC-V toolchain GCC ${_ver} is sufficient: $(${SYSTEM_CROSS}gcc --version | head -1)"
    CROSS_COMPILE="${SYSTEM_CROSS}"
    _use_custom_toolchain=0
  else
    warn "System RISC-V toolchain GCC ${_ver} is too old (need >= ${GCC_MIN_VERSION})."
    warn "SpacemiT K1 kernel uses zicond ISA extension which requires GCC 13+."
    warn "Downloading riscv-collab pre-built toolchain (GCC 14) ..."
    # Download and extract
    if [[ ! -f "${TOOLCHAIN_ARCHIVE}" ]]; then
      info "Downloading: ${TOOLCHAIN_URL}"
      info "This is ~200MB — may take a few minutes ..."
      curl -L --progress-bar -o "${TOOLCHAIN_ARCHIVE}" "${TOOLCHAIN_URL}" \
        || { warn "Download failed. Set CROSS_COMPILE manually."; CROSS_COMPILE="${SYSTEM_CROSS}"; }
    fi
    if [[ -f "${TOOLCHAIN_ARCHIVE}" ]]; then
      info "Extracting toolchain to ${TOOLCHAIN_DIR} ..."
      tar -xf "${TOOLCHAIN_ARCHIVE}" -C "${WORK_DIR}" 2>/dev/null
      # The archive extracts to a subdirectory — find the bin/ dir
      _tc_bin=$(find "${WORK_DIR}" -maxdepth 3 -name "riscv64-unknown-linux-gnu-gcc" 2>/dev/null | head -1)
      if [[ -n "${_tc_bin}" ]]; then
        _tc_dir=$(dirname "${_tc_bin}")
        # Symlink or move to expected location
        if [[ "${_tc_dir}" != "${TOOLCHAIN_DIR}/bin" ]]; then
          _tc_root=$(dirname "${_tc_dir}")
          rm -rf "${TOOLCHAIN_DIR}"
          ln -sfn "${_tc_root}" "${TOOLCHAIN_DIR}"
        fi
        CROSS_COMPILE="${TOOLCHAIN_DIR}/bin/riscv64-unknown-linux-gnu-"
        _ver=$(_gcc_major "${TOOLCHAIN_DIR}/bin/riscv64-unknown-linux-gnu-gcc")
        ok "Toolchain installed: GCC ${_ver} at ${TOOLCHAIN_DIR}"
        _use_custom_toolchain=1
      else
        warn "Could not find riscv64-unknown-linux-gnu-gcc after extraction."
        warn "Falling back to system toolchain (build may fail for zicond)."
        CROSS_COMPILE="${SYSTEM_CROSS}"
      fi
    fi
  fi
fi

if [[ ${_use_custom_toolchain} -eq 0 ]] && ! command -v "${SYSTEM_CROSS}gcc" &>/dev/null; then
  warn "No RISC-V cross-compiler found."
  warn "Install with: sudo apt-get install gcc-riscv64-linux-gnu"
  warn "Or re-run this script to auto-download the riscv-collab toolchain."
  warn "Continuing — you must set CROSS_COMPILE before building."
fi

# ---------------------------------------------------------------------------
# 6. Write environment file (sourced by other scripts)
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/env.sh"
cat > "${ENV_FILE}" <<EOF
# Auto-generated by 00-setup-env.sh — do not edit manually
export WORK_DIR="${WORK_DIR}"
export KERNEL_DIR="${KERNEL_DIR}"
export EVL_KERNEL_DIR="${EVL_KERNEL_DIR}"
export LIBEVL_DIR="${LIBEVL_DIR}"
export BUILD_DIR="${BUILD_DIR}"
export TOOLCHAIN_DIR="${TOOLCHAIN_DIR}"
export ARCH="riscv"
export CROSS_COMPILE="${CROSS_COMPILE}"
export KBUILD_OUTPUT="${BUILD_DIR}"
EOF
ok "Environment file written to ${ENV_FILE}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Setup complete!"
echo "  Repo root      : ${REPO_ROOT}"
echo "  Kernel source : ${KERNEL_DIR}"
echo "  EVL kernel    : ${EVL_KERNEL_DIR}"
echo "  libevl        : ${LIBEVL_DIR}"
echo "  Build output  : ${BUILD_DIR}"
echo ""
echo "  Next step:"
echo "    bash scripts/build/00b-deploy-overlay.sh"
echo "============================================================"
