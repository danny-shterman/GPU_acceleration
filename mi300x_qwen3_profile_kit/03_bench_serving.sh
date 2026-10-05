#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-32B}"
CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
PORT="${PORT:-8000}"
NUM_PROMPTS="${NUM_PROMPTS:-100}"
INPUT_LEN="${INPUT_LEN:-1024}"
OUTPUT_LEN="${OUTPUT_LEN:-128}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"
REQUEST_RATE="${REQUEST_RATE:-inf}"

STAMP="$(date +%Y%m%d_%H%M%S)"
RESULT="serving_${STAMP}.json"

docker exec "$CONTAINER_NAME" bash -lc "
  cd /workspace/kit
  vllm bench serve \
    --backend openai \
    --base-url 'http://127.0.0.1:${PORT}' \
    --model '$MODEL_ID' \
    --dataset-name random \
    --random-input-len '$INPUT_LEN' \
    --random-output-len '$OUTPUT_LEN' \
    --random-range-ratio 0.0 \
    --num-prompts '$NUM_PROMPTS' \
    --num-warmups 5 \
    --request-rate '$REQUEST_RATE' \
    --max-concurrency '$MAX_CONCURRENCY' \
    --ignore-eos \
    --percentile-metrics ttft,tpot,itl,e2el \
    --metric-percentiles 50,90,95,99 \
    --save-result \
    --save-detailed \
    --result-dir /workspace/kit/results \
    --result-filename '$RESULT'
"

echo "Result: results/$RESULT"
