#!/bin/bash
# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# ROCm layer provisioning (overlay on a driver layer). Installs the ROCm
# user-space stack of a chosen version. This is the most frequently rebuilt
# layer (nightly) and is a thin overlay: user space only, no kernel-module
# rebuild.
#
# Required env:
#   ROCM_VER   rocm apt channel, e.g. "7.0" (https://repo.radeon.com/rocm/apt/<ver>)
# Optional env:
#   ROCM_PKG_VER   exact apt version for the rocm metapackage (default: repo latest)
#   INSTALL_PYTORCH=1  also install a PyTorch wheel (off by default; very slow in sim)
set -euo pipefail

: "${ROCM_VER:?ROCM_VER env (e.g. 7.0) is required}"
echo "=== rocm-layer-install: ROCm ${ROCM_VER} ==="
export DEBIAN_FRONTEND=noninteractive

mkdir --parents --mode=0755 /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/rocm.gpg ]; then
    wget https://repo.radeon.com/rocm/rocm.gpg.key -O - \
        | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null
fi

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VER} noble main" \
    | tee /etc/apt/sources.list.d/rocm.list
echo -e 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600' \
    | tee /etc/apt/preferences.d/rocm-pin-600
apt-get update

if [ -n "${ROCM_PKG_VER:-}" ]; then
    apt-get install -y "rocm=${ROCM_PKG_VER}"
else
    apt-get install -y rocm
fi

# Enable xnack+ (recoverable GPU page faults) system-wide for ROCm device ASAN.
# Must live in /etc/environment so it reaches ALL processes (login shells,
# services, GPU workloads). With HSA_XNACK=1 rocminfo reports gfx942:xnack+.
if ! grep -q '^HSA_XNACK=' /etc/environment 2>/dev/null; then
    echo 'HSA_XNACK=1' >> /etc/environment
fi

if [ "${INSTALL_PYTORCH:-0}" = "1" ]; then
    echo "=== rocm-layer-install: installing PyTorch (slow in sim) ==="
    apt-get install -y pip3 || apt-get install -y python3-pip
    pip3 install --break-system-packages torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/rocm${ROCM_VER}" || \
        echo "WARN: PyTorch install failed for rocm${ROCM_VER}; continuing."
fi

echo "${ROCM_VER}" > /etc/cosim-rocm-version
echo "=== rocm-layer-install: done (ROCm ${ROCM_VER}) ==="
