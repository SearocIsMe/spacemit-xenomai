#!/usr/bin/env bash
# =============================================================================
# run-riscv64-virt.sh
#
# Boot a kernel built by scripts/build/build-qemu-virt-bisect.sh on the
# standard QEMU riscv64 `virt` machine.
#
# This is meant for architecture smoke tests, not for reproducing the full
# Jupiter SD-card boot chain.
#
# Usage:
#   bash scripts/qemu/run-riscv64-virt.sh <build_dir>
#
# Optional environment:
#   INITRD=path/to/rootfs.cpio.gz     Boot with an initramfs
#   ROOTFS_IMG=path/to/rootfs.img     Attach a virtio block rootfs
#   APPEND="extra kernel args"        Extra kernel command line
#   QEMU_SMP=4                        Number of vCPUs
#   QEMU_MEM=2048                     RAM in MiB
#   QEMU_NET=1                        Enable user-mode networking
#   QEMU_NO_REBOOT=1                  Exit on guest reset instead of looping
#   QEMU_DEBUG_LOG=path               Write QEMU debug log to this file
#   QEMU_STDOUT_LOG=path              Mirror guest console/stdout to this file
#   QEMU_DEBUG_FLAGS=guest_errors,cpu_reset
#   QEMU_BIN=qemu-system-riscv64      Override QEMU binary
# =============================================================================
set -euo pipefail

BUILD_DIR="${1:-}"
QEMU_BIN="${QEMU_BIN:-qemu-system-riscv64}"
QEMU_SMP="${QEMU_SMP:-4}"
QEMU_MEM="${QEMU_MEM:-2048}"
QEMU_NET="${QEMU_NET:-0}"
QEMU_NO_REBOOT="${QEMU_NO_REBOOT:-0}"
QEMU_DEBUG_LOG="${QEMU_DEBUG_LOG:-}"
QEMU_STDOUT_LOG="${QEMU_STDOUT_LOG:-}"
QEMU_DEBUG_FLAGS="${QEMU_DEBUG_FLAGS:-guest_errors,cpu_reset}"
APPEND="${APPEND:-}"
INITRD="${INITRD:-}"
ROOTFS_IMG="${ROOTFS_IMG:-}"

if [[ -z "${BUILD_DIR}" ]]; then
  echo "Usage: $0 <build_dir>"
  exit 1
fi

KERNEL_IMAGE="${BUILD_DIR}/arch/riscv/boot/Image"

[[ -f "${KERNEL_IMAGE}" ]] || {
  echo "ERROR: kernel image not found: ${KERNEL_IMAGE}"
  exit 1
}

if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
  echo "ERROR: ${QEMU_BIN} not found in PATH."
  exit 1
fi

cmd=(
  "${QEMU_BIN}"
  -machine virt
  -cpu rv64
  -smp "${QEMU_SMP}"
  -m "${QEMU_MEM}"
  -nographic
  -bios default
  -kernel "${KERNEL_IMAGE}"
)

if [[ "${QEMU_NO_REBOOT}" == "1" ]]; then
  cmd+=(-no-reboot)
fi

if [[ -n "${QEMU_DEBUG_LOG}" ]]; then
  cmd+=(-d "${QEMU_DEBUG_FLAGS}" -D "${QEMU_DEBUG_LOG}")
fi

kernel_args=(
  "console=ttyS0"
  "earlycon=sbi"
  "panic=-1"
  "loglevel=8"
)

if [[ -n "${INITRD}" ]]; then
  [[ -f "${INITRD}" ]] || {
    echo "ERROR: initrd not found: ${INITRD}"
    exit 1
  }
  cmd+=(-initrd "${INITRD}")
fi

if [[ -n "${ROOTFS_IMG}" ]]; then
  [[ -f "${ROOTFS_IMG}" ]] || {
    echo "ERROR: rootfs image not found: ${ROOTFS_IMG}"
    exit 1
  }
  cmd+=(
    -drive "file=${ROOTFS_IMG},format=raw,if=none,id=hd0"
    -device virtio-blk-device,drive=hd0
  )
  kernel_args+=("root=/dev/vda" "rw")
fi

if [[ "${QEMU_NET}" == "1" ]]; then
  cmd+=(
    -netdev user,id=n0
    -device virtio-net-device,netdev=n0
  )
fi

if [[ -n "${APPEND}" ]]; then
  kernel_args+=("${APPEND}")
fi

cmd+=(-append "${kernel_args[*]}")

echo "Running: ${cmd[*]}"

if [[ -n "${QEMU_STDOUT_LOG}" ]]; then
  mkdir -p "$(dirname "${QEMU_STDOUT_LOG}")"
  "${cmd[@]}" 2>&1 | tee "${QEMU_STDOUT_LOG}"
  exit "${PIPESTATUS[0]}"
fi

exec "${cmd[@]}"
