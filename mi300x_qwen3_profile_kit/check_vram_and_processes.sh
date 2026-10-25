#!/usr/bin/env bash
set -euo pipefail

THRESHOLD_MIB=30
THRESHOLD_BYTES=$((THRESHOLD_MIB * 1024 * 1024))

CHECK_SCRIPT="./check_gpu_vram.sh"

if [[ ! -x "$CHECK_SCRIPT" ]]; then
    echo "ERROR: $CHECK_SCRIPT does not exist or is not executable."
    exit 1
fi

###############################################################################
# Run check_gpu_vram.sh and preserve/print its output
###############################################################################

OUTPUT="$("$CHECK_SCRIPT")"

printf '%s\n' "$OUTPUT"

###############################################################################
# Extract:
#
# GPU[0] : VRAM Total Used Memory (B): 181210148864
###############################################################################

VRAM_USED_BYTES="$(
    printf '%s\n' "$OUTPUT" |
    awk -F: '
        /VRAM Total Used Memory \(B\)/ {
            value=$NF
            gsub(/[[:space:]]/, "", value)
            print value
            exit
        }
    '
)"

if [[ -z "$VRAM_USED_BYTES" || ! "$VRAM_USED_BYTES" =~ ^[0-9]+$ ]]; then
    echo
    echo "ERROR: Could not parse 'VRAM Total Used Memory (B)' from check_gpu_vram.sh."
    exit 1
fi

VRAM_USED_MIB=$((VRAM_USED_BYTES / 1024 / 1024))

echo
echo "=================================================="
echo "VRAM check"
echo "=================================================="
echo "VRAM used: ${VRAM_USED_BYTES} bytes"
echo "VRAM used: ${VRAM_USED_MIB} MiB"
echo "Threshold: ${THRESHOLD_MIB} MiB"

###############################################################################
# Stop if VRAM usage is <= threshold
###############################################################################

if (( VRAM_USED_BYTES <= THRESHOLD_BYTES )); then
    echo
    echo "VRAM usage is <= ${THRESHOLD_MIB} MiB."
    echo "No process investigation required."
    exit 0
fi

echo
echo "WARNING: VRAM usage is greater than ${THRESHOLD_MIB} MiB."
echo "Investigating KFD processes..."

###############################################################################
# Extract PIDs from this part of check_gpu_vram.sh output:
#
# PID     PROCESS NAME    GPU(s) ...
# 29841   python          1 ...
# 29840   python          0 ...
#
# Restrict parsing to the KFD-process section.
###############################################################################

mapfile -t PIDS < <(
    printf '%s\n' "$OUTPUT" |
    awk '
        /KFD process information:/ {
            in_kfd=1
            next
        }

        /End of ROCm SMI Log/ {
            if (in_kfd)
                exit
        }

        in_kfd && $1 ~ /^[0-9]+$/ {
            print $1
        }
    ' |
    sort -nu
)

###############################################################################
# VRAM > threshold but ROCm reports no KFD process
###############################################################################

if (( ${#PIDS[@]} == 0 )); then
    echo
    echo "VRAM usage is high, but no KFD process PIDs were found."
    echo
    echo "This may be driver/runtime-reserved VRAM rather than memory owned"
    echo "by an active userspace GPU process."
    exit 2
fi

echo
echo "Found KFD PID(s): ${PIDS[*]}"

###############################################################################
# Inspect every detected process
###############################################################################

for p in "${PIDS[@]}"; do
    echo
    echo "=================================================="
    echo "HOST PID=$p"
    echo "=================================================="

    if [[ ! -d "/proc/$p" ]]; then
        echo "Process $p disappeared before it could be inspected."
        continue
    fi

    ps -o pid,ppid,user,stat,etime,cmd -p "$p" || true

    echo
    echo "--- status ---"
    grep -E '^(Name|State|PPid|NSpid):' \
        "/proc/$p/status" 2>/dev/null || true

    echo
    echo "--- cmdline ---"
    if [[ -r "/proc/$p/cmdline" ]]; then
        tr '\0' ' ' < "/proc/$p/cmdline"
        echo
    fi

    echo
    echo "--- cwd ---"
    readlink -f "/proc/$p/cwd" 2>/dev/null || true

    echo
    echo "--- cgroup ---"
    cat "/proc/$p/cgroup" 2>/dev/null || true

    echo
    echo "--- ROCprofiler libraries ---"
    grep -Ei 'rocprof|rocprofiler' \
        "/proc/$p/maps" 2>/dev/null |
        head -5 || true
done
