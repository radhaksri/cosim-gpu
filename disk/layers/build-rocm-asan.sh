#!/bin/bash
# Copyright (c) 2026 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD 3-Clause
#
# Build the ASAN ROCm overlay layer ON THE HOST (no guest boot):
#   1. fetch a TheRock CI ASAN build with build_tools/install_rocm_from_artifacts.py
#      (uses the host's gh auth for bucket resolution + boto3 for S3),
#   2. create a qcow2 overlay on the driver layer,
#   3. inject the ROCm tree + environment into the overlay with libguestfs
#      (virt-customize), offline.
#
# This avoids replicating the host's auth context (corporate CA, GitHub token,
# AWS creds) inside a throwaway guest.
#
# Env (set by cosim_vm.py; all required unless noted):
#   RUN_ID         TheRock workflow run id (numeric)
#   AMDGPU_FAMILY  e.g. "gfx94X-dcgpu" or "gfx942:xnack+"
#   DRIVER_IMAGE   path to the driver-layer qcow2 (backing file)
#   OUTPUT_IMAGE   path to write the rocm-asan overlay qcow2
#   TESTS          "1" to fetch component test artifacts (default "1")
#   THEROCK_REPO   owner/repo (default ROCm/TheRock)
#   THEROCK_REF    git ref for the install tooling (default main)
#   EXTRA_ENV      newline-separated KEY=VALUE lines to add to /etc/environment
#   COMPONENTS     extra args appended verbatim to install_rocm_from_artifacts.py
set -euo pipefail

: "${RUN_ID:?RUN_ID required}"
: "${AMDGPU_FAMILY:?AMDGPU_FAMILY required}"
: "${DRIVER_IMAGE:?DRIVER_IMAGE required}"
: "${OUTPUT_IMAGE:?OUTPUT_IMAGE required}"
TESTS="${TESTS:-1}"
THEROCK_REPO="${THEROCK_REPO:-ROCm/TheRock}"
THEROCK_REF="${THEROCK_REF:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
COSIM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
QEMU_BUILD="${COSIM_DIR}/qemu/build"
export PATH="${QEMU_BUILD}:${PATH}"   # qemu-img

CACHE="${SCRIPT_DIR}/.cache"
VENV="${CACHE}/therock-venv"
SRC="${CACHE}/therock-src"
STAGE_PARENT="${CACHE}/stage-${RUN_ID}"
STAGE="${STAGE_PARENT}/rocm-therock"   # basename becomes /opt/rocm-therock
mkdir -p "$CACHE"

# --- tooling checks ---
# DRY_RUN=1 validates the fetch path only (run/family/bucket/artifacts) without
# downloading GBs or needing libguestfs.
if [ "${DRY_RUN:-0}" != "1" ]; then
    command -v virt-customize >/dev/null 2>&1 || {
        echo "ERROR: libguestfs not installed. Run: sudo apt-get install -y libguestfs-tools" >&2
        exit 1
    }
    [ -x "${QEMU_BUILD}/qemu-img" ] || { echo "ERROR: ${QEMU_BUILD}/qemu-img missing" >&2; exit 1; }
fi

# --- TheRock build_tools (sparse) on the host ---
# Cone-mode sparse checkout keeps top-level files (incl. requirements.txt).
if [ ! -d "${SRC}/build_tools" ]; then
    echo "=== build-rocm-asan: cloning ${THEROCK_REPO} build_tools (${THEROCK_REF}) ==="
    rm -rf "$SRC"
    git clone --depth=1 --filter=blob:none --sparse \
        --branch "${THEROCK_REF}" "https://github.com/${THEROCK_REPO}.git" "$SRC"
    git -C "$SRC" sparse-checkout set build_tools
else
    git -C "$SRC" fetch --depth=1 origin "${THEROCK_REF}" >/dev/null 2>&1 || true
    git -C "$SRC" checkout -q "${THEROCK_REF}" >/dev/null 2>&1 || true
fi

# --- python venv with TheRock's pinned requirements (per the ASAN wiki) ---
# install_rocm_from_artifacts.py needs boto3 + pyzstd/zstandard etc.; using the
# repo's requirements.txt keeps versions aligned with the build that produced
# the artifacts.
if [ ! -x "${VENV}/bin/python" ]; then
    echo "=== build-rocm-asan: creating venv ${VENV} ==="
    python3 -m venv "$VENV"
fi
"${VENV}/bin/pip" install --quiet --upgrade pip
if [ -f "${SRC}/requirements.txt" ]; then
    "${VENV}/bin/pip" install --quiet -r "${SRC}/requirements.txt"
else
    echo "WARN: ${SRC}/requirements.txt not found; falling back to minimal deps" >&2
    "${VENV}/bin/pip" install --quiet boto3 botocore pyzstd zstandard
fi

