#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
    echo "Usage: $0 COMMAND [ARGS...]"
    exit 2
fi

OUT="${TRACE_OUT:-results/rocprof_trace_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"

if command -v rocprofv3 >/dev/null 2>&1; then
    echo "Using rocprofv3."
    rocprofv3 \
        --sys-trace \
        --output-directory "$OUT" \
        -- "$@"

    echo "Trace directory: $OUT"

    if command -v rocpd >/dev/null 2>&1; then
        DB="$(find "$OUT" -type f -name '*_results.db' | head -1 || true)"
        if [[ -n "$DB" ]]; then
            echo "ROCPD database: $DB"
            echo "To convert it:"
            echo "  rocpd convert -i \"$DB\" --output-format pftrace"
            echo "  rocpd convert -i \"$DB\" --output-format csv"
        fi
    fi
else
    echo "ERROR: rocprofv3 not found."
    echo "Check the ROCm installation and profiler packages."
    exit 1
fi
