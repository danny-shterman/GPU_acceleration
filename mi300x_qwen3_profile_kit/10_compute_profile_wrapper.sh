#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
    echo "Usage: $0 COMMAND [ARGS...]"
    exit 2
fi

if ! command -v rocprof-compute >/dev/null 2>&1; then
    echo "ERROR: rocprof-compute not found."
    exit 1
fi

NAME="${PROFILE_NAME:-mi300x_$(date +%Y%m%d_%H%M%S)}"

echo "Installed metric sets:"
rocprof-compute profile --list-sets || true

echo
echo "Profiling as workload: $NAME"
echo "NOTE: counter profiling may replay/serialize the workload."

rocprof-compute profile \
    --name "$NAME" \
    --no-roof \
    -- "$@"

echo
echo "Analyze the generated workload directory with:"
echo "  rocprof-compute analyze -p workloads/${NAME}/MI300X/"
