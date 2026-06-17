#!/bin/bash
# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# Build a qcow2 overlay layer (kernel | driver | rocm) on top of a lower image.
# Uses the cosim's custom QEMU build (no system qemu installed).
#
# Usage:
#   ./build-layer.sh kernel -var kernel_version=6.8.0-79-generic
#   ./build-layer.sh driver -var amdgpu_repo_ver=7.0 -var kernel_version=6.8.0-79-generic
#   ./build-layer.sh rocm   -var rocm_ver=7.0
#
# Each layer defaults its input_image to the previous layer's default output.
# Override with -var input_image=... and -var output_dir=... to build variants
# (e.g. multiple ROCm versions on the same driver layer).
set -euo pipefail

LAYER="${1:-}"
shift || true
case "$LAYER" in
  kernel|driver|rocm) ;;
  *) echo "Usage: $0 <kernel|driver|rocm> [packer -var ...]" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
COSIM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
QEMU_BUILD="${COSIM_DIR}/qemu/build"

if [ ! -x "${QEMU_BUILD}/qemu-system-x86_64" ] || [ ! -x "${QEMU_BUILD}/qemu-img" ]; then
    echo "ERROR: custom QEMU not found in ${QEMU_BUILD}." >&2
    exit 1
fi
export PATH="${QEMU_BUILD}:${PATH}"

PACKER="../packer"
[ -x "$PACKER" ] || { echo "ERROR: packer not found at $PACKER (run ../build.sh once)." >&2; exit 1; }

# Default output dir for this layer (override via -var output_dir=...).
DEFAULT_OUT="disk-image-${LAYER}"
if ! printf '%s\n' "$@" | grep -q 'output_dir='; then
    rm -rf "${DEFAULT_OUT}"
fi

"$PACKER" init "${LAYER}.pkr.hcl"
"$PACKER" build \
    -var "qemu_path=${QEMU_BUILD}/qemu-system-x86_64" \
    "$@" \
    "${LAYER}.pkr.hcl"

echo
echo "Layer '${LAYER}' built. Output:"
ls -la "${DEFAULT_OUT}" 2>/dev/null || echo "(custom output_dir; check your -var output_dir)"
