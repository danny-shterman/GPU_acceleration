#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-32B}"
CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
PORT="${PORT:-8000}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

python3 ./07_generate_prompts.py

run_case() {
    local name="$1"
    local concurrency="$2"
    local prompts="$3"
    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"

    docker exec "$CONTAINER_NAME" bash -lc "
      cd /workspace/kit
      vllm bench serve \
        --backend openai \
        --base-url 'http://127.0.0.1:${PORT}' \
        --model '$MODEL_ID' \
        --dataset-name custom \
        --dataset-path '/workspace/kit/prompts/${name}.jsonl' \
        --skip-chat-template \
        --custom-output-len 1 \
        --num-prompts '$prompts' \
        --num-warmups 2 \
        --request-rate inf \
        --max-concurrency '$concurrency' \
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