# --- fetch the ROCm tree (cached by run id; FORCE_FETCH=1 to redownload) ---
FETCH_MARK="${STAGE_PARENT}/.fetch-complete"
if [ -f "$FETCH_MARK" ] && [ "${FORCE_FETCH:-0}" != "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
    echo "=== build-rocm-asan: using cached fetch ${STAGE} (FORCE_FETCH=1 to redo) ==="
else
    echo "=== build-rocm-asan: fetching run ${RUN_ID} family ${AMDGPU_FAMILY} -> ${STAGE} ==="
    rm -rf "$STAGE_PARENT"
    mkdir -p "$STAGE_PARENT"
    # GitHub token (bucket resolution) from host gh auth; AWS_* honored if set.
    export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
    TESTS_FLAG=""
    [ "$TESTS" = "1" ] && TESTS_FLAG="--tests"
    DRY_FLAG=""
    [ "${DRY_RUN:-0}" = "1" ] && DRY_FLAG="--dry-run"
    ( cd "${SRC}/build_tools" && \
      "${VENV}/bin/python" install_rocm_from_artifacts.py \
        --run-id "${RUN_ID}" \
        --amdgpu-family "${AMDGPU_FAMILY}" \
        --output-dir "${STAGE}" \
        --run-github-repo "${THEROCK_REPO}" \
        ${TESTS_FLAG} ${DRY_FLAG} ${COMPONENTS:-} )

    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "=== build-rocm-asan: DRY_RUN complete (fetch validated; no inject) ==="
        exit 0
    fi
    if [ -z "$(ls -A "$STAGE" 2>/dev/null)" ]; then
        echo "ERROR: fetched ROCm tree is empty (${STAGE})" >&2
        exit 1
    fi
    touch "$FETCH_MARK"
fi

# --- create overlay on the driver layer ---
echo "=== build-rocm-asan: creating overlay ${OUTPUT_IMAGE} on $(basename "$DRIVER_IMAGE") ==="
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
rm -f "$OUTPUT_IMAGE"
qemu-img create -q -f qcow2 -b "$DRIVER_IMAGE" -F qcow2 "$OUTPUT_IMAGE"

# --- inject into the overlay with libguestfs (offline) ---
# /etc/environment additions: defaults (ROCm path + xnack) plus any wiki-specified
# EXTRA_ENV lines. A small in-guest merge script idempotently upserts each KEY.
ENV_ADD="${STAGE_PARENT}/cosim-environment.add"
{
    echo "ROCM_PATH=/opt/rocm"
    echo "HSA_XNACK=1"
    echo "LD_LIBRARY_PATH=/opt/rocm/lib"
    [ -n "${EXTRA_ENV:-}" ] && printf '%s\n' "${EXTRA_ENV}"
} > "$ENV_ADD"

MERGE_SH="${STAGE_PARENT}/cosim-merge-env.sh"
cat > "$MERGE_SH" <<'EOS'
#!/bin/sh
set -e
# Prepend /opt/rocm/bin to PATH if a PATH line exists, else add one.
if grep -q '^PATH=' /etc/environment; then
    sed -i 's|^PATH="\{0,1\}|PATH="/opt/rocm/bin:|' /etc/environment
    sed -i 's|/opt/rocm/bin:/opt/rocm/bin:|/opt/rocm/bin:|' /etc/environment
else
    echo 'PATH="/opt/rocm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' >> /etc/environment
fi
# Upsert each KEY=VALUE from the staged additions.
while IFS= read -r line; do
    [ -z "$line" ] && continue
    key=${line%%=*}
    if grep -q "^${key}=" /etc/environment; then
        sed -i "s|^${key}=.*|${line}|" /etc/environment
    else
        echo "$line" >> /etc/environment
    fi
done < /root/cosim-environment.add
echo /opt/rocm/lib > /etc/ld.so.conf.d/rocm-therock.conf
ln -sfn /opt/rocm-therock /opt/rocm
ldconfig || true
EOS

# libguestfs needs a kernel for its supermin appliance. This host (WSL2) has no
# kernel in /boot, so download a generic kernel + modules (no sudo, no system
# install) and point supermin at them via SUPERMIN_KERNEL/SUPERMIN_MODULES.
ensure_guestfs_kernel() {
    local kdir="${CACHE}/guestfs-kernel"
    local kver="${GUESTFS_KVER:-}"
    if [ -z "$kver" ]; then
        kver="$(apt-cache depends linux-image-generic 2>/dev/null \
                | sed -n 's/.*linux-image-\([0-9][^ ]*-generic\).*/\1/p' | head -1)"
    fi
    [ -n "$kver" ] || { echo "ERROR: could not resolve a generic kernel version for libguestfs" >&2; exit 1; }
    local kimg="${kdir}/root/boot/vmlinuz-${kver}"
    local kmod="${kdir}/root/lib/modules/${kver}"
    if [ ! -f "$kimg" ] || [ ! -f "${kmod}/modules.dep" ]; then
        echo "=== build-rocm-asan: fetching guestfs kernel ${kver} (no sudo) ==="
        mkdir -p "$kdir"; ( cd "$kdir"
            apt-get download "linux-image-unsigned-${kver}" "linux-modules-${kver}"
            rm -rf root && mkdir root
            for d in linux-image-unsigned-${kver}_*.deb linux-modules-${kver}_*.deb; do
                dpkg-deb -x "$d" root
            done
            depmod -b root "${kver}" )
    fi
    export SUPERMIN_KERNEL="$kimg"
    export SUPERMIN_MODULES="$kmod"
    export LIBGUESTFS_BACKEND=direct
}

ensure_guestfs_kernel
echo "=== build-rocm-asan: injecting ROCm tree + env via virt-customize ==="
virt-customize -a "$OUTPUT_IMAGE" \
    --copy-in "${STAGE}:/opt" \
    --copy-in "${ENV_ADD}:/root" \
    --copy-in "${MERGE_SH}:/root" \
    --run-command 'sh /root/cosim-merge-env.sh' \
    --write "/etc/cosim-rocm-source:therock-asan" \
    --write "/etc/cosim-rocm-run-id:${RUN_ID}" \
    --delete /root/cosim-environment.add \
    --delete /root/cosim-merge-env.sh

echo "=== build-rocm-asan: done -> ${OUTPUT_IMAGE} ==="
