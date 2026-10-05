#!/usr/bin/env bash
set -euo pipefail

GIB="${HBM_BW_GIB:-8}"
REPEATS="${HBM_BW_REPEATS:-10}"
OUT="${1:-results/hbm_bandwidth.csv}"

command -v hipcc >/dev/null 2>&1 || {
    echo "ERROR: hipcc not found."
    exit 1
}

hipcc -O3 -std=c++17 hbm_bandwidth.hip -o hbm_bandwidth

./hbm_bandwidth "$GIB" "$REPEATS" | tee "$OUT"
