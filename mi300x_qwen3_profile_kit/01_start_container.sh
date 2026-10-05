#!/usr/bin/env bash
set -euo pipefail

VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai-rocm:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
PORT="${PORT:-8000}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"

# Actual host directory containing this script.
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$HF_CACHE"
mkdir -p "$KIT_DIR/results"

echo "Host kit directory: $KIT_DIR"
echo "Container mount:    $KIT_DIR -> /workspace/kit"
echo "Container:          $CONTAINER_NAME"
echo "Image:              $VLLM_IMAGE"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found."
    exit 1
fi

if [[ ! -e /dev/kfd ]]; then
    echo "ERROR: /dev/kfd does not exist."
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
    --mount type=bind,source="$KIT_DIR",target=/workspace/kit \
    --entrypoint /bin/bash \
    "$VLLM_IMAGE" \
    -lc 'sleep infinity'

echo
echo "Container started: $CONTAINER_NAME"

echo
echo "=== Mount verification ==="

docker exec "$CONTAINER_NAME" \
    bash -lc 'pwd; ls -la /workspace/kit | head -30'

echo
echo "=== PyTorch / ROCm verification ==="

docker exec -i "$CONTAINER_NAME" python3 - <<'PY'
import sys
import torch

print("PyTorch:", torch.__version__)
print("HIP:", torch.version.hip)
print("GPU available:", torch.cuda.is_available())
print("GPU count:", torch.cuda.device_count())

if not torch.cuda.is_available():
    print("ERROR: ROCm GPU not available through PyTorch")
    sys.exit(1)

for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    print(f"GPU {i}: {p.name}")
    print(f"  memory: {p.total_memory / 1024**3:.2f} GiB")
    print(f"  compute units: {p.multi_processor_count}")
PY

echo
echo "Container validation successful."

