#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
MODEL_ID="${MODEL_ID:-Qwen/Qwen3-32B}"
PORT="${PORT:-8000}"

LOG="/workspace/kit/results/vllm_server.log"

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
docker exec -d "${CONTAINER_NAME}" \
  bash -lc "
    cd /workspace/kit

    rm -rf /workspace/kit/results/qwen3_sys_trace
    mkdir -p /workspace/kit/results/qwen3_sys_trace

    exec rocprofv3 \
        --sys-trace \
        --output-format pftrace \
        --output-directory /workspace/kit/results/qwen3_sys_trace \
        -- \
        vllm serve '${MODEL_ID}' \
            --host 0.0.0.0 \
            --port '${PORT}' \
            --dtype bfloat16 \
            --max-model-len 32768 \
            --gpu-memory-utilization 0.90 \
            --no-enable-prefix-caching \
        2>&1 | python3 -u -c '
            import sys
            from logging.handlers import RotatingFileHandler
            import logging

            path = "/workspace/kit/results/vllm_rocprof_server.log"

            handler = RotatingFileHandler(
                path,
                maxBytes=100 * 1024 * 1024,
                backupCount=2
            )

            handler.setFormatter(logging.Formatter("%(message)s"))

            logger = logging.getLogger("vllm")
            logger.setLevel(logging.INFO)
            logger.addHandler(handler)
            logger.propagate = False

            for line in sys.stdin:
                logger.info(line.rstrip("\n"))
        '
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

