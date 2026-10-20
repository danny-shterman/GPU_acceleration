#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${1:-mi300x-qwen3-profile}"
POLL_INTERVAL=2
MAX_ATTEMPTS=5

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "Container '$CONTAINER_NAME' is not running."
    exit 0
fi

# Function to get living, non-zombie vLLM process IDs
get_active_vllm_pids() {
    docker exec -u 0 "$CONTAINER_NAME" bash -c "
        ps -eo pid,stat,args | awk '\$2 !~ /Z/ && /vllm/ && !/awk/ && !/ps -eo/ {print \$1}'
    " 2>/dev/null || true
}

attempt=1

while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    active_pids=$(get_active_vllm_pids)

    # If no living processes remain (or only zombies exist), we are done
    if [ -z "$active_pids" ]; then
        echo "Success: No active vLLM processes running inside '$CONTAINER_NAME' (only dead/reaped zombies remain)."
        exit 0
    fi

    echo "Attempt #$attempt: Living vLLM PID(s) found: $(echo "$active_pids" | tr '\n' ' ')"

    SIGNAL="TERM"
    if [ "$attempt" -ge 3 ]; then
        SIGNAL="KILL"
        echo "Sending SIGKILL (-9)..."
    else
        echo "Sending SIGTERM..."
    fi

    # Kill living processes directly by PID
    docker exec -u 0 "$CONTAINER_NAME" bash -c "
        kill -$SIGNAL $active_pids 2>/dev/null || true
        pkill -$SIGNAL -f 'multiprocessing.spawn' 2>/dev/null || true
    "

    sleep "$POLL_INTERVAL"
    attempt=$((attempt + 1))
done

echo "Warning: Processes did not exit after $MAX_ATTEMPTS attempts."