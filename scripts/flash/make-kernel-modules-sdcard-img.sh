#!/usr/bin/env bash
# =============================================================================
# make-kernel-modules-sdcard-img.sh
#
# Build a bootflow-preserving Jupiter SD card image that replaces:
#   - kernel Image
#   - DTBs
#   - matching kernel modules in rootfs
#
# This is the next diagnostic step after kernel-only. It keeps the base image
# boot configuration and rootfs customizations intact, but avoids ABI mismatch
# between the new kernel and the old module set.
#
# Usage:
#   bash scripts/flash/make-kernel-modules-sdcard-img.sh <base_image> [build_dir] [output_dir]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <base_image> [build_dir] [output_dir]"
  exit 1
fi

TEST_PROFILE=kernel-modules \
IMAGE_TAG=kernel-modules \
  bash "${SCRIPT_DIR}/make-full-sdcard-img.sh" "$@"
