#!/usr/bin/env bash
# =============================================================================
# 04-build-sdk.sh
#
# Build the complete SpacemiT K1 / Milk-V Jupiter SDK from source using the
# official milkv-jupiter repo manifest and buildroot build system.
#
# This produces a full SD card image that includes:
#   - FSBL (from U-Boot SPL)
#   - OpenSBI
#   - U-Boot
#   - Buildroot-based rootfs (Bianbu-compatible, spacemit_k1_v2_defconfig)
#
# We use spacemit_k1_v2_defconfig as documented at:
#   https://milkv.io/docs/jupiter/build-os/buildroot
# This is the standard defconfig for the Milk-V Jupiter / SpacemiT K1 platform.
#
# How the SpacemiT build system works (from scripts/Makefile):
#   make envconfig
#     → interactive menu → user picks spacemit_k1_v2_defconfig
#     → runs: make -C ./buildroot O=../output/k1_v2 \
#                  BR2_EXTERNAL=../buildroot-ext spacemit_k1_v2_defconfig
#     → writes env.mk: MAKEFILE=output/k1_v2/Makefile
#   make
#     → reads env.mk → make -C output/k1_v2
#
# This script replicates that non-interactively.
#
# Usage:
#   bash scripts/build/04-build-sdk.sh [work_dir]
#
#   work_dir  Where to clone the SDK (default: ~/work/jupiter-linux)
#             Must be on a native Linux filesystem (not /mnt/c/...)
#
# After this script completes, run:
#   bash scripts/flash/make-full-sdcard-img.sh \
#     ~/work/jupiter-linux/output/k1_v2/images/sdcard.img \
#     ~/work/build-k1 \
#     /mnt/c/Users/haipeng/Downloads
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }
step() { echo -e "\n\033[1;35m════════════════════════════════════════\033[0m"
         echo -e "\033[1;35m  $*\033[0m"
         echo -e "\033[1;35m════════════════════════════════════════\033[0m"; }

