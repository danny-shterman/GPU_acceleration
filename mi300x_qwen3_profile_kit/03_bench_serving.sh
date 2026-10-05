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
  cd /home/hotaisle/users/danny/gpu_accelerate/mi300x_qwen3_profile_kit
  echo "Checking vLLM server..."

  if ! docker exec "$CONTAINER_NAME" \
      curl -fsS "http://127.0.0.1:${PORT}/v1/models" >/dev/null
  then
      echo "ERROR: vLLM server is not reachable on port ${PORT}."
      echo
      echo "Server process:"
      docker exec "$CONTAINER_NAME" \
          bash -lc 'ps aux | grep -E "[v]llm|[a]pi_server" || true'
  
      echo
      echo "Listening sockets:"
      docker exec "$CONTAINER_NAME" \
          bash -lc "ss -lntp | grep ':${PORT}' || true"
  
      echo
      echo "Last 100 server-log lines:"
      docker exec "$CONTAINER_NAME" \
          tail -100 /home/hotaisle/users/danny/gpu_accelerate/mi300x_qwen3_profile_kit/results/vllm_server.log || true
  
      exit 1
  fi
  
  echo "vLLM server is ready."

  echo "Checking vLLM health..."

  if ! docker exec "$CONTAINER_NAME" \
      curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null
  then
      echo "ERROR: vLLM is not healthy on port ${PORT}."
      echo "Check whether the server is still initializing or has failed."
      exit 1
  fi
  
  echo "vLLM health check passed."
  
  echo "Checking model endpoint..."
  
  docker exec "$CONTAINER_NAME" \
      curl -fsS "http://127.0.0.1:${PORT}/v1/models"
  
  echo

  vllm bench serve \
    --ready-check-timeout-sec 600 \
    --temperature 0 \\
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
    --result-dir /home/hotaisle/users/danny/gpu_accelerate/mi300x_qwen3_profile_kit/results \
    --result-filename '$RESULT'
"

echo "Result: results/$RESULT"
