#!/bin/bash
# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# Build the base (backing) qcow2: Ubuntu 24.04 + version-independent cosim infra.
# Uses the cosim's custom QEMU build (no system qemu-system-x86_64 is installed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# cosim repo root: .../cosim-gpu
COSIM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
QEMU_BUILD="${COSIM_DIR}/qemu/build"

if [ ! -x "${QEMU_BUILD}/qemu-system-x86_64" ] || [ ! -x "${QEMU_BUILD}/qemu-img" ]; then
    echo "ERROR: custom QEMU not found in ${QEMU_BUILD} (need qemu-system-x86_64 and qemu-img)." >&2
    echo "Build it first (see cosim CLAUDE.md), or install system qemu-utils/qemu-system-x86." >&2
    exit 1
fi

# Make both qemu-system-x86_64 and qemu-img discoverable by packer.
export PATH="${QEMU_BUILD}:${PATH}"

PACKER="../packer"
if [ ! -x "$PACKER" ]; then
    echo "ERROR: packer binary not found at $PACKER (run ../build.sh once to fetch it)." >&2
    exit 1
fi

# Fresh output dir (packer refuses to overwrite).
rm -rf disk-image-base

"$PACKER" init base.pkr.hcl
"$PACKER" build \
    -var "qemu_path=${QEMU_BUILD}/qemu-system-x86_64" \
    "$@" \
    base.pkr.hcl

echo
echo "Base disk built: $(ls -la disk-image-base/ 2>/dev/null)"
