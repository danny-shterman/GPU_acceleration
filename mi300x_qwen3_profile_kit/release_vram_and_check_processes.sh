#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${1:-mi300x-qwen3-profile}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
TERM_WAIT="${TERM_WAIT:-5}"
VRAM_THRESHOLD_MIB="${VRAM_THRESHOLD_MIB:-30}"

###############################################################################
# Verify container
###############################################################################

if ! docker ps --format '{{.Names}}' |
    grep -qx "$CONTAINER_NAME"; then

    echo "Container '$CONTAINER_NAME' is not running."
    exit 1
fi

###############################################################################
# Find container init PID on host
###############################################################################

CONTAINER_INIT_HOST_PID="$(
    docker inspect \
        --format '{{.State.Pid}}' \
        "$CONTAINER_NAME"
)"

echo "Container               : $CONTAINER_NAME"
echo "Container PID 1 host PID: $CONTAINER_INIT_HOST_PID"

echo

ps -o pid,ppid,user,stat,etime,cmd \
    -p "$CONTAINER_INIT_HOST_PID" || true

###############################################################################
# Check real vLLM server
###############################################################################

echo
echo "======================================================================"
echo "Checking active vLLM server"
echo "======================================================================"

VLLM_PIDS="$(
    docker exec "$CONTAINER_NAME" bash -lc '
        ps -eo pid,stat,args |
        awk "
            \$2 !~ /Z/ &&
            /\/usr\/local\/bin\/vllm serve/ &&
            !/awk/ {
                print \$1
            }
        "
    ' 2>/dev/null || true
)"

if [[ -n "$VLLM_PIDS" ]]; then

    echo "Active vLLM server found:"
    echo "$VLLM_PIDS"

    echo
    echo "Refusing residual-worker cleanup."
    echo "Stop vLLM normally first."

    exit 2
fi

echo "No active vLLM serve process."

###############################################################################
# Check VRAM
###############################################################################

echo
echo "======================================================================"
echo "Current GPU state"
echo "======================================================================"

GPU_OUTPUT="$(./check_gpu_vram.sh)"
printf '%s\n' "$GPU_OUTPUT"

VRAM_BYTES="$(
    printf '%s\n' "$GPU_OUTPUT" |
    awk -F: '
        /VRAM Total Used Memory \(B\)/ {
            x=$NF
            gsub(/[[:space:]]/, "", x)
            print x
            exit
        }
    '
)"

if [[ -z "$VRAM_BYTES" ||
      ! "$VRAM_BYTES" =~ ^[0-9]+$ ]]; then

    echo "ERROR: Could not parse VRAM usage."
    exit 1
fi

THRESHOLD_BYTES=$((VRAM_THRESHOLD_MIB * 1024 * 1024))
VRAM_MIB=$((VRAM_BYTES / 1024 / 1024))

echo
echo "VRAM used: $VRAM_MIB MiB"

if (( VRAM_BYTES <= THRESHOLD_BYTES )); then
    echo "VRAM already below threshold."
    exit 0
fi

###############################################################################
# Find residual multiprocessing processes belonging to this container
###############################################################################

echo
echo "======================================================================"
echo "Searching for residual vLLM multiprocessing processes"
echo "======================================================================"

SPAWN_HOST_PIDS=()
TRACKER_HOST_PIDS=()

