#!/usr/bin/env bash
set -euo pipefail

# Threshold in MiB.
# NOTE: MI300X KFD driver idle overhead is typically ~250-300 MiB.
# We set this to 300 MiB, but also check if 0 KFD processes are active.
THRESHOLD_MIB=300
THRESHOLD_BYTES=$(( THRESHOLD_MIB * 1024 * 1024 ))
CONTAINER_NAME="mi300x-qwen3-profile"
POLL_INTERVAL=3

# Auto-detect sudo for root-owned processes
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
    else
        echo "Error: Must be run as root or with sudo to terminate root processes."
        exit 1
    fi
fi

if ! command -v rocm-smi &> /dev/null; then
    echo "Error: 'rocm-smi' command not found in PATH."
    exit 2
fi

iteration=1

while true; do
    echo "--- Check #$iteration ---"
    smi_output=$(rocm-smi --showmeminfo vram 2>&1)
    pids_output=$(rocm-smi --showpids 2>&1 || true)

    needs_release=false
    found_gpu=0

    # 1. Print memory usage per GPU
    while IFS= read -r line; do
        if [[ "$line" =~ GPU\[([0-9]+)\][[:space:]]*:[[:space:]]*VRAM\ Total\ Used\ Memory\ \(B\):[[:space:]]*([0-9]+) ]]; then
            found_gpu=$((found_gpu + 1))
            gpu_id="${BASH_REMATCH[1]}"
            used_bytes="${BASH_REMATCH[2]}"
            used_mib=$(awk -v b="$used_bytes" 'BEGIN { printf "%.2f", b / 1048576 }')

            echo "GPU[$gpu_id] VRAM Total Used Memory: ${used_mib} MiB (${used_bytes} B)"

            if (( used_bytes > THRESHOLD_BYTES )); then
                needs_release=true
            fi
        fi
    done <<< "$smi_output"

    if [ "$found_gpu" -eq 0 ]; then
        echo "Error: Could not retrieve VRAM info from rocm-smi."
        exit 2
    fi

    # 2. Extract active KFD process IDs from rocm-smi
    kfd_pids=$(echo "$pids_output" | awk '$1 ~ /^[0-9]+$/ {print $1}')

    # Exit condition: memory is under threshold AND no KFD processes are active
    if [ "$needs_release" = false ] && [ -z "$kfd_pids" ]; then
        echo "Success: VRAM is clear and no KFD processes are active."
        break
    fi

    # Choose termination signal: escalate to SIGKILL (-9) after 2 iterations
    SIGNAL="-TERM"
    if [ "$iteration" -ge 3 ]; then
        SIGNAL="-KILL"
        echo "Escalating signal to SIGKILL (-9)..."
    fi

    echo "VRAM exceeds threshold or active processes found. Releasing..."

    # Step A: Target exact PIDs holding GPU memory reported by rocm-smi
    if [ -n "$kfd_pids" ]; then
        echo "Targeting active KFD PIDs: $(echo "$kfd_pids" | tr '\n' ' ')"
        for pid in $kfd_pids; do
            $SUDO kill "$SIGNAL" "$pid" 2>/dev/null || true
        done
    fi

    # Step B: Clean up inside container as root (-u 0)
    if command -v docker &> /dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        echo "Sending $SIGNAL to processes inside container '$CONTAINER_NAME'..."
        $SUDO docker exec -u 0 "$CONTAINER_NAME" bash -lc "
            pkill $SIGNAL -f '[v]llm' || true
            pkill $SIGNAL -f 'multiprocessing.spawn' || true
            pkill $SIGNAL -f '[r]ocprofv3' || true
        " || true
    fi

    # Step C: Clean up lingering host processes matching patterns
    $SUDO pkill "$SIGNAL" -f '[v]llm' || true
    $SUDO pkill "$SIGNAL" -f 'multiprocessing.spawn' || true
    $SUDO pkill "$SIGNAL" -f '[r]ocprofv3' || true

    echo "Waiting ${POLL_INTERVAL}s for driver deallocation..."
    sleep "$POLL_INTERVAL"
    iteration=$((iteration + 1))
    echo ""
done