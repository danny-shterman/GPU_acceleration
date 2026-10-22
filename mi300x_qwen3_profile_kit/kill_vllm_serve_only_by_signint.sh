#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${1:-mi300x-qwen3-profile}"
POLL_INTERVAL=10

# Check if the container is running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "Container '$CONTAINER_NAME' is not running. No processes to kill."
    exit 0
fi

iteration=1

while true; do
    echo "--- Check #$iteration ---"

    # Query active vLLM process IDs inside the container
    vllm_pids=$(docker exec -u 0 "$CONTAINER_NAME" pgrep -f 'vllm' 2>/dev/null || true)
    echo "Active vLLM processes: $vllm_pids"

    # If no PIDs are found, vllm serve is fully dead
    if [ -z "$vllm_pids" ]; then
        echo "Success: No active vLLM processes found inside '$CONTAINER_NAME'."
        exit 0
    fi

    echo "Active vLLM PID(s) inside container: $(echo "$vllm_pids" | tr '\n' ' ')"
    if (( iteration > 1 )) && [[ "$vllm_pids" =~ [0-9] ]]; then
	echo "Iteration $iteration: Detected lingering PIDs (${vllm_pids//$'\n'/ }). Kill this processes by using ./kill_docker_zombie_table_entries.sh after all the checks."
#        echo "Iteration $iteration: Detected lingering PIDs ($vllm_pids). Running zombie cleanup..."
#        if [ -x "./kill_docker_zombie_table_entries.sh" ]; then
#            ./kill_docker_zombie_table_entries.sh
#        else
#            bash ./kill_docker_zombie_table_entries.sh
#        fi
    fi

    # Escalate to SIGKILL (-9) after 2 unsuccessful attempts
    SIGNAL="TERM"
    if [ "$iteration" -ge 3 ]; then
        SIGNAL="KILL"
        echo "Escalating: Sending SIGKILL (-9)..."
    else
        echo "Sending SIGTERM to vLLM processes..."
    fi

    # Kill vLLM and any multi-GPU engine subprocesses inside the container
#    docker exec -u 0 "$CONTAINER_NAME" bash -c "
#    	pkill -TERM -f '^/usr/bin/python /usr/local/bin/vllm serve '
#    	pkill -TERM -f '^/usr/bin/python3 /usr/local/bin/vllm serve '
#    " 2>/dev/null || true
    docker exec -u 0 mi300x-qwen3-profile bash -lc '
        PID=$(pgrep -f "^/usr/bin/python3? /usr/local/bin/vllm serve " | head -1)

        if [[ -n "$PID" ]]; then
            echo "Gracefully stopping vLLM PID=$PID with SIGINT"
            kill -INT "$PID"
        else
            echo "No vLLM serve process found"
        fi
    ' 2>/dev/null || true

    echo "Waiting ${POLL_INTERVAL}s to verify shutdown..."
    sleep "$POLL_INTERVAL"
    iteration=$((iteration + 1))
    echo ""
done
