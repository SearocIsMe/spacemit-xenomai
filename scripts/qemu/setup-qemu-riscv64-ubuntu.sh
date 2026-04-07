#!/usr/bin/env bash
# =============================================================================
# setup-qemu-riscv64-ubuntu.sh
#
# Install the host-side packages needed to run qemu-system-riscv64 on Ubuntu.
#
# Usage:
#   bash scripts/qemu/setup-qemu-riscv64-ubuntu.sh
#
# Notes:
# - This script uses apt and therefore needs sudo privileges.
# - On Ubuntu, qemu-system-riscv64 is provided by qemu-system-misc.
# - qemu-utils is included for image inspection/conversion helpers.
# =============================================================================
set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run this script as a normal user with sudo access, not as root."
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "ERROR: /etc/os-release not found."
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
  echo "ERROR: This installer currently supports Ubuntu/Debian-style systems."
  echo "Detected: ${PRETTY_NAME:-unknown}"
  exit 1
fi

packages=(
  qemu-system-misc
  qemu-utils
)

echo "Detected host: ${PRETTY_NAME:-unknown}"
echo "Installing QEMU packages: ${packages[*]}"

sudo apt-get update
sudo apt-get install -y "${packages[@]}"

if ! command -v qemu-system-riscv64 >/dev/null 2>&1; then
  echo "ERROR: qemu-system-riscv64 still not found after installation."
  exit 1
fi

echo ""
echo "QEMU riscv64 install complete."
echo "Binary : $(command -v qemu-system-riscv64)"
echo "Version: $(qemu-system-riscv64 --version | head -n 1)"
echo ""
echo "Next steps:"
echo "  1. Build a generic kernel:"
echo "     bash scripts/build/build-qemu-virt-bisect.sh vanilla-qemu"
echo "  2. Run it:"
echo "     bash scripts/qemu/run-riscv64-virt.sh .build/qemu-virt/vanilla"
