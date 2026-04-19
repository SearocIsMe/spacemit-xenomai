#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${1:-${ROOT_DIR}/.build/qemu-virt/irq-pipeline}"
STAMP="${2:-$(date +%Y%m%d-%H%M%S)}"

STDOUT_LOG="${ROOT_DIR}/.build/qemu-virt/irq-pipeline-qemu-output.log"
DEBUG_LOG="${ROOT_DIR}/.build/qemu-virt/irq-pipeline.evl_debug.qemu.log"
ARCHIVE_STDOUT="${ROOT_DIR}/.build/qemu-virt/irq-pipeline-qemu-output.${STAMP}.log"
ARCHIVE_DEBUG="${ROOT_DIR}/.build/qemu-virt/irq-pipeline.evl_debug.${STAMP}.log"

rm -f "${STDOUT_LOG}" "${DEBUG_LOG}"

QEMU_NO_REBOOT=1 \
QEMU_GDB=1 \
QEMU_GDB_PORT=1234 \
QEMU_DEBUG_LOG="${DEBUG_LOG}" \
QEMU_STDOUT_LOG="${STDOUT_LOG}" \
APPEND="evl_debug" \
bash "${ROOT_DIR}/scripts/qemu/run-riscv64-virt.sh" "${BUILD_DIR}"

if [[ -f "${STDOUT_LOG}" ]]; then
	cp -f "${STDOUT_LOG}" "${ARCHIVE_STDOUT}"
fi

if [[ -f "${DEBUG_LOG}" ]]; then
	cp -f "${DEBUG_LOG}" "${ARCHIVE_DEBUG}"
fi

printf 'Preserved logs:\n  %s\n  %s\n' "${ARCHIVE_STDOUT}" "${ARCHIVE_DEBUG}"