# ---------------------------------------------------------------------------
# Guard: refuse to run under /mnt/c/ (Windows FS — no exec permissions)
# ---------------------------------------------------------------------------
_work_arg="${1:-}"
if [[ "${_work_arg}" == /mnt/* ]] || [[ "$PWD" == /mnt/* ]]; then
  die "Running from Windows-mounted path. Use a WSL2 native path like ~/work/jupiter-linux"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SDK_DIR="${_work_arg:-${HOME}/work/jupiter-linux}"

MANIFEST_URL="https://github.com/milkv-jupiter/manifests.git"
MANIFEST_BRANCH="main"
MANIFEST_FILE="k1-bl-v2.1.y.xml"
SDK_BRANCH="k1-bl-v2.1.y"

# The buildroot defconfig to use.
# spacemit_k1_v2_defconfig = standard Milk-V Jupiter / SpacemiT K1 defconfig
# as documented at https://milkv.io/docs/jupiter/build-os/buildroot
# Other options: spacemit_k1_minimal_defconfig, spacemit_k1_rt_defconfig, spacemit_k1_plt_defconfig
DEFCONFIG="spacemit_k1_v2_defconfig"

# Derived from defconfig name: spacemit_k1_v2_defconfig → k1_v2
OUTPUT_NAME=$(echo "${DEFCONFIG}" | sed -E 's/spacemit_(.*)_defconfig/\1/')
OUTPUT_DIR="${SDK_DIR}/output/${OUTPUT_NAME}"

JOBS=$(nproc)

# ---------------------------------------------------------------------------
# Step 0: Check prerequisites
# ---------------------------------------------------------------------------
step "Step 0: Checking prerequisites"

# Always ensure build dependencies are present.
# python3-dev is required by kmod (and other packages) even when python3
# the interpreter is already installed.
info "Ensuring build dependencies are installed ..."
sudo apt-get update -qq
sudo apt-get install -y \
  git build-essential cpio unzip rsync file bc wget \
  python3 python-is-python3 python3-dev python3-pip \
  libncurses5-dev libncursesw5-dev libssl-dev zlib1g-dev \
  dosfstools mtools u-boot-tools flex bison zip \
  device-tree-compiler xz-utils pkg-config libelf-dev

_missing=()
for _tool in git make python3 rsync cpio bc flex bison; do
  command -v "${_tool}" &>/dev/null || _missing+=("${_tool}")
done
if [[ ${#_missing[@]} -gt 0 ]]; then
  die "Still missing tools after apt install: ${_missing[*]}"
fi

# pyyaml is required by the SpacemiT build system
if ! python3 -c "import yaml" &>/dev/null; then
  info "Installing pyyaml ..."
  pip3 install --quiet pyyaml 2>/dev/null || sudo pip3 install --quiet pyyaml
fi

# Check for 'repo' tool (Google repo, not apt repo)
if ! command -v repo &>/dev/null; then
  info "Installing Google 'repo' tool ..."
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    -o "${HOME}/.local/bin/repo"
  chmod +x "${HOME}/.local/bin/repo"
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v repo &>/dev/null || die "'repo' tool install failed."
fi

ok "All prerequisites satisfied."

# ---------------------------------------------------------------------------
# Step 1: Create SDK directory and initialise repo manifest
# ---------------------------------------------------------------------------
step "Step 1: Initialising SpacemiT SDK repo manifest"

mkdir -p "${SDK_DIR}"
cd "${SDK_DIR}"

if [[ -d ".repo" ]]; then
  warn "Repo already initialised at ${SDK_DIR} — skipping repo init."
else
  info "Initialising repo from ${MANIFEST_URL}"
  info "  branch  : ${MANIFEST_BRANCH}"
  info "  manifest: ${MANIFEST_FILE}"
  repo init \
    -u "${MANIFEST_URL}" \
    -b "${MANIFEST_BRANCH}" \
    -m "${MANIFEST_FILE}" \
    --no-clone-bundle \
    || die "repo init failed. Check network connectivity to github.com."
  ok "Repo initialised."
fi

# ---------------------------------------------------------------------------
# Step 2: Sync all repositories
# ---------------------------------------------------------------------------
step "Step 2: Syncing all SDK repositories (repo sync)"
info "Repos: linux-6.6, uboot-2022.10, opensbi, buildroot, buildroot-ext, package-src/..."
info "This downloads the full SpacemiT SDK — may take 20-60 minutes."

repo sync \
  --jobs=4 \
  --force-sync \
  --no-clone-bundle \
  --no-tags \
  || die "repo sync failed. Check network connectivity."

ok "All repositories synced."

# ---------------------------------------------------------------------------
# Step 3: Start the SDK branch on all repos
# ---------------------------------------------------------------------------
step "Step 3: Starting branch ${SDK_BRANCH} on all repos"

repo start "${SDK_BRANCH}" --all 2>/dev/null || \
  warn "repo start returned non-zero (may already be on branch) — continuing."

ok "Branch started."

# ---------------------------------------------------------------------------
# WSL2 PATH sanitization
#
# Buildroot explicitly rejects a PATH that contains spaces, TABs, or newlines.
# In WSL2, the Windows PATH is appended (e.g. /mnt/c/Program Files/...) which
# contains spaces.  We strip all PATH entries that contain spaces or that start
# with /mnt/ (Windows drives) before running any make commands.
# We also ensure ~/.local/bin is first so cmake/repo installed there are found.
# ---------------------------------------------------------------------------
_clean_path=""
while IFS= read -r -d: _p; do
  [[ "${_p}" == *" "* ]] && continue        # skip entries with spaces
  [[ "${_p}" == /mnt/* ]] && continue       # skip Windows /mnt/c/ etc.
  [[ "${_p}" == */anaconda3/* ]] && continue  # skip Anaconda subdirs (bin, lib…)
  [[ "${_p}" == */anaconda3 ]]   && continue  # skip Anaconda root itself
  [[ "${_p}" == */conda/* ]]     && continue  # skip conda envs
  [[ -z "${_p}" ]] && continue
  _clean_path="${_clean_path:+${_clean_path}:}${_p}"
done <<< "${PATH}:"
# Prepend standard Linux paths + ~/.local/bin (for cmake, repo)
export PATH="${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${_clean_path}"
info "PATH sanitized (removed Windows /mnt/ entries and Anaconda paths)."

# ---------------------------------------------------------------------------
# Anaconda isolation
#
# Buildroot bootstraps cmake 3.22.3 from source.  During that bootstrap,
# cmake's own test suite calls find_package(Qt5Widgets).  cmake scans
# filesystem prefix paths (including ~/anaconda3/lib/cmake/) regardless of
# PATH or env-var settings, so the only reliable way to hide Anaconda's Qt5
# cmake config files is to temporarily rename them for the duration of the
# build, then restore them via a trap on EXIT.
# ---------------------------------------------------------------------------
unset CMAKE_PREFIX_PATH CMAKE_FRAMEWORK_PATH
unset Qt5_DIR Qt5Core_DIR Qt5Gui_DIR Qt5Widgets_DIR
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR
unset PYTHONPATH PYTHONHOME
if command -v /usr/bin/python3 &>/dev/null; then
  export PYTHON=/usr/bin/python3
fi
info "Anaconda environment variables cleared."

# Collect Anaconda Qt5/Qt cmake config dirs that would poison the bootstrap.
_ANACONDA_CMAKE_DIR="${HOME}/anaconda3/lib/cmake"
_HIDDEN_CMAKE_DIRS=()

_hide_anaconda_cmake() {
  if [[ ! -d "${_ANACONDA_CMAKE_DIR}" ]]; then return; fi
  info "Temporarily hiding Anaconda Qt cmake dirs to prevent cmake bootstrap conflict ..."
  while IFS= read -r -d '' _d; do
    local _hidden="${_d}.buildroot_hidden"
    if [[ -d "${_d}" && ! -d "${_hidden}" ]]; then
      mv "${_d}" "${_hidden}"
      _HIDDEN_CMAKE_DIRS+=("${_d}")
      info "  hidden: ${_d}"
    fi
  done < <(find "${_ANACONDA_CMAKE_DIR}" -maxdepth 1 -type d \( \
    -iname 'Qt5*' -o -iname 'Qt6*' -o -iname 'Qt*' \
    \) -print0 2>/dev/null)
}

_restore_anaconda_cmake() {
  for _d in "${_HIDDEN_CMAKE_DIRS[@]:-}"; do
    [[ -z "${_d}" ]] && continue
    local _hidden="${_d}.buildroot_hidden"
    if [[ -d "${_hidden}" ]]; then
      mv "${_hidden}" "${_d}"
      info "  restored: ${_d}"
    fi
  done
}

# If a previous cmake bootstrap attempt left a poisoned stamp, remove it so
# buildroot re-runs the configure step with the clean environment above.
_cmake_stamp="${OUTPUT_DIR}/build/host-cmake-3.22.3/.stamp_configured"
if [[ -f "${_cmake_stamp}" ]]; then
  warn "Removing stale cmake bootstrap stamp (previous failed configure): ${_cmake_stamp}"
  rm -f "${_cmake_stamp}"
fi

# ---------------------------------------------------------------------------
# kmod Python workaround
#
# When BR2_PACKAGE_PYTHON3=y, kmod.mk unconditionally appends --enable-python
# to kmod's configure flags.  kmod's AM_PATH_PYTHON autoconf macro then
# requires python3-embed.pc to be present in the target staging sysroot, but
# the cross-compiled python3 buildroot package does not install that file,
# so configure fails with "python support requested but libraries not found".
#
# local.mk is not supported by this buildroot version.
# The fix is to patch kmod.mk directly (sed in-place) to replace
# --enable-python with --disable-python before the build starts, and restore
# the original file via the EXIT trap.
# ---------------------------------------------------------------------------
_KMOD_MK="${SDK_DIR}/buildroot/package/kmod/kmod.mk"
_KMOD_MK_BACKUP="${_KMOD_MK}.orig_backup"

_patch_kmod_mk() {
  if [[ ! -f "${_KMOD_MK}" ]]; then
    warn "kmod.mk not found at ${_KMOD_MK} — skipping Python workaround."
    return
  fi
  if grep -q -- "--enable-python" "${_KMOD_MK}"; then
    info "Patching kmod.mk: replacing --enable-python with --disable-python"
    cp -f "${_KMOD_MK}" "${_KMOD_MK_BACKUP}"
    sed -i 's/--enable-python/--disable-python/g' "${_KMOD_MK}"
    ok "kmod.mk patched."
  else
    info "kmod.mk already uses --disable-python or has no --enable-python — no patch needed."
  fi
}

_restore_kmod_mk() {
  if [[ -f "${_KMOD_MK_BACKUP}" ]]; then
    mv -f "${_KMOD_MK_BACKUP}" "${_KMOD_MK}"
    info "kmod.mk restored from backup."
  fi
}

# Register a single EXIT trap covering both restores.
trap '_restore_anaconda_cmake; _restore_kmod_mk' EXIT

# Now apply both workarounds (after trap is set so restores always run).
_hide_anaconda_cmake
_patch_kmod_mk

# Remove a stale kmod configure stamp so buildroot re-runs configure with
# --disable-python now in kmod.mk.
_kmod_stamp="${OUTPUT_DIR}/build/kmod-30/.stamp_configured"
if [[ -f "${_kmod_stamp}" ]]; then
  warn "Removing stale kmod configure stamp: ${_kmod_stamp}"
  rm -f "${_kmod_stamp}"
fi

# ---------------------------------------------------------------------------
# Step 4: Configure buildroot (non-interactive equivalent of make envconfig)
#
# What make envconfig does interactively:
#   make -C ./buildroot O=../output/k1_v2 \
#        BR2_EXTERNAL=../buildroot-ext spacemit_k1_v2_defconfig
#   echo "MAKEFILE=output/k1_v2/Makefile" > env.mk
# ---------------------------------------------------------------------------
step "Step 4: Configuring buildroot (${DEFCONFIG})"

if [[ -f "${SDK_DIR}/env.mk" ]]; then
  warn "env.mk already exists — build already configured."
  warn "Contents: $(cat "${SDK_DIR}/env.mk")"
  warn "To reconfigure: rm ${SDK_DIR}/env.mk && re-run this script."
else
  info "Running: make -C buildroot O=../output/${OUTPUT_NAME} BR2_EXTERNAL=../buildroot-ext ${DEFCONFIG}"
  info "(spacemit_k1_plt_defconfig builds FSBL/U-Boot for Milk-V Jupiter hardware)"
  mkdir -p "${OUTPUT_DIR}"

  make -C "${SDK_DIR}/buildroot" \
    O="../output/${OUTPUT_NAME}" \
    BR2_EXTERNAL="../buildroot-ext" \
    "${DEFCONFIG}" \
    || die "buildroot defconfig failed."

  # Write env.mk (same as what make envconfig writes)
  echo "MAKEFILE=output/${OUTPUT_NAME}/Makefile" > "${SDK_DIR}/env.mk"
  ok "env.mk written: MAKEFILE=output/${OUTPUT_NAME}/Makefile"
fi

ok "Build configured with ${DEFCONFIG}."

# ---------------------------------------------------------------------------
# Step 5: Full build
# ---------------------------------------------------------------------------
step "Step 5: Full SDK build (make -C output/${OUTPUT_NAME})"
info "This builds: OpenSBI → U-Boot → Linux kernel → buildroot rootfs → SD image"
info "Expected time: 1-4 hours depending on CPU speed and network."
info "Output will be in: ${OUTPUT_DIR}/images/"

make -C "${OUTPUT_DIR}" \
  || die "Full SDK build failed. Check output above for errors."

ok "Full SDK build complete."

# ---------------------------------------------------------------------------
# Step 6: Locate output image
# ---------------------------------------------------------------------------
step "Step 6: Locating output image"

IMG=""
for _candidate in \
    "${OUTPUT_DIR}/images/sdcard.img" \
    "${OUTPUT_DIR}/images/"*sdcard*.img \
    "${OUTPUT_DIR}/images/"*.img; do
  if [[ -f "${_candidate}" ]]; then
    IMG="${_candidate}"
    break
  fi
done

if [[ -z "${IMG}" ]]; then
  warn "Could not find output .img file. Listing ${OUTPUT_DIR}/images/:"
  ls -lh "${OUTPUT_DIR}/images/" 2>/dev/null || \
  ls -lh "${OUTPUT_DIR}/" 2>/dev/null || \
  warn "No output directory found."
  die "Output image not found. Check build output above."
fi

ok "Base SD card image: ${IMG}"
ok "Size: $(du -sh "${IMG}" | cut -f1)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  SpacemiT K1 base SDK image built successfully!"
echo ""
echo "  Output : ${IMG}"
echo "  Size   : $(du -sh "${IMG}" | cut -f1)"
echo ""
echo "  This base image uses the SpacemiT stock kernel."
echo "  To inject the EVL kernel (6.6.63) into this image, run:"
echo ""
echo "    bash scripts/flash/make-full-sdcard-img.sh \\"
echo "      ${IMG} \\"
echo "      ~/work/build-k1 \\"
echo "      /mnt/c/Users/haipeng/Downloads"
echo "============================================================"
