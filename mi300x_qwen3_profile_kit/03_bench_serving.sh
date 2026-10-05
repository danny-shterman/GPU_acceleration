#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 03_bench_serving.sh
#
# Benchmark an already-running vLLM OpenAI-compatible server inside the
# mi300x-qwen3-profile container.
#
# Defaults can be overridden from the environment, for example:
#
#   NUM_PROMPTS=64 INPUT_LEN=2048 OUTPUT_LEN=256 bash 03_bench_serving.sh
# -----------------------------------------------------------------------------

CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
MODEL="${MODEL:-Qwen/Qwen3-32B}"
PORT="${PORT:-8000}"

NUM_PROMPTS="${NUM_PROMPTS:-32}"
INPUT_LEN="${INPUT_LEN:-1024}"
OUTPUT_LEN="${OUTPUT_LEN:-128}"
REQUEST_RATE="${REQUEST_RATE:-inf}"

RESULT_DIR="${RESULT_DIR:-/workspace/kit/results}"
BASE_URL="http://127.0.0.1:${PORT}"

echo "Container:      ${CONTAINER_NAME}"
echo "Model:          ${MODEL}"
echo "Server:         ${BASE_URL}"
echo "Prompts:        ${NUM_PROMPTS}"
echo "Input length:   ${INPUT_LEN}"
echo "Output length:  ${OUTPUT_LEN}"
echo "Request rate:   ${REQUEST_RATE}"
echo "Result dir:     ${RESULT_DIR}"
echo

# -----------------------------------------------------------------------------
# 1. Verify that the Docker container exists and is running.
# -----------------------------------------------------------------------------

if ! docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -qx 'true'; then
    echo "ERROR: Docker container '${CONTAINER_NAME}' is not running."
    echo "Start the container first, then run this script again."
    exit 1
fi

echo "Docker container is running."

# -----------------------------------------------------------------------------
# 2. Verify vLLM health.
#
# Do NOT use 'ss' here.  The HTTP health endpoint is the relevant check.
# -----------------------------------------------------------------------------

echo "Checking vLLM health..."

if docker exec "${CONTAINER_NAME}" \
    curl -fsS "${BASE_URL}/health" >/dev/null 2>&1; then
    echo "vLLM server is healthy."
else
    echo "ERROR: vLLM server is not responding at ${BASE_URL}/health"
    echo
    echo "Last 100 lines of the vLLM log:"
    docker exec "${CONTAINER_NAME}" \
        tail -n 100 "${RESULT_DIR}/vllm_server.log" 2>/dev/null || true
    exit 1
fi

# -----------------------------------------------------------------------------
# 3. Verify that the expected model is served.
# -----------------------------------------------------------------------------

echo "Checking served model..."

MODELS_JSON="$(
    docker exec "${CONTAINER_NAME}" \
        curl -fsS "${BASE_URL}/v1/models"
)"

if ! printf '%s' "${MODELS_JSON}" | grep -Fq "\"id\":\"${MODEL}\""; then
    # vLLM/JSON formatting can include spaces, so perform a second looser check.
    if ! printf '%s' "${MODELS_JSON}" | grep -Fq "${MODEL}"; then
        echo "ERROR: Expected model '${MODEL}' was not returned by /v1/models."
        echo
        echo "Server response:"
        printf '%s\n' "${MODELS_JSON}"
        exit 1
    fi
fi

echo "Model is available."
echo

# -----------------------------------------------------------------------------
# 4. Make sure the results directory exists.
# -----------------------------------------------------------------------------

docker exec "${CONTAINER_NAME}" mkdir -p "${RESULT_DIR}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_JSON="${RESULT_DIR}/bench_serving_${TIMESTAMP}.json"
RESULT_LOG="${RESULT_DIR}/bench_serving_${TIMESTAMP}.log"

echo "Benchmark output:"
echo "  ${RESULT_LOG}"
echo "  ${RESULT_JSON}"
echo

# -----------------------------------------------------------------------------
# 5. Run a serving benchmark.
#
# First try the normal vLLM CLI:
#     vllm bench serve ...
#
# If that CLI form is unavailable in the container, fail with a clear message
# rather than silently running some unrelated benchmark.
# -----------------------------------------------------------------------------

echo "Starting vLLM serving benchmark..."
echo

docker exec \
    -e MODEL="${MODEL}" \
    -e BASE_URL="${BASE_URL}" \
    -e NUM_PROMPTS="${NUM_PROMPTS}" \
    -e INPUT_LEN="${INPUT_LEN}" \
    -e OUTPUT_LEN="${OUTPUT_LEN}" \
    -e REQUEST_RATE="${REQUEST_RATE}" \
    -e RESULT_DIR="${RESULT_DIR}" \
    -e RESULT_JSON="${RESULT_JSON}" \
    -e RESULT_LOG="${RESULT_LOG}" \
    "${CONTAINER_NAME}" \
    bash -lc '
        set -euo pipefail

        if ! command -v vllm >/dev/null 2>&1; then
            echo "ERROR: vllm CLI is not available in the container."
            exit 1
        fi

        echo "vLLM version:"
        vllm --version || true
        echo

        set +e

        vllm bench serve \
            --backend vllm \
            --model "$MODEL" \
            --base-url "$BASE_URL" \
            --dataset-name random \
            --num-prompts "$NUM_PROMPTS" \
            --random-input-len "$INPUT_LEN" \
            --random-output-len "$OUTPUT_LEN" \
            --request-rate "$REQUEST_RATE" \
            --save-result \
            --result-dir "$RESULT_DIR" \
            --result-filename "$(basename "$RESULT_JSON")" \
            2>&1 | tee "$RESULT_LOG"

        rc=${PIPESTATUS[0]}
        set -e

        if [ "$rc" -ne 0 ]; then
            echo
            echo "ERROR: vLLM serving benchmark failed with exit code $rc."
            echo
            echo "Check supported options with:"
            echo "  docker exec '"${CONTAINER_NAME}"' vllm bench serve --help"
            exit "$rc"
        fi
    '

echo
echo "Benchmark completed successfully."
echo
echo "Results inside container:"
echo "  ${RESULT_LOG}"
echo "  ${RESULT_JSON}"
echo
echo "To inspect the JSON result:"
echo "  docker exec ${CONTAINER_NAME} cat ${RESULT_JSON}"