for p in /proc/[0-9]*; do

    host_pid="${p#/proc/}"

    [[ -r "$p/cmdline" ]] || continue
    [[ -r "$p/status" ]] || continue
    [[ -r "$p/cgroup" ]] || continue

    cmd="$(
        tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true
    )"

    [[ -n "$cmd" ]] || continue

    if [[ "$cmd" != *multiprocessing.spawn* &&
          "$cmd" != *multiprocessing.resource_tracker* ]]; then
        continue
    fi

    #
    # Make sure this process belongs to our container.
    #
    if ! grep -q "$(docker inspect -f '{{.Id}}' "$CONTAINER_NAME")" \
            "$p/cgroup" 2>/dev/null; then
        continue
    fi

    ppid="$(
        awk '/^PPid:/ {print $2}' \
            "$p/status"
    )"

    inner_pid="$(
        awk '/^NSpid:/ {print $NF}' \
            "$p/status"
    )"

    echo
    echo "HOST PID=$host_pid"
    echo "CONTAINER PID=$inner_pid"
    echo "PPID=$ppid"
    echo "CMD=$cmd"

    #
    # Key test:
    #
    # If the parent is the container init process, the worker has lost
    # its original vLLM parent and is now attached directly to PID 1
    # of the container.
    #
    if [[ "$ppid" == "$CONTAINER_INIT_HOST_PID" ]]; then
        echo "STATUS=RESIDUAL / ADOPTED BY CONTAINER PID 1"

        if [[ "$cmd" == *multiprocessing.spawn* ]]; then
            SPAWN_HOST_PIDS+=("$host_pid")
        fi

        if [[ "$cmd" == *multiprocessing.resource_tracker* ]]; then
            TRACKER_HOST_PIDS+=("$host_pid")
        fi
    else
        echo "STATUS=NOT CLASSIFIED AS ORPHAN"
    fi

done

###############################################################################
# Helper: host PID -> container PID
###############################################################################

container_pid_for_host_pid() {

    local host_pid="$1"

    awk '/^NSpid:/ {print $NF}' \
        "/proc/$host_pid/status" 2>/dev/null
}

###############################################################################
# Kill residual multiprocessing.spawn workers first
###############################################################################

echo
echo "======================================================================"
echo "Cleaning residual GPU workers"
echo "======================================================================"

if (( ${#SPAWN_HOST_PIDS[@]} == 0 )); then

    echo "No residual multiprocessing.spawn worker found."

else

    for host_pid in "${SPAWN_HOST_PIDS[@]}"; do

        [[ -d "/proc/$host_pid" ]] || continue

        inner_pid="$(
            container_pid_for_host_pid "$host_pid"
        )"

        echo
        echo "SIGTERM:"
        echo "  host PID      = $host_pid"
        echo "  container PID = $inner_pid"

        docker exec -u 0 "$CONTAINER_NAME" \
            kill -TERM "$inner_pid" \
            2>/dev/null || true
    done

    echo
    echo "Waiting ${TERM_WAIT}s..."
    sleep "$TERM_WAIT"

fi

###############################################################################
# Recheck workers; SIGKILL only if necessary
###############################################################################

for host_pid in "${SPAWN_HOST_PIDS[@]}"; do

    if [[ -d "/proc/$host_pid" ]]; then

        inner_pid="$(
            container_pid_for_host_pid "$host_pid"
        )"

        echo
        echo "Worker host PID=$host_pid survived SIGTERM."
        echo "Sending SIGKILL to container PID=$inner_pid."

        docker exec -u 0 "$CONTAINER_NAME" \
            kill -KILL "$inner_pid" \
            2>/dev/null || true
    fi

done

sleep "$POLL_INTERVAL"

###############################################################################
# Clean resource trackers afterward
###############################################################################

echo
echo "======================================================================"
echo "Cleaning residual resource trackers"
echo "======================================================================"

for host_pid in "${TRACKER_HOST_PIDS[@]}"; do

    [[ -d "/proc/$host_pid" ]] || continue

    inner_pid="$(
        container_pid_for_host_pid "$host_pid"
    )"

    echo
    echo "SIGTERM:"
    echo "  host PID      = $host_pid"
    echo "  container PID = $inner_pid"

    docker exec -u 0 "$CONTAINER_NAME" \
        kill -TERM "$inner_pid" \
        2>/dev/null || true

done

sleep "$TERM_WAIT"

###############################################################################
# Final check
###############################################################################

echo
echo "======================================================================"
echo "FINAL GPU STATE"
echo "======================================================================"

rocm-smi --showpids
rocm-smi --showmeminfo vram

