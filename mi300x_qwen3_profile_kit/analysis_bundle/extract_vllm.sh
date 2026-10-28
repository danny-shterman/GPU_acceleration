#!/usr/bin/env bash
set -euo pipefail

CONTAINER=mi300x-qwen3-profile
OUT=analysis_bundle/vllm_active_source.tar.gz

docker exec "$CONTAINER" bash -lc '
set -e
VLLM_DIR=$(python3 -c "
import vllm
from pathlib import Path
print(Path(vllm.__file__).resolve().parent)
")
cd "$(dirname "$VLLM_DIR")"
tar -czf - "$(basename "$VLLM_DIR")"
' > "$OUT"

echo "Created: $OUT"
ls -lh "$OUT"
