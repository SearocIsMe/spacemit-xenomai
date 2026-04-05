#!/usr/bin/env bash
# =============================================================================
# make-kernel-bisect-images.sh
#
# Produce SD card images from the kernel bisect build directories.
# Each image uses the safest boot path by default: TEST_PROFILE=kernel-only.
# For HDMI-visible kernel logs without UART, run with:
#   TEST_PROFILE_OVERRIDE=env-debug bash scripts/flash/make-kernel-bisect-images.sh ...
#
# Usage:
#   sudo bash scripts/flash/make-kernel-bisect-images.sh <base_image> [output_dir]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/scripts/build/env.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: scripts/build/env.sh not found. Run scripts/build/00-setup-env.sh first."
  exit 1
fi
source "${ENV_FILE}"

BASE_IMAGE="${1:-}"
OUTPUT_DIR="${2:-/tmp}"
TEST_PROFILE_OVERRIDE="${TEST_PROFILE_OVERRIDE:-kernel-only}"

if [[ -z "${BASE_IMAGE}" ]]; then
  echo "Usage: $0 <base_image> [output_dir]"
  exit 1
fi

variants=(
  "vanilla-k1:${WORK_DIR}/build-k1-vanilla"
  "dovetail-nosmp:${WORK_DIR}/build-k1-dovetail-nosmp"
  "dovetail-noidle:${WORK_DIR}/build-k1-dovetail-noidle"
  "dovetail-only:${WORK_DIR}/build-k1-dovetail"
  "evl-off:${WORK_DIR}/build-k1-evl-off"
  "full-evl:${WORK_DIR}/build-k1-evl"
)

for entry in "${variants[@]}"; do
  IFS=":" read -r name build_dir <<<"${entry}"
  echo ""
  echo "============================================================"
  echo "Building image for kernel variant: ${name}"
  echo "  build dir : ${build_dir}"
  echo "============================================================"
  TEST_PROFILE="${TEST_PROFILE_OVERRIDE}" \
  IMAGE_TAG="${name}" \
    bash "${SCRIPT_DIR}/make-full-sdcard-img.sh" \
      "${BASE_IMAGE}" \
      "${build_dir}" \
      "${OUTPUT_DIR}"
done

echo ""
echo "Kernel bisect images completed in ${OUTPUT_DIR} (profile: ${TEST_PROFILE_OVERRIDE})"
