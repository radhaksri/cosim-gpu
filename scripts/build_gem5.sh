#!/bin/bash
# Build gem5 in the gem5-run:local container with ccache enabled.
#
# ccache (installed in the image, masquerade on PATH) transparently caches the
# compiles; CCACHE_DIR is bind-mounted to a host dir so the cache persists across
# the --rm container and across rebuilds. This makes iterative gem5 rebuilds
# (header changes, branch switches, the spurious param_*.cc cascades) much
# faster.
#
# Usage:
#   scripts/build_gem5.sh                       # build build/VEGA_X86/gem5.opt
#   scripts/build_gem5.sh build/VEGA_X86/gem5.fast
#   JOBS=24 scripts/build_gem5.sh               # override parallelism
#   scripts/build_gem5.sh --stats               # print ccache stats and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIM_DIR="$(dirname "$SCRIPT_DIR")"
GEM5_DIR="${COSIM_DIR}/gem5"
IMAGE="${GEM5_DOCKER_IMAGE:-gem5-run:local}"
CC_DIR="${GEM5_CCACHE_DIR:-$HOME/.cache/gem5-ccache}"
JOBS="${JOBS:-$(nproc)}"
TARGET="${1:-build/VEGA_X86/gem5.opt}"

mkdir -p "$CC_DIR"

if [[ "$TARGET" == "--stats" ]]; then
    docker run --rm -e CCACHE_DIR=/ccache -v "$CC_DIR:/ccache" "$IMAGE" ccache -s
    exit 0
fi

# Note: the build runs as root (the default in this image); the gem5 build/ tree
# is root-owned from prior builds. ccache writes into the (host-owned) mounted
# cache as root, which is fine.
exec docker run --rm \
    -e CCACHE_DIR=/ccache \
    -e PYTHONPATH=/usr/lib/python3.12/lib-dynload \
    -v "${GEM5_DIR}:/gem5" \
    -v "${CC_DIR}:/ccache" \
    -w /gem5 \
    "$IMAGE" \
    scons "$TARGET" -j"$JOBS"
