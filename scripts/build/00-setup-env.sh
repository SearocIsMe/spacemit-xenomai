#!/usr/bin/env bash
# =============================================================================
# 00-setup-env.sh
# Clone SpacemiT linux-6.6 kernel and EVL sources into WSL2 native filesystem.
# Must be run from the WSL2 native FS (e.g. ~/work/spacemit-xenomai/).
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Guard: refuse to run under /mnt/c/ or any Windows-mounted path
# ---------------------------------------------------------------------------
if [[ "$PWD" == /mnt/* ]]; then
  echo "ERROR: You are running from a Windows-mounted path: $PWD"
  echo "       This will cause slow I/O and build failures."
  echo "       Please run from the WSL2 native filesystem, e.g.:"
  echo "         cd ~/work && git clone <this-repo> && cd spacemit-xenomai"
  exit 1
fi

# ---------------------------------------------------------------------------
# Configuration — edit these if needed
# ---------------------------------------------------------------------------
WORK_DIR="${HOME}/work"
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

# RISC-V cross-compiler prefix
CROSS_COMPILE="${TOOLCHAIN_DIR}/bin/riscv64-unknown-linux-gnu-"
# Fallback to system toolchain if custom not downloaded
SYSTEM_CROSS="riscv64-linux-gnu-"

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

if command -v riscv64-linux-gnu-gcc &>/dev/null; then
  ok "System RISC-V toolchain found: $(riscv64-linux-gnu-gcc --version | head -1)"
  CROSS_COMPILE="${SYSTEM_CROSS}"
else
  warn "System RISC-V toolchain not found."
  warn "Install with: sudo apt-get install gcc-riscv64-linux-gnu"
  warn "Or download a pre-built toolchain to ${TOOLCHAIN_DIR}"
  warn "Continuing — you must set CROSS_COMPILE before building."
fi

# ---------------------------------------------------------------------------
# 6. Write environment file (sourced by other scripts)
# ---------------------------------------------------------------------------
ENV_FILE="$(dirname "$0")/env.sh"
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
echo "  Kernel source : ${KERNEL_DIR}"
echo "  EVL kernel    : ${EVL_KERNEL_DIR}"
echo "  libevl        : ${LIBEVL_DIR}"
echo "  Build output  : ${BUILD_DIR}"
echo ""
echo "  Next step:"
echo "    bash scripts/build/01-apply-patches.sh"
echo "============================================================"
