#!/usr/bin/env bash
set -euo pipefail

VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai-rocm:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
PORT="${PORT:-8000}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$HF_CACHE" "$KIT_DIR/results"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found."
    exit 1
fi

if [[ ! -e /dev/kfd ]]; then
    echo "ERROR: /dev/kfd does not exist. ROCm driver is not available."
    exit 1
fi

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker pull "$VLLM_IMAGE"

docker run -d \
    --name "$CONTAINER_NAME" \
    --group-add=video \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --device /dev/kfd \
    --device /dev/dri \
    --ipc=host \
    -p "${PORT}:${PORT}" \
    -v "$HF_CACHE:/root/.cache/huggingface" \
    -v "$KIT_DIR:/home/hotaisle/users/danny/gpu_accelerate/mi300x_qwen3_profile_kit" \
    --entrypoint /bin/bash \
    "$VLLM_IMAGE" \
    -lc 'sleep infinity'

echo "Container started: $CONTAINER_NAME"
docker exec "$CONTAINER_NAME" python3 - <<'PY'
import torch
print("torch:", torch.__version__)
print("HIP:", torch.version.hip)
print("CUDA API available:", torch.cuda.is_available())
print("device count:", torch.cuda.device_count())
for i in range(torch.cuda.device_count()):
    print(i, torch.cuda.get_device_name(i))
PY
