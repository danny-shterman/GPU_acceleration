#!/usr/bin/env bash
set -euo pipefail

LOG="/workspace/kit/results/vllm_rocprof_server.log"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
TRACE_ROOT="/workspace/kit/results/qwen3_sys_trace/${RUN_ID}"
RAW_DIR="${TRACE_ROOT}/raw"
CONVERTED_DIR="${TRACE_ROOT}/converted"

CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
MODEL_ID="${MODEL_ID:-Qwen/Qwen3-32B}"
PORT="${PORT:-8000}"

LOG="/workspace/kit/results/vllm_rocprof_server.log"

echo "Container: ${CONTAINER_NAME}"
echo "Model:     ${MODEL_ID}"
echo "Port:      ${PORT}"
echo "Log:       ${LOG}"
echo

echo "Stopping previous vLLM server, if present..."

docker exec "${CONTAINER_NAME}" \
    bash -lc "pkill -f '[v]llm serve' || true"

sleep 2

echo "Previous server stopped."
echo

echo "Starting Qwen3-32B..."

# python code is used to generate a rotating log file for the vLLM server, so that the log file does not grow too large.
echo "Starting Qwen3-32B under rocprofv3..."
echo "Trace directory: ${TRACE_ROOT}"

docker exec -d "${CONTAINER_NAME}" \
  bash -lc "
    set -o pipefail

    cd /workspace/kit

    mkdir -p '${RAW_DIR}'
    mkdir -p '${CONVERTED_DIR}'

    rm -f '${LOG}' '${LOG}.1' '${LOG}.2'

    PROFILE_STATUS='${TRACE_ROOT}/profile_status.txt'
    CONVERSION_LOG='${TRACE_ROOT}/conversion.log'

    echo 'Starting rocprofv3 ROCPD collection...' \
        > \"\$CONVERSION_LOG\"

    set +e

    rocprofv3 \
        --sys-trace \
        --output-format rocpd \
        --output-directory '${RAW_DIR}' \
        -- \
        vllm serve '${MODEL_ID}' \
            --host 0.0.0.0 \
            --port '${PORT}' \
            --dtype bfloat16 \
            --max-model-len 32768 \
            --gpu-memory-utilization 0.90 \
            --no-enable-prefix-caching \
        > '${LOG}' 2>&1

    ROCPROF_RC=\$?

    echo \"rocprofv3_exit_status=\${ROCPROF_RC}\" \
        > \"\$PROFILE_STATUS\"

    echo >> \"\$CONVERSION_LOG\"
    echo 'rocprofv3 finished.' \
        >> \"\$CONVERSION_LOG\"

    echo 'Searching for ROCPD databases...' \
        >> \"\$CONVERSION_LOG\"

    mapfile -t DBS < <(
        find '${RAW_DIR}' \
            -type f \
            -name '*_results.db' \
            | sort
    )

    printf 'Found %d database(s).\n' \"\${#DBS[@]}\" \
        >> \"\$CONVERSION_LOG\"

    printf '%s\n' \"\${DBS[@]}\" \
        >> \"\$CONVERSION_LOG\"

    if (( \${#DBS[@]} == 0 )); then
        echo 'ERROR: rocprofv3 generated no ROCPD database.' \
            >> \"\$CONVERSION_LOG\"

        echo 'csv_conversion_exit_status=3' \
            >> \"\$PROFILE_STATUS\"

        echo 'pftrace_conversion_exit_status=3' \
            >> \"\$PROFILE_STATUS\"

        exit 3
    fi

    echo >> \"\$CONVERSION_LOG\"

    echo 'Converting ROCPD -> CSV...' \
        >> \"\$CONVERSION_LOG\"

    rocpd2csv \
        -i \"\${DBS[@]}\" \
        -d '${CONVERTED_DIR}' \
        -o qwen3_sys_trace \
        >> \"\$CONVERSION_LOG\" 2>&1

    CSV_RC=\$?

    echo \"csv_conversion_exit_status=\${CSV_RC}\" \
        >> \"\$PROFILE_STATUS\"

    echo 'Converting ROCPD -> PFTrace...' \
        >> \"\$CONVERSION_LOG\"

    rocpd2pftrace \
        -i \"\${DBS[@]}\" \
        -d '${CONVERTED_DIR}' \
        -o qwen3_sys_trace \
        >> \"\$CONVERSION_LOG\" 2>&1

    PFTRACE_RC=\$?

    echo \"pftrace_conversion_exit_status=\${PFTRACE_RC}\" \
        >> \"\$PROFILE_STATUS\"

    if (( CSV_RC != 0 || PFTRACE_RC != 0 )); then
        echo \"ERROR: conversion failed: CSV=\${CSV_RC}, PFTrace=\${PFTRACE_RC}\" \
            >> \"\$CONVERSION_LOG\"

        exit 4
    fi

    echo 'ROCPD conversions completed successfully.' \
        >> \"\$CONVERSION_LOG\"

    exit \"\$ROCPROF_RC\"
  "

echo "vLLM launch command submitted."
echo "Server log: ${LOG}"
echo

echo "Waiting for server readiness..."

MAX_ATTEMPTS=300

for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do

    HTTP_CODE="$(
        docker exec "${CONTAINER_NAME}" \
            curl -s -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:${PORT}/health" \
            2>/dev/null || true
    )"

    if [[ "${HTTP_CODE}" == "200" ]]; then
        echo
        echo "vLLM server is READY."
        echo

        echo "Models:"
        docker exec "${CONTAINER_NAME}" \
            curl -sS "http://127.0.0.1:${PORT}/v1/models"

        echo
        echo
        echo "Server URL:"
        echo "  http://127.0.0.1:${PORT}"
        echo

        exit 0
    fi

    # Detect an early vLLM failure instead of waiting 10 minutes.
    if ! docker exec "${CONTAINER_NAME}" \
        bash -lc "pgrep -f '[v]llm serve' >/dev/null"; then

        echo
        echo "ERROR: vLLM process exited before becoming ready."
        echo
        echo "Last 100 lines of server log:"
        docker exec "${CONTAINER_NAME}" \
            tail -n 100 "${LOG}" || true

        exit 1
    fi

    if (( attempt % 5 == 0 )); then
        echo "Still waiting... attempt ${attempt}/${MAX_ATTEMPTS}, HTTP=${HTTP_CODE:-000}"
    fi

    sleep 2
done

echo
echo "ERROR: vLLM did not become ready."
echo
echo "Last 100 lines of server log:"

docker exec "${CONTAINER_NAME}" \
    tail -n 100 "${LOG}" || true

exit 1

