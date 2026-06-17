#!/bin/bash
# Guest-side MI300X co-simulation GPU initialization.
# Called by cosim-gpu-setup.service at boot.
# Detects all AMD GPU PCI devices and initializes each one.

set -e

export LD_LIBRARY_PATH=/opt/rocm/lib:${LD_LIBRARY_PATH:-}
export HSA_ENABLE_INTERRUPT=0
# xnack+ (recoverable GPU page faults) — required for ROCm device ASAN.
# Needs the gem5 fault/replay + interrupt path (see plan-xnack.md Phases 2-4);
# until those land, only no-fault / pre-resident workloads are expected to pass.
export HSA_XNACK=1
export HCC_AMDGPU_TARGET=gfx942:xnack+

ROM_PATH="/root/roms/mi300.rom"
FW_DISCOVERY="/usr/lib/firmware/amdgpu/mi300_discovery"
FW_LINK="/usr/lib/firmware/amdgpu/ip_discovery.bin"

# Load VGA ROM to legacy address 0xC0000 (required by amdgpu driver)
if [ -f "$ROM_PATH" ]; then
    dd if="$ROM_PATH" of=/dev/mem bs=1k seek=768 count=128 2>/dev/null
    echo "cosim-gpu-setup: VGA ROM loaded"
else
    echo "cosim-gpu-setup: WARNING: $ROM_PATH not found" >&2
fi

# Link IP discovery firmware
if [ -e "$FW_DISCOVERY" ]; then
    rm -f "$FW_LINK"
    ln -s "$FW_DISCOVERY" "$FW_LINK"
    echo "cosim-gpu-setup: IP discovery firmware linked"
fi

# Load amdgpu driver with cosim-specific parameters.
# NOTE: Do NOT delegate to /home/gem5/load_amdgpu.sh — that script is designed
# for standalone gem5 full-system simulation (ip_block_mask=0x6f enables PSP).
# In cosim (QEMU+KVM+gem5), PSP/SMU are not modeled; ppfeaturemask and dpm
# must be disabled to prevent the driver from accessing unmodeled registers.
AMDGPU_ARGS=(ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2)

# Kernel cmdline modprobe.blacklist=amdgpu creates a runtime blacklist that
# causes modprobe to silently skip the module (exit 0 without loading).
rm -f /run/modprobe.d/*blacklist* 2>/dev/null

if modprobe amdgpu "${AMDGPU_ARGS[@]}" 2>/dev/null; then
    echo "cosim-gpu-setup: amdgpu loaded (modprobe)"
elif insmod "/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst" "${AMDGPU_ARGS[@]}" 2>/dev/null; then
    echo "cosim-gpu-setup: amdgpu loaded (insmod .ko.zst)"
elif insmod "/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko" "${AMDGPU_ARGS[@]}" 2>/dev/null; then
    echo "cosim-gpu-setup: amdgpu loaded (insmod .ko)"
else
    echo "cosim-gpu-setup: ERROR: failed to load amdgpu" >&2
    exit 1
fi

# Verify: count initialized AMD GPUs via DRM
EXPECTED=$(lspci -d 1002: | wc -l)
INITIALIZED=0
for card in /sys/class/drm/card[0-9]*; do
    if [ -d "$card/device" ] && [ -f "$card/device/vendor" ]; then
        vendor=$(cat "$card/device/vendor" 2>/dev/null)
        if [ "$vendor" = "0x1002" ]; then
            INITIALIZED=$((INITIALIZED + 1))
        fi
    fi
done

echo "cosim-gpu-setup: $INITIALIZED/$EXPECTED GPU(s) initialized"
if [ "$INITIALIZED" -lt "$EXPECTED" ]; then
    echo "cosim-gpu-setup: WARNING: not all GPUs initialized" >&2
    exit 1
fi
