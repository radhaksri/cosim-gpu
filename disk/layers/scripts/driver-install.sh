#!/bin/bash
# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# Driver layer provisioning (overlay on a kernel layer). Installs amdgpu-dkms
# from the radeon repo and builds it for the kernel pinned by the underlying
# kernel layer (NOT necessarily the kernel currently booted for provisioning).
#
# Required env:
#   AMDGPU_REPO_VER  radeon repo channel, e.g. "7.0" (https://repo.radeon.com/amdgpu/<ver>/ubuntu)
# Optional env:
#   AMDGPU_PKG_VER   exact apt version for amdgpu-dkms (default: repo latest)
#   KERNEL           kernel to build DKMS for (default: /etc/cosim-kernel-version)
set -euo pipefail

: "${AMDGPU_REPO_VER:?AMDGPU_REPO_VER env (e.g. 7.0) is required}"
KERNEL="${KERNEL:-$(cat /etc/cosim-kernel-version 2>/dev/null || true)}"
: "${KERNEL:?Could not determine target KERNEL (set env or build a kernel layer first)}"
echo "=== driver-install: amdgpu repo ${AMDGPU_REPO_VER}, target kernel ${KERNEL} ==="
export DEBIAN_FRONTEND=noninteractive

mkdir --parents --mode=0755 /etc/apt/keyrings
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - \
    | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${AMDGPU_REPO_VER}/ubuntu noble main" \
    | tee /etc/apt/sources.list.d/amdgpu.list
apt-get update

if [ -n "${AMDGPU_PKG_VER:-}" ]; then
    apt-get install -y "amdgpu-dkms=${AMDGPU_PKG_VER}"
else
    apt-get install -y amdgpu-dkms
fi

# Ensure the DKMS module is built+installed for the cosim target kernel, since
# the running (provisioning) kernel may differ from ${KERNEL}.
MOD_DIR="$(ls -d /usr/src/amdgpu-* 2>/dev/null | head -1 || true)"
if [ -n "${MOD_DIR}" ]; then
    MOD_VER="$(basename "${MOD_DIR}" | sed 's/^amdgpu-//')"
    echo "=== driver-install: dkms build/install amdgpu/${MOD_VER} for ${KERNEL} ==="
    dkms build  -m amdgpu -v "${MOD_VER}" -k "${KERNEL}" || true
    dkms install -m amdgpu -v "${MOD_VER}" -k "${KERNEL}" --force || true
    depmod "${KERNEL}" || true
    echo "${MOD_VER}" > /etc/cosim-amdgpu-version
else
    echo "WARN: /usr/src/amdgpu-* not found; relying on package postinst dkms build." >&2
fi

echo "=== driver-install: done ==="
