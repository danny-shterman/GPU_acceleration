#!/usr/bin/env bash
set -euo pipefail

INTERVAL="${MONITOR_INTERVAL:-1}"
DURATION="${MONITOR_DURATION:-300}"
OUT="${1:-results/amd_smi_monitor_$(date +%Y%m%d_%H%M%S).csv}"

mkdir -p "$(dirname "$OUT")"

if ! command -v amd-smi >/dev/null 2>&1; then
    echo "ERROR: amd-smi not found."
    exit 1
fi

echo "Monitoring for ${DURATION}s -> $OUT"

# Current AMD SMI supports monitor/watch mode. If the installed version differs,
# inspect: amd-smi monitor --help
amd-smi monitor \
    --gpu 0 \
    --csv \
    --file "$OUT" \
    --watch "$INTERVAL" \
    --watch-time "$DURATION"

echo "Telemetry: $OUT"
