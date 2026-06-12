#!/bin/bash
# Driver: boot the layered ASAN cosim VM (run 27320850021) and run rocrtst64
# the way the TheRock harness does, capturing the console for diff against the
# MI325 reference. Leaves the session up (FIFO) for follow-up passes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIM_DIR="$(dirname "$SCRIPT_DIR")"

RUN_TAG="${RUN_TAG:-rocrtst-$(date +%Y%m%d-%H%M%S)}"
SESSION_DIR="/tmp/${RUN_TAG}"
SCREEN_LOG="${SESSION_DIR}/console.log"
SESSION_FIFO="${SESSION_DIR}/console.in"
BOOT_TIMEOUT_SECS="${BOOT_TIMEOUT_SECS:-600}"

mkdir -p "$SESSION_DIR"
rm -f "$SCREEN_LOG" "$SESSION_FIFO"
mkfifo "$SESSION_FIFO"
exec {CONTROL_FD}<>"$SESSION_FIFO"

echo "[drive] session_dir=$SESSION_DIR"
echo "[drive] launching ASAN cosim VM (cosim_vm.py launch)..."
PASSTHRU=()
if [[ -n "${GEM5_DEBUG:-}" ]]; then
    PASSTHRU=(-- --gem5-debug "${GEM5_DEBUG}")
fi
setsid stdbuf -oL -eL python3 "${SCRIPT_DIR}/cosim_vm.py" launch --no-build "${PASSTHRU[@]}" \
    <&$CONTROL_FD >"$SCREEN_LOG" 2>&1 &
LAUNCH_PID=$!
echo "$LAUNCH_PID" > "${SESSION_DIR}/launcher.pid"
echo "[drive] launcher pid=$LAUNCH_PID"

send() { printf '%s\n' "$1" >&$CONTROL_FD; }

echo "[drive] waiting for guest shell (timeout ${BOOT_TIMEOUT_SECS}s)..."
start_ts=$(date +%s)
while true; do
    if [[ -f "$SCREEN_LOG" ]] && grep -a -q 'root@gem5:~#' "$SCREEN_LOG"; then
        echo "[drive] guest shell ready"; break
    fi
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
        echo "[drive] FATAL: launcher exited during boot. tail:"; tail -n 50 "$SCREEN_LOG"; exit 1
    fi
    if (( $(date +%s) - start_ts >= BOOT_TIMEOUT_SECS )); then
        echo "[drive] FATAL: boot timeout"; tail -n 50 "$SCREEN_LOG"; exit 1
    fi
    sleep 3
done

# GPU readiness + env check (matches harness env from /etc/environment).
send 'echo "XNACK=$HSA_XNACK ASAN_OPTIONS=$ASAN_OPTIONS"; ls /opt/rocm/bin/rocrtst64; rocminfo 2>&1 | grep -iE "ROCk module|Name:.*gfx|XNACK enabled" | head'
sleep 12
echo "[drive] readiness probe output:"; tail -n 20 "$SCREEN_LOG" | tr -d '\r'

echo "[drive] session left up. FIFO=$SESSION_FIFO LOG=$SCREEN_LOG launcher=$LAUNCH_PID"
echo "[drive] (run rocrtst by writing commands to the FIFO)"
