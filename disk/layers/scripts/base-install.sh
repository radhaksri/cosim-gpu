#!/bin/bash
# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# Base layer provisioning: version-INDEPENDENT cosim infrastructure only.
# This goes into the rarely-changing backing disk. Everything that is coupled
# to a specific Linux kernel, amdgpu driver, or ROCm version belongs in a
# higher overlay layer (kernel-/driver-/rocm-), NOT here.
set -euo pipefail

echo "=== base-install: installing version-independent packages ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Build/runtime tooling reused by every higher layer (DKMS driver builds,
# gem5 m5 util fallback, etc.). These are stable across kernel/ROCm versions.
apt-get install -y \
    build-essential \
    dkms \
    scons \
    git \
    vim \
    cmake \
    wget \
    gpg \
    unzip \
    ca-certificates

# Remove the message-of-the-day spam so the serial console stays clean.
rm -f /etc/update-motd.d/* || true

# --- gem5 m5 magic-instruction utility (version-independent static binary) ---
if [ -f /home/gem5/m5 ]; then
    cp /home/gem5/m5 /sbin/m5
    chmod +x /sbin/m5
else
    echo "ERROR: /home/gem5/m5 not provisioned; base disk would be unusable." >&2
    exit 1
fi

# --- cosim GPU init service (version-independent) ---
chmod a+x /home/gem5/load_amdgpu.sh || true
chmod a+x /home/gem5/cosim-gpu-setup.sh
mv /home/gem5/cosim-gpu-setup.sh /usr/local/bin/cosim-gpu-setup.sh
mv /home/gem5/cosim-gpu-setup.service /lib/systemd/system/
systemctl daemon-reload
systemctl enable cosim-gpu-setup.service

# --- serial auto-login (version-independent) ---
mv /home/gem5/serial-getty@.service /lib/systemd/system/

# --- GPU BIOS + IP-discovery firmware staging (hardware data) ---
# Create the directories and make the firmware targets writable so the Packer
# file provisioner (running as the unprivileged ssh user) can drop the blobs in
# afterwards. Higher layers may overwrite these blobs if a driver version needs
# a different discovery format.
mkdir -p /root/roms
chmod 777 /root /root/roms
mkdir -p /usr/lib/firmware/amdgpu
touch /usr/lib/firmware/amdgpu/mi300_discovery \
      /usr/lib/firmware/amdgpu/mi350_discovery \
      /usr/lib/firmware/amdgpu/ip_discovery.bin
chmod 777 /usr/lib/firmware/amdgpu/mi300_discovery \
          /usr/lib/firmware/amdgpu/mi350_discovery \
          /usr/lib/firmware/amdgpu/ip_discovery.bin

# Convenience: launch helper from root's shell (harmless if unused).
if [ -f /home/gem5/run_gem5_app.sh ]; then
    echo -e "\n/home/gem5/run_gem5_app.sh\n" >> /root/.bashrc
fi

echo "=== base-install: done ==="
