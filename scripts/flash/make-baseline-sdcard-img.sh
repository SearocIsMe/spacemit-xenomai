#!/usr/bin/env bash
# =============================================================================
# make-baseline-sdcard-img.sh
#
# Build the safest first-boot Jupiter SD card image by reusing the
# make-full-sdcard-img.sh pipeline with TEST_PROFILE=kernel-only.
# This profile replaces only Image + DTBs and preserves the boot flow and
# rootfs from the known-good base image.
#
# Usage:
#   bash scripts/flash/make-baseline-sdcard-img.sh <base_image> [build_dir] [output_dir]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <base_image> [build_dir] [output_dir]"
  exit 1
fi

TEST_PROFILE=kernel-only \
IMAGE_TAG=baseline \
  bash "${SCRIPT_DIR}/make-full-sdcard-img.sh" "$@"
