#!/bin/bash
# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# Kernel layer provisioning (overlay on base). Installs a specific Linux kernel
# + headers + extra modules, builds the gem5_wmi helper module for THAT kernel,
# and extracts the matching vmlinux. The extracted vmlinux is what QEMU boots
# (-kernel), so it MUST match the kernel whose modules live in this layer.
#
# Required env: KERNEL  (e.g. "6.8.0-79-generic")
set -euo pipefail

: "${KERNEL:?KERNEL env var (e.g. 6.8.0-79-generic) is required}"
echo "=== kernel-install: target kernel ${KERNEL} ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update

apt-get install -y \
    "linux-image-${KERNEL}" \
    "linux-headers-${KERNEL}" \
    "linux-modules-extra-${KERNEL}"

# Extract the uncompressed vmlinux for gem5/QEMU -kernel boot.
echo "=== kernel-install: extracting vmlinux ==="
/usr/src/linux-headers-${KERNEL}/scripts/extract-vmlinux \
    /boot/vmlinuz-${KERNEL} > /home/gem5/vmlinux-${KERNEL}
chmod 666 /home/gem5/vmlinux-${KERNEL}

# Build the gem5 WMI shim module against THIS kernel (provides symbols missing
# due to gem5's limited ACPI support). Kernel-coupled → lives in this layer.
echo "=== kernel-install: building gem5_wmi.ko for ${KERNEL} ==="
pushd /home/gem5/gem5_wmi
make -C "/lib/modules/${KERNEL}/build" M="${PWD}"
if [ ! -f ./gem5_wmi.ko ]; then
    echo "ERROR: gem5_wmi.ko did not build for ${KERNEL}." >&2
    exit 1
fi
# Install into the target kernel's module tree so modprobe finds it at runtime.
mkdir -p "/lib/modules/${KERNEL}/extra"
cp ./gem5_wmi.ko "/lib/modules/${KERNEL}/extra/"
depmod "${KERNEL}" || true
popd

# Record which kernel this chain pairs with (consumed by the launcher).
echo "${KERNEL}" > /etc/cosim-kernel-version

echo "=== kernel-install: done (kernel ${KERNEL}) ==="
