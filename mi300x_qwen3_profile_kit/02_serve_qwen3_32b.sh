#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-32B}"
CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"

echo "KUKU100"

docker exec "$CONTAINER_NAME" bash -lc \
    "pkill -f 'vllm serve' >/dev/null 2>&1 || true"
echo "KUKU200"

docker exec -d "$CONTAINER_NAME" bash -lc "
    cd /home/hotaisle/users/danny/gpu_accelerate/mi300x_qwen3_profile_kit
    exec vllm serve '$MODEL_ID' \
      --host 0.0.0.0 \
      --port '$PORT' \
      --dtype bfloat16 \
      --max-model-len '$MAX_MODEL_LEN' \
      --gpu-memory-utilization '$GPU_MEMORY_UTILIZATION' \
      2>&1 | tee /home/hotaisle/users/danny/gpu_accelerate/mi300x_qwen3_profile_kit/results/vllm_server.log/vllm_server.log
"

echo "Starting Qwen3-32B..."
echo "Server log: results/vllm_server.log"

for i in $(seq 1 180); do
    if curl -fsS "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
        echo "Server ready."
        exit 0
    fi
    sleep 2
done

echo "ERROR: server did not become ready."
docker exec "$CONTAINER_NAME" tail -100 /home/hotaisle/users/danny/gpu_accelerate/mi300x_qwen3_profile_kit/results/vllm_server.log || true
exit 1
