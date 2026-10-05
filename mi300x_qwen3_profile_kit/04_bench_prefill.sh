#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-32B}"
CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
PORT="${PORT:-8000}"

echo "Container: ${CONTAINER_NAME}"
echo "Model:     ${MODEL_ID}"
echo "Port:      ${PORT}"
echo

# Generate the prompt files INSIDE the vLLM container.
# The host Python environment does not need transformers installed.
echo "Generating prefill prompts..."
docker exec "${CONTAINER_NAME}" \
    bash -lc 'cd /workspace/kit && python3 ./07_generate_prompts.py'

echo
echo "Prompt generation completed."

run_case() {
    local name="$1"
    local concurrency="$2"
    local prompts="$3"
    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"

    echo
    echo "============================================================"
    echo "Prefill case: ${name}"
    echo "Concurrency:  ${concurrency}"
    echo "Prompts:      ${prompts}"
    echo "============================================================"

    echo "Checking vLLM health..."
    if ! docker exec "${CONTAINER_NAME}" \
        curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
        echo "ERROR: vLLM is not healthy on port ${PORT}."
        echo
        echo "Last 100 server-log lines:"
        docker exec "${CONTAINER_NAME}" \
            tail -n 100 /workspace/kit/results/vllm_server.log || true
        exit 1
    fi
    echo "vLLM server is healthy."

    docker exec "${CONTAINER_NAME}" bash -lc "
        set -euo pipefail
        cd /workspace/kit

        vllm bench serve \
            --ready-check-timeout-sec 600 \
            --temperature 0 \
            --backend openai \
            --base-url 'http://127.0.0.1:${PORT}' \
            --model '${MODEL_ID}' \
            --dataset-name custom \
            --dataset-path '/workspace/kit/prompts/${name}.jsonl' \
            --skip-chat-template \
            --custom-output-len 1 \
            --num-prompts '${prompts}' \
            --num-warmups 2 \
            --request-rate inf \
            --max-concurrency '${concurrency}' \
            --ignore-eos \
            --percentile-metrics ttft,e2el \
            --metric-percentiles 50,90,95,99 \
            --save-result \
            --save-detailed \
            --result-dir /workspace/kit/results \
            --result-filename 'prefill_${name}_${stamp}.json'
    "
}

run_case short 1 10
run_case medium 1 10
run_case long 1 10
run_case large_batch 16 64

echo
echo "All prefill benchmark cases completed."

