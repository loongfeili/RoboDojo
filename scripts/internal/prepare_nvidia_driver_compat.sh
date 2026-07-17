#!/usr/bin/env bash
# Build a non-root library overlay when container CUDA libraries do not match
# the loaded NVIDIA kernel module.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${ROBODOJO_NVIDIA_LIB_DIR:-/usr/lib/x86_64-linux-gnu}"

kernel_version="$(
  awk '/NVRM version:/ {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {
        print $i
        exit
      }
    }
  }' /proc/driver/nvidia/version
)"
[[ -n "${kernel_version}" ]] || {
  echo "Unable to determine NVIDIA kernel module version" >&2
  exit 1
}

if [[ "${1:-}" == "--needs-version-bypass" ]]; then
  IFS=. read -r major minor _patch <<< "${kernel_version}"
  # NVIDIA encodes the Vulkan minor component in 8 bits. Driver 535.261.03
  # therefore appears to Kit as 535.05.03 even though it is newer than the
  # recommended 535.161.07 driver.
  [[ "${major}" -eq 535 && "${minor}" -ge 161 ]]
  exit
fi
[[ $# -eq 0 ]] || {
  echo "Usage: $0 [--needs-version-bypass]" >&2
  exit 2
}

resolved_cuda="$(readlink -f "${LIB_DIR}/libcuda.so.1")"
if [[ "${resolved_cuda}" == *".${kernel_version}" ]]; then
  printf '%s\n' ""
  exit 0
fi

overlay="${ROOT_DIR}/.cache/nvidia-driver-compat/${kernel_version}"
mkdir -p "${overlay}"

link_versioned() {
  local soname="$1"
  local versioned="${LIB_DIR}/${soname%.*}.${kernel_version}"
  [[ -f "${versioned}" ]] || {
    echo "Matching NVIDIA library not found: ${versioned}" >&2
    exit 1
  }
  ln -sfn "${versioned}" "${overlay}/${soname}"
}

link_versioned "libcuda.so.1"
ln -sfn "${LIB_DIR}/libcuda.so.${kernel_version}" "${overlay}/libcuda.so"
link_versioned "libnvidia-ptxjitcompiler.so.1"
link_versioned "libnvidia-nvvm.so.4"

echo "[nvidia-compat] kernel=${kernel_version} system_cuda=${resolved_cuda}" >&2
echo "[nvidia-compat] overlay=${overlay}" >&2
printf '%s\n' "${overlay}"
