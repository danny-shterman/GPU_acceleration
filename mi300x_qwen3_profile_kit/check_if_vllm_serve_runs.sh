#!/usr/bin/env bash
#docker exec mi300x-qwen3-profile \
#  bash -lc "ps -eo pid,ppid,stat,cmd | grep -E '[v]llm|[p]ython|[r]ocprof' || true"
#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="mi300x-qwen3-profile"

# 1. Verify container is running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "Container '$CONTAINER_NAME' is not running."
    exit 1
fi

# 2. Inspect processes inside the container
proc_output=$(docker exec "$CONTAINER_NAME" \
    bash -lc "ps -eo pid,ppid,stat,cmd | grep -E '[v]llm|[p]ython|[r]ocprof' || true")

# 3. Filter for active (non-zombie) vLLM processes
active_vllm=$(echo "$proc_output" | awk '$3 !~ /Z/ && /vllm/ {print $0}')

# 4. Check status and print result
if [ -n "$active_vllm" ]; then
    echo "Status: 'vllm serve' IS RUNNING inside '$CONTAINER_NAME'."
    echo ""
    echo "Active Process Details:"
    printf "%-8s %-8s %-6s %s\n" "PID" "PPID" "STAT" "COMMAND"
    echo "$active_vllm"
else
    echo "Status: 'vllm serve' is NOT running inside '$CONTAINER_NAME'."
    
    # Check if defunct/zombie entries were found
    zombie_vllm=$(echo "$proc_output" | awk '$3 ~ /Z/ && /vllm/ {print $0}')
    if [ -n "$zombie_vllm" ]; then
        echo "(Note: Only dead/defunct zombie entries remain in the process table)"
    fi
fi
