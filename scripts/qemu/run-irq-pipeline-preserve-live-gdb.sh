#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

QEMU_GDB_STOP=0 \
exec bash "${ROOT_DIR}/scripts/qemu/run-irq-pipeline-preserve.sh" "$@"
