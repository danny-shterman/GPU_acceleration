#!/usr/bin/env bash
set -euo pipefail

MAX_GIB="${HBM_LATENCY_MAX_GIB:-8}"
ITERS="${HBM_LATENCY_ITERS:-1000000}"
OUT="${1:-results/hbm_latency.csv}"

command -v hipcc >/dev/null 2>&1 || {
    echo "ERROR: hipcc not found."
    exit 1
}

hipcc -O3 -std=c++17 hbm_latency.hip -o hbm_latency

./hbm_latency "$MAX_GIB" "$ITERS" | tee "$OUT"

echo
echo "Interpretation:"
echo "  small working sets -> cache latency"
echo "  transitions        -> cache/TLB boundaries"
echo "  large working sets -> HBM-dominated dependent-load latency"
echo
echo "Do not compare this number directly with streaming GB/s."
