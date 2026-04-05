#!/usr/bin/env bash
# =============================================================================
# make-test-matrix.sh
#
# Build a staged set of Jupiter SD-card images so we can bisect boot failures
# without UART:
#
#   1. kernel-only  - Replace only Image + DTBs
#   2. env-debug    - kernel-only + patch env_k1-x.txt for verbose bootargs
#   3. boot-debug   - env-debug + patch extlinux/initramfs
#   4. full-evl     - boot-debug + inject modules + rootfs compatibility edits
#
# Usage:
#   sudo bash scripts/flash/make-test-matrix.sh <base_image> [build_dir] [output_dir]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="${1:-}"
BUILD_DIR="${2:-${HOME}/work/build-k1}"
OUTPUT_DIR="${3:-/tmp}"

if [[ -z "${BASE_IMAGE}" ]]; then
  echo "Usage: $0 <base_image> [build_dir] [output_dir]"
  exit 1
fi

profiles=(
  "kernel-only"
  "env-debug"
  "boot-debug"
  "full-evl"
)

for profile in "${profiles[@]}"; do
  echo ""
  echo "============================================================"
  echo "Building test profile: ${profile}"
  echo "============================================================"
  TEST_PROFILE="${profile}" \
  IMAGE_TAG="${profile}" \
    bash "${SCRIPT_DIR}/make-full-sdcard-img.sh" \
      "${BASE_IMAGE}" \
      "${BUILD_DIR}" \
      "${OUTPUT_DIR}"
done

echo ""
echo "Completed test matrix build in ${OUTPUT_DIR}"
