#!/bin/bash
# Throwaway driver: boot cosim, run /root/mgd under HSA_XNACK=1, capture the
# post-result window with GPUPTWalker tracing to see which agent keeps
# re-faulting the managed page after the kernel completes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIM_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/cosim_lib.sh"

COSIM_RUN_ID="${COSIM_RUN_ID:-$(generate_run_id)}"
export COSIM_RUN_ID
LAUNCH_SCRIPT="${SCRIPT_DIR}/cosim_launch.sh"

SESSION_DIR="/tmp/mgd-trace-${COSIM_RUN_ID}"
SCREEN_LOG="${SESSION_DIR}/console.log"
SESSION_FIFO="${SESSION_DIR}/console.in"
BOOT_TIMEOUT_SECS="${BOOT_TIMEOUT_SECS:-360}"
RUN_TIMEOUT_SECS="${RUN_TIMEOUT_SECS:-90}"
GEM5_DEBUG="${GEM5_DEBUG:-GPUPTWalker}"
TOKEN="MGD_DONE_$(date +%s)"

mkdir -p "$SESSION_DIR"
rm -f "$SCREEN_LOG" "$SESSION_FIFO"
mkfifo "$SESSION_FIFO"
exec {CONTROL_FD}<>"$SESSION_FIFO"

echo "[drive] run_id=$COSIM_RUN_ID session_dir=$SESSION_DIR"
echo "[drive] launching cosim (debug=$GEM5_DEBUG)..."
setsid stdbuf -oL -eL "$LAUNCH_SCRIPT" --gem5-debug "$GEM5_DEBUG" \
    <&$CONTROL_FD >"$SCREEN_LOG" 2>&1 &
LAUNCH_PID=$!
echo "$LAUNCH_PID" > "${SESSION_DIR}/launcher.pid"

send() { printf '%s\n' "$1" >&$CONTROL_FD; }

echo "[drive] waiting for guest shell..."
start_ts=$(date +%s)
while true; do
    if [[ -f "$SCREEN_LOG" ]] && grep -a -q 'root@gem5:~#' "$SCREEN_LOG"; then
        echo "[drive] guest shell ready"; break
    fi
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
        echo "[drive] FATAL: launcher exited during boot. tail:"; tail -n 40 "$SCREEN_LOG"
        exit 1
    fi
    if (( $(date +%s) - start_ts >= BOOT_TIMEOUT_SECS )); then
        echo "[drive] FATAL: boot timeout"; exit 1
    fi
    sleep 3
done

# Drive the run. Mark the moment the result prints so the post-result re-fault
# window is identifiable in the gem5 log.
send "export HSA_XNACK=1"
send "echo MGD_RUN_START"
send "timeout ${RUN_TIMEOUT_SECS} /root/mgd; echo __${TOKEN}__:\$?"

echo "[drive] running /root/mgd (timeout ${RUN_TIMEOUT_SECS}s)..."
start_ts=$(date +%s)
while true; do
    if grep -a -q "__${TOKEN}__:" "$SCREEN_LOG"; then
        echo "[drive] mgd finished:"; grep -a "__${TOKEN}__:" "$SCREEN_LOG" | tail -1
        break
    fi
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
        echo "[drive] FATAL: launcher died during run"; break
    fi
    if (( $(date +%s) - start_ts >= RUN_TIMEOUT_SECS + 30 )); then
        echo "[drive] run window elapsed (likely hang)"; break
    fi
    sleep 2
done

# Capture gem5 log (contains GPUPTWalker traces).
cname="$(cosim_container_name "$COSIM_RUN_ID")"
docker logs "$cname" > "${SESSION_DIR}/gem5.log" 2>&1 || true
echo "[drive] captured gem5.log ($(wc -l < "${SESSION_DIR}/gem5.log" 2>/dev/null || echo 0) lines)"
echo "[drive] console.log mgd tail:"; grep -a -A40 'MGD_RUN_START' "$SCREEN_LOG" | head -60

echo "[drive] leaving session up for inspection. cleanup:"
echo "  kill -TERM -- -${LAUNCH_PID}; docker rm -f ${cname}"
echo "[drive] artifacts in ${SESSION_DIR}"
