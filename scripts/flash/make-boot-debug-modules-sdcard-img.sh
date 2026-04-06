#!/usr/bin/env bash
# =============================================================================
# make-boot-debug-modules-sdcard-img.sh
#
# Build a Jupiter SD card image for no-UART bring-up that:
#   - rewrites extlinux/env/initramfs for maximum visible boot logging
#   - injects matching kernel modules
#   - avoids rootfs compatibility edits used by full-evl
#
# Usage:
#   bash scripts/flash/make-boot-debug-modules-sdcard-img.sh <base_image> [build_dir] [output_dir]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <base_image> [build_dir] [output_dir]"
  exit 1
fi

TEST_PROFILE=boot-debug-modules \
IMAGE_TAG=boot-debug-modules \
  bash "${SCRIPT_DIR}/make-full-sdcard-img.sh" "$@"
