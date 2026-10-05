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
        --dataset-name custom \
        --dataset-path '/home/hotaisle/users/danny/gpu_accelerate/mi300x_qwen3_profile_kit/prompts/${name}.jsonl' \
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
        --result-dir /home/hotaisle/users/danny/gpu_accelerate/mi300x_qwen3_profile_kit/results \
        --result-filename 'prefill_${name}_${stamp}.json'
    "
}

run_case short 1 10
run_case medium 1 10
run_case long 1 10
run_case large_batch 16 64
