#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-mi300x_qwen3_profile_kit}"
ZIP="${ROOT}.zip"

rm -rf "$ROOT" "$ZIP"
mkdir -p "$ROOT/results" "$ROOT/prompts" "$ROOT/graphs"

###############################################################################
# README
###############################################################################
cat > "$ROOT/README.md" <<'EOF'
# MI300X / Qwen3-32B profiling kit

Target:
- One physical AMD Instinct MI300X
- Qwen/Qwen3-32B
- ROCm
- vLLM ROCm container
- gfx942 expected for MI300X

This kit separates:
1. machine discovery
2. workload generation
3. serving benchmark
4. telemetry
5. HBM latency
6. HBM bandwidth
7. timeline tracing
8. hardware-counter profiling
9. static DFG extraction
10. end-to-end optimization DFG

IMPORTANT:
Do not assume profiler counter names from documentation or another ROCm release.
Query the counters/metric sets installed on the actual machine.

Recommended order:

    ./00_collect_system.sh

    cp .env.example .env
    # edit .env if required
    source .env

    ./01_start_container.sh
    ./02_serve_qwen3_32b.sh

    # Wait until server is ready.
    ./07_generate_prompts.py

    ./05_monitor_amd_smi.sh &
    MONITOR_PID=$!

    ./03_bench_serving.sh
    ./04_bench_prefill.sh

    wait "$MONITOR_PID" || true

    ./06_build_and_run_hbm_latency.sh
    ./06b_build_and_run_hbm_bandwidth.sh

    ./08_static_dfg.py

Tracing an arbitrary GPU program:

    ./09_trace_wrapper.sh ./hbm_bandwidth 8589934592

Hardware-counter profiling:

    ./10_compute_profile_wrapper.sh ./hbm_bandwidth 8589934592

Render the complete workflow:

    dot -Tsvg mi300x_qwen3_end_to_end_dfg.dot \
        -o graphs/mi300x_qwen3_end_to_end_dfg.svg

    dot -Tpng mi300x_qwen3_end_to_end_dfg.dot \
        -o graphs/mi300x_qwen3_end_to_end_dfg.png

Notes:

Qwen3-32B is large enough to exercise the MI300X meaningfully while leaving
substantial HBM for KV cache, vLLM workspace and profiling.

Do not profile first. Establish a stable baseline first.

For HBM latency, use the dependent pointer-chase benchmark. Do not interpret
streaming bandwidth as latency.

For HBM bandwidth, use the separate streaming benchmark.

ROCm Compute Profiler can replay an application several times while collecting
counter groups. Therefore its kernel timing is not a replacement for the
unmodified rocprofv3 execution timeline.

Current machine has one MI300X:
- inter-GPU model traffic: N/A
- RCCL collective duration: N/A
- xGMI model-parallel traffic: N/A
- communication/computation overlap between GPUs: N/A

Those become relevant only when the workload spans >=2 accelerators.
EOF

###############################################################################
# Environment
###############################################################################
cat > "$ROOT/.env.example" <<'EOF'
export MODEL_ID="Qwen/Qwen3-32B"
export VLLM_IMAGE="vllm/vllm-openai-rocm:latest"
export CONTAINER_NAME="mi300x-qwen3-profile"
export PORT="8000"
export MAX_MODEL_LEN="32768"
export GPU_MEMORY_UTILIZATION="0.90"
export HF_CACHE="${HOME}/.cache/huggingface"
export RESULTS_DIR="$(pwd)/results"
export PROMPTS_DIR="$(pwd)/prompts"

# Serving benchmark
export NUM_PROMPTS="100"
export INPUT_LEN="1024"
export OUTPUT_LEN="128"
export MAX_CONCURRENCY="1"
export REQUEST_RATE="inf"

# Telemetry
export MONITOR_INTERVAL="1"
export MONITOR_DURATION="300"

# HBM benchmarks
export HBM_LATENCY_MAX_GIB="8"
export HBM_LATENCY_ITERS="1000000"
export HBM_BW_GIB="8"
export HBM_BW_REPEATS="10"
EOF

###############################################################################
# 00 - Machine discovery
###############################################################################
cat > "$ROOT/00_collect_system.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-results/system}"
mkdir -p "$OUT"

capture() {
    local name="$1"
    shift
    {
        echo "# timestamp=$(date --iso-8601=ns)"
        echo "# command=$*"
        "$@"
    } >"$OUT/$name" 2>&1 || true
}

capture date.txt date --iso-8601=ns
capture uname.txt uname -a

if [[ -r /etc/os-release ]]; then
    cp /etc/os-release "$OUT/os-release.txt"
fi

capture kernel_cmdline.txt cat /proc/cmdline
capture cpu.txt lscpu
capture numa.txt numactl --hardware
capture memory.txt free -h
capture lspci.txt lspci -nnk
capture lspci_verbose.txt lspci -vv

if command -v rocminfo >/dev/null 2>&1; then
    capture rocminfo.txt rocminfo
fi

if command -v hipconfig >/dev/null 2>&1; then
    capture hipconfig.txt hipconfig --full
fi

if command -v amd-smi >/dev/null 2>&1; then
    capture amd_smi_version.txt amd-smi version
    capture amd_smi_list.json amd-smi list --json
    capture amd_smi_static.json amd-smi static --json
    capture amd_smi_metric.json amd-smi metric --json
    capture amd_smi_topology.json amd-smi topology --json

    if amd-smi partition --help >/dev/null 2>&1; then
        capture amd_smi_partition_current.json \
            amd-smi partition --current --json
        capture amd_smi_partition_memory.json \
            amd-smi partition --memory --json
        capture amd_smi_partition_accelerator.json \
            amd-smi partition --accelerator --json
    fi

    if amd-smi xgmi --help >/dev/null 2>&1; then
        capture amd_smi_xgmi.json amd-smi xgmi --json
    fi

    if amd-smi firmware --help >/dev/null 2>&1; then
        capture amd_smi_firmware.json amd-smi firmware --json
    fi
fi

capture amdgpu_modinfo.txt modinfo amdgpu

if [[ -r /sys/module/amdgpu/version ]]; then
    cp /sys/module/amdgpu/version "$OUT/amdgpu_module_version.txt"
fi

if command -v rocprofv3 >/dev/null 2>&1; then
    capture rocprofv3_help.txt rocprofv3 --help
fi

if command -v rocprof-compute >/dev/null 2>&1; then
    capture rocprof_compute_help.txt rocprof-compute profile --help
    capture rocprof_compute_sets.txt rocprof-compute profile --list-sets
    capture rocprof_compute_metrics.txt \
        rocprof-compute profile --list-available-metrics
fi

{
    echo "timestamp=$(date --iso-8601=ns)"
    echo "hostname=$(hostname)"
    echo "kernel=$(uname -r)"
    echo "rocminfo=$(command -v rocminfo || true)"
    echo "amd_smi=$(command -v amd-smi || true)"
    echo "rocprofv3=$(command -v rocprofv3 || true)"
    echo "rocprof_compute=$(command -v rocprof-compute || true)"
    echo "hipcc=$(command -v hipcc || true)"
} > "$OUT/manifest.txt"

echo "System information written to $OUT"
EOF

###############################################################################
# 01 - ROCm vLLM container
###############################################################################
cat > "$ROOT/01_start_container.sh" <<'EOF'
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
    -v "$KIT_DIR:/workspace/kit" \
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
EOF

###############################################################################
# 02 - Serve Qwen3
###############################################################################
cat > "$ROOT/02_serve_qwen3_32b.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-32B}"
CONTAINER_NAME="${CONTAINER_NAME:-mi300x-qwen3-profile}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"

docker exec "$CONTAINER_NAME" bash -lc \
    "pkill -f 'vllm serve' >/dev/null 2>&1 || true"

docker exec -d "$CONTAINER_NAME" bash -lc "
    cd /workspace/kit
    exec vllm serve '$MODEL_ID' \
      --host 0.0.0.0 \
      --port '$PORT' \
      --dtype bfloat16 \
      --max-model-len '$MAX_MODEL_LEN' \
      --gpu-memory-utilization '$GPU_MEMORY_UTILIZATION' \
      > results/vllm_server.log 2>&1
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
docker exec "$CONTAINER_NAME" tail -100 /workspace/kit/results/vllm_server.log || true
exit 1
EOF

###############################################################################
# 03 - Serving benchmark
###############################################################################
cat > "$ROOT/03_bench_serving.sh" <<'EOF'
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
EOF

###############################################################################
# 04 - Prefill benchmark
###############################################################################
cat > "$ROOT/04_bench_prefill.sh" <<'EOF'
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
EOF

###############################################################################
# 05 - AMD SMI monitoring
###############################################################################
cat > "$ROOT/05_monitor_amd_smi.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

INTERVAL="${MONITOR_INTERVAL:-1}"
DURATION="${MONITOR_DURATION:-300}"
OUT="${1:-results/amd_smi_monitor_$(date +%Y%m%d_%H%M%S).csv}"

mkdir -p "$(dirname "$OUT")"

if ! command -v amd-smi >/dev/null 2>&1; then
    echo "ERROR: amd-smi not found."
    exit 1
fi

echo "Monitoring for ${DURATION}s -> $OUT"

# Current AMD SMI supports monitor/watch mode. If the installed version differs,
# inspect: amd-smi monitor --help
amd-smi monitor \
    --gpu 0 \
    --csv \
    --file "$OUT" \
    --watch "$INTERVAL" \
    --watch-time "$DURATION"

echo "Telemetry: $OUT"
EOF

###############################################################################
# HBM latency benchmark
###############################################################################
cat > "$ROOT/hbm_latency.hip" <<'EOF'
#include <hip/hip_runtime.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <numeric>
#include <random>
#include <vector>

#define HIP_CHECK(x) do {                                      \
    hipError_t e = (x);                                        \
    if (e != hipSuccess) {                                     \
        std::cerr << "HIP error: " << hipGetErrorString(e)     \
                  << " at " << __FILE__ << ":" << __LINE__     \
                  << std::endl;                                \
        std::exit(1);                                          \
    }                                                          \
} while (0)

__global__ void pointer_chase(
    const uint64_t* __restrict__ next,
    uint64_t iterations,
    uint64_t* result,
    unsigned long long* elapsed_ticks)
{
    if (blockIdx.x != 0 || threadIdx.x != 0) return;

    uint64_t p = 0;

    // Small warmup. Large working sets still miss the cache hierarchy.
    for (int i = 0; i < 4096; ++i)
        p = next[p];

    unsigned long long start = wall_clock64();

    for (uint64_t i = 0; i < iterations; ++i)
        p = next[p];

    unsigned long long stop = wall_clock64();

    result[0] = p;
    elapsed_ticks[0] = stop - start;
}

static uint64_t mib(uint64_t x) {
    return x * 1024ULL * 1024ULL;
}

int main(int argc, char** argv)
{
    uint64_t max_gib = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 8;
    uint64_t iterations =
        argc > 2 ? std::strtoull(argv[2], nullptr, 10) : 1000000ULL;

    int device = 0;
    HIP_CHECK(hipSetDevice(device));

    hipDeviceProp_t prop{};
    HIP_CHECK(hipGetDeviceProperties(&prop, device));

    int wall_khz = 0;
    HIP_CHECK(hipDeviceGetAttribute(
        &wall_khz, hipDeviceAttributeWallClockRate, device));

    std::cerr << "# device=" << prop.name << "\n";
    std::cerr << "# gcnArchName=" << prop.gcnArchName << "\n";
    std::cerr << "# wall_clock_khz=" << wall_khz << "\n";
    std::cerr << "# iterations=" << iterations << "\n";

    std::cout
        << "working_set_bytes,elements,iterations,"
        << "ticks_per_access,ns_per_access\n";

    std::mt19937_64 rng(0x300ULL);

    for (uint64_t bytes = mib(1);
         bytes <= max_gib * 1024ULL * 1024ULL * 1024ULL;
         bytes *= 2)
    {
        uint64_t n = bytes / sizeof(uint64_t);

        std::vector<uint64_t> permutation(n);
        std::iota(permutation.begin(), permutation.end(), 0ULL);
        std::shuffle(permutation.begin(), permutation.end(), rng);

        std::vector<uint64_t> next(n);
        for (uint64_t i = 0; i + 1 < n; ++i)
            next[permutation[i]] = permutation[i + 1];

        next[permutation[n - 1]] = permutation[0];

        uint64_t* d_next = nullptr;
        uint64_t* d_result = nullptr;
        unsigned long long* d_ticks = nullptr;

        HIP_CHECK(hipMalloc(&d_next, bytes));
        HIP_CHECK(hipMalloc(&d_result, sizeof(uint64_t)));
        HIP_CHECK(hipMalloc(&d_ticks, sizeof(unsigned long long)));

        HIP_CHECK(hipMemcpy(
            d_next, next.data(), bytes, hipMemcpyHostToDevice));

        hipLaunchKernelGGL(
            pointer_chase,
            dim3(1), dim3(1), 0, 0,
            d_next, iterations, d_result, d_ticks);

        HIP_CHECK(hipDeviceSynchronize());

        uint64_t result = 0;
        unsigned long long ticks = 0;

        HIP_CHECK(hipMemcpy(
            &result, d_result, sizeof(result), hipMemcpyDeviceToHost));
        HIP_CHECK(hipMemcpy(
            &ticks, d_ticks, sizeof(ticks), hipMemcpyDeviceToHost));

        const double ticks_per_access =
            static_cast<double>(ticks) / iterations;

        const double ns_per_tick =
            wall_khz > 0 ? 1.0e6 / static_cast<double>(wall_khz) : 0.0;

        const double ns_per_access = ticks_per_access * ns_per_tick;

        std::cout
            << bytes << ","
            << n << ","
            << iterations << ","
            << ticks_per_access << ","
            << ns_per_access << "\n";

        // Prevent the final dependent load from becoming dead code.
        if (result >= n)
            std::cerr << "invalid result\n";

        HIP_CHECK(hipFree(d_ticks));
        HIP_CHECK(hipFree(d_result));
        HIP_CHECK(hipFree(d_next));
    }

    return 0;
}
EOF

cat > "$ROOT/06_build_and_run_hbm_latency.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MAX_GIB="${HBM_LATENCY_MAX_GIB:-8}"
ITERS="${HBM_LATENCY_ITERS:-1000000}"
OUT="${1:-results/hbm_latency.csv}"

command -v hipcc >/dev/null 2>&1 || {
    echo "ERROR: hipcc not found."
    exit 1
}

hipcc -O3 -std=c++17 hbm_latency.hip -o hbm_latency

./hbm_latency "$MAX_GIB" "$ITERS" | tee "$OUT"

echo
echo "Interpretation:"
echo "  small working sets -> cache latency"
echo "  transitions        -> cache/TLB boundaries"
echo "  large working sets -> HBM-dominated dependent-load latency"
echo
echo "Do not compare this number directly with streaming GB/s."
EOF

###############################################################################
# HBM bandwidth
###############################################################################
cat > "$ROOT/hbm_bandwidth.hip" <<'EOF'
#include <hip/hip_runtime.h>

#include <cstdint>
#include <cstdlib>
#include <iostream>

#define HIP_CHECK(x) do {                                      \
    hipError_t e = (x);                                        \
    if (e != hipSuccess) {                                     \
        std::cerr << hipGetErrorString(e) << std::endl;        \
        std::exit(1);                                          \
    }                                                          \
} while (0)

__global__ void stream_copy(
    const float4* __restrict__ src,
    float4* __restrict__ dst,
    size_t n)
{
    size_t i =
        static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    size_t stride =
        static_cast<size_t>(gridDim.x) * blockDim.x;

    for (; i < n; i += stride)
        dst[i] = src[i];
}

int main(int argc, char** argv)
{
    uint64_t gib =
        argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 8;
    int repeats =
        argc > 2 ? std::atoi(argv[2]) : 10;

    size_t bytes = gib * 1024ULL * 1024ULL * 1024ULL;
    size_t n4 = bytes / sizeof(float4);
    bytes = n4 * sizeof(float4);

    float4* src = nullptr;
    float4* dst = nullptr;

    HIP_CHECK(hipMalloc(&src, bytes));
    HIP_CHECK(hipMalloc(&dst, bytes));
    HIP_CHECK(hipMemset(src, 1, bytes));
    HIP_CHECK(hipMemset(dst, 0, bytes));

    hipDeviceProp_t prop{};
    HIP_CHECK(hipGetDeviceProperties(&prop, 0));

    int blocks = prop.multiProcessorCount * 8;
    int threads = 256;

    hipEvent_t start, stop;
    HIP_CHECK(hipEventCreate(&start));
    HIP_CHECK(hipEventCreate(&stop));

    stream_copy<<<blocks, threads>>>(src, dst, n4);
    HIP_CHECK(hipDeviceSynchronize());

    HIP_CHECK(hipEventRecord(start));

    for (int r = 0; r < repeats; ++r)
        stream_copy<<<blocks, threads>>>(src, dst, n4);

    HIP_CHECK(hipEventRecord(stop));
    HIP_CHECK(hipEventSynchronize(stop));

    float ms = 0.0f;
    HIP_CHECK(hipEventElapsedTime(&ms, start, stop));

    // Each copy performs one HBM read and one HBM write.
    double transferred =
        2.0 * static_cast<double>(bytes) * repeats;

    double gbps =
        transferred / (static_cast<double>(ms) / 1000.0) / 1.0e9;

    std::cout << "device," << prop.name << "\n";
    std::cout << "bytes_per_buffer," << bytes << "\n";
    std::cout << "repeats," << repeats << "\n";
    std::cout << "elapsed_ms," << ms << "\n";
    std::cout << "read_plus_write_GBps," << gbps << "\n";

    HIP_CHECK(hipEventDestroy(stop));
    HIP_CHECK(hipEventDestroy(start));
    HIP_CHECK(hipFree(dst));
    HIP_CHECK(hipFree(src));

    return 0;
}
EOF

cat > "$ROOT/06b_build_and_run_hbm_bandwidth.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

GIB="${HBM_BW_GIB:-8}"
REPEATS="${HBM_BW_REPEATS:-10}"
OUT="${1:-results/hbm_bandwidth.csv}"

command -v hipcc >/dev/null 2>&1 || {
    echo "ERROR: hipcc not found."
    exit 1
}

hipcc -O3 -std=c++17 hbm_bandwidth.hip -o hbm_bandwidth

./hbm_bandwidth "$GIB" "$REPEATS" | tee "$OUT"
EOF

###############################################################################
# 07 - Exact-token prompt generator
###############################################################################
cat > "$ROOT/07_generate_prompts.py" <<'EOF'
#!/usr/bin/env python3

import json
import math
import os
from pathlib import Path

from transformers import AutoTokenizer

MODEL = os.environ.get("MODEL_ID", "Qwen/Qwen3-32B")
OUT = Path(os.environ.get("PROMPTS_DIR", "prompts"))
OUT.mkdir(parents=True, exist_ok=True)

tokenizer = AutoTokenizer.from_pretrained(MODEL)

SEED = (
    "Analyze the following synthetic systems-performance workload. "
    "Discuss memory hierarchy behavior, arithmetic intensity, cache locality, "
    "parallel execution, synchronization, scheduling, and bottlenecks. "
    "Use precise technical terminology and distinguish measured facts from "
    "engineering hypotheses. "
)

seed_ids = tokenizer.encode(SEED, add_special_tokens=False)
if not seed_ids:
    raise RuntimeError("seed tokenization produced zero tokens")


def exact_prompt(target):
    repeats = math.ceil((target + 32) / len(seed_ids))
    source = SEED * repeats

    ids = tokenizer.encode(source, add_special_tokens=False)

    while len(ids) < target:
        source += SEED
        ids = tokenizer.encode(source, add_special_tokens=False)

    ids = ids[:target]
    text = tokenizer.decode(
        ids,
        skip_special_tokens=False,
        clean_up_tokenization_spaces=False,
    )

    check = tokenizer.encode(text, add_special_tokens=False)

    if len(check) != target:
        raise RuntimeError(
            f"Tokenizer round-trip changed token count: "
            f"target={target}, actual={len(check)}"
        )

    return text


CASES = {
    "short": {
        "tokens": 128,
        "count": 16,
        "output_tokens": 1,
    },
    "medium": {
        "tokens": 2048,
        "count": 16,
        "output_tokens": 1,
    },
    "long": {
        "tokens": 16384,
        "count": 16,
        "output_tokens": 1,
    },
    "large_batch": {
        "tokens": 2048,
        "count": 64,
        "output_tokens": 1,
    },
    "decode": {
        "tokens": 256,
        "count": 32,
        "output_tokens": 512,
    },
}

manifest = {}

for name, cfg in CASES.items():
    prompt = exact_prompt(cfg["tokens"])
    actual = len(tokenizer.encode(prompt, add_special_tokens=False))

    path = OUT / f"{name}.jsonl"

    with path.open("w", encoding="utf-8") as f:
        for i in range(cfg["count"]):
            row = {
                "prompt": prompt,
                "output_tokens": cfg["output_tokens"],
                "case": name,
                "request_index": i,
            }
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    manifest[name] = {
        **cfg,
        "verified_input_tokens": actual,
        "file": str(path),
    }

with (OUT / "manifest.json").open("w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)

print(json.dumps(manifest, indent=2))
EOF

###############################################################################
# 08 - Static Qwen3 MLP DFG
###############################################################################
cat > "$ROOT/08_static_dfg.py" <<'EOF'
#!/usr/bin/env python3

import json
import os
from pathlib import Path

import torch
from torch.fx import symbolic_trace
from torch.fx.passes.shape_prop import ShapeProp
from transformers import AutoConfig, AutoModelForCausalLM

MODEL_ID = os.environ.get("MODEL_ID", "Qwen/Qwen3-32B")
SEQ = int(os.environ.get("DFG_SEQ_LEN", "128"))
BATCH = int(os.environ.get("DFG_BATCH", "1"))

OUT = Path("graphs")
OUT.mkdir(exist_ok=True)

cfg = AutoConfig.from_pretrained(MODEL_ID)

# Instantiate parameters on meta device: no 65-GB weight allocation.
with torch.device("meta"):
    model = AutoModelForCausalLM.from_config(cfg)

# MLP is intentionally selected because it is a useful, static,
# easily traceable Qwen3 transformer subgraph.
mlp = model.model.layers[0].mlp
gm = symbolic_trace(mlp)

x = torch.empty(
    (BATCH, SEQ, cfg.hidden_size),
    device="meta",
    dtype=torch.bfloat16,
)

ShapeProp(gm).propagate(x)

nodes = []

for n in gm.graph.nodes:
    tm = n.meta.get("tensor_meta")
    shape = list(tm.shape) if tm is not None else None
    dtype = str(tm.dtype) if tm is not None else None

    nodes.append({
        "name": n.name,
        "op": n.op,
        "target": str(n.target),
        "shape": shape,
        "dtype": dtype,
        "users": [u.name for u in n.users],
    })

json_path = OUT / "qwen3_layer0_mlp_dfg.json"
json_path.write_text(json.dumps(nodes, indent=2))

def esc(s):
    return str(s).replace("\\", "\\\\").replace('"', '\\"')

dot = [
    "digraph Qwen3MLP {",
    '  rankdir="LR";',
    '  graph [fontname="Helvetica"];',
    '  node [shape=box, fontname="Helvetica"];',
]

for n in gm.graph.nodes:
    tm = n.meta.get("tensor_meta")
    extra = ""
    if tm is not None:
        extra = f"\\nshape={list(tm.shape)}\\ndtype={tm.dtype}"

    label = esc(f"{n.name}\\n{n.op}\\n{n.target}{extra}")
    dot.append(f'  "{n.name}" [label="{label}"];')

for n in gm.graph.nodes:
    for u in n.users:
        dot.append(f'  "{n.name}" -> "{u.name}";')

dot.append("}")

dot_path = OUT / "qwen3_layer0_mlp_dfg.dot"
dot_path.write_text("\n".join(dot) + "\n")

print(json_path)
print(dot_path)
EOF

###############################################################################
# 09 - Timeline tracing
###############################################################################
cat > "$ROOT/09_trace_wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
    echo "Usage: $0 COMMAND [ARGS...]"
    exit 2
fi

OUT="${TRACE_OUT:-results/rocprof_trace_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"

if command -v rocprofv3 >/dev/null 2>&1; then
    echo "Using rocprofv3."
    rocprofv3 \
        --sys-trace \
        --output-directory "$OUT" \
        -- "$@"

    echo "Trace directory: $OUT"

    if command -v rocpd >/dev/null 2>&1; then
        DB="$(find "$OUT" -type f -name '*_results.db' | head -1 || true)"
        if [[ -n "$DB" ]]; then
            echo "ROCPD database: $DB"
            echo "To convert it:"
            echo "  rocpd convert -i \"$DB\" --output-format pftrace"
            echo "  rocpd convert -i \"$DB\" --output-format csv"
        fi
    fi
else
    echo "ERROR: rocprofv3 not found."
    echo "Check the ROCm installation and profiler packages."
    exit 1
fi
EOF

###############################################################################
# 10 - Compute profiler
###############################################################################
cat > "$ROOT/10_compute_profile_wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
    echo "Usage: $0 COMMAND [ARGS...]"
    exit 2
fi

if ! command -v rocprof-compute >/dev/null 2>&1; then
    echo "ERROR: rocprof-compute not found."
    exit 1
fi

NAME="${PROFILE_NAME:-mi300x_$(date +%Y%m%d_%H%M%S)}"

echo "Installed metric sets:"
rocprof-compute profile --list-sets || true

echo
echo "Profiling as workload: $NAME"
echo "NOTE: counter profiling may replay/serialize the workload."

rocprof-compute profile \
    --name "$NAME" \
    --no-roof \
    -- "$@"

echo
echo "Analyze the generated workload directory with:"
echo "  rocprof-compute analyze -p workloads/${NAME}/MI300X/"
EOF

###############################################################################
# Requirements
###############################################################################
cat > "$ROOT/requirements.txt" <<'EOF'
transformers>=4.51
torch
graphviz
EOF

###############################################################################
# COMPLETE end-to-end Graphviz DFG
###############################################################################
cat > "$ROOT/mi300x_qwen3_end_to_end_dfg.dot" <<'EOF'
digraph MI300X_Qwen3_EndToEnd {
  rankdir=LR;
  compound=true;
  newrank=true;

  graph [
    label="MI300X / Qwen3-32B End-to-End Profiling and Optimization DFG",
    labelloc=t,
    fontsize=22,
    fontname="Helvetica",
    bgcolor="white"
  ];

  node [fontname="Helvetica", fontsize=10];
  edge [fontname="Helvetica", fontsize=9, color="#555555"];

  // Styles:
  // input    = ellipse / blue
  // process  = box / gray
  // artifact = folder / green
  // decision = diamond / orange
  // future   = dashed / purple

  subgraph cluster_discovery {
    label="A. Inputs & Discovery";
    color="#7aa6c2";

    gpu [
      label="INPUT\nPhysical MI300X",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    host [
      label="INPUT\nHost OS + kernel",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    rocm [
      label="INPUT\nROCm + amdgpu\nfirmware + AMD SMI",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    permissions [
      label="INPUT\nUser/root permissions",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    discover [
      label="PROCESS\n00_collect_system.sh\nMachine discovery",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    machine_manifest [
      label="ARTIFACT\nmachine/environment manifest\nrocminfo + AMD SMI logs",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    topology [
      label="ARTIFACT\nPCIe + NUMA + topology\npartition + clocks + thermals",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    gpu -> discover;
    host -> discover;
    rocm -> discover;
    permissions -> discover;

    discover -> machine_manifest [
      label="SKU, gfx target,\nversions, HBM"
    ];

    discover -> topology [
      label="PCIe/NUMA,\nSPX/CPX, NPS state"
    ];
  }

  subgraph cluster_config {
    label="B. Partition Configuration";
    color="#e5a84b";

    desired_partition [
      label="INPUT\nDesired mode\nSPX/NPS1 or CPX/NPS4",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    support_check [
      label="DECISION\nSupported by installed\nfirmware + AMD SMI?",
      shape=diamond,
      style=filled,
      fillcolor="#ffe2ad"
    ];

    stop_gpu [
      label="PROCESS\nStop GPU workloads",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    set_spx [
      label="PROCESS\nValidated AMD procedure\nSPX + NPS1",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    set_cpx [
      label="PROCESS\nValidated AMD procedure\nCPX + NPS4",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    rediscover [
      label="PROCESS\nRequired driver reload/reset\nif applicable + rediscovery",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    partition_after [
      label="ARTIFACT\nVerified post-change\npartition/device manifest",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    rollback [
      label="PROCESS\nRollback to previous\nvalidated partition state",
      shape=box,
      style="rounded,filled,dashed",
      fillcolor="#fff3d6"
    ];

    topology -> support_check;
    desired_partition -> support_check;

    support_check -> stop_gpu [label="yes"];
    support_check -> partition_after [label="no change"];

    stop_gpu -> set_spx [label="SPX/NPS1"];
    stop_gpu -> set_cpx [label="CPX/NPS4"];

    set_spx -> rediscover;
    set_cpx -> rediscover;
    rediscover -> partition_after;

    partition_after -> rollback [
      style=dashed,
      label="rollback if needed"
    ];
    rollback -> rediscover [style=dashed];
  }

  subgraph cluster_model {
    label="C-D. Model & Workload";
    color="#6fa36f";

    software [
      label="INPUT\nROCm-compatible vLLM\nPyTorch + container",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    weights [
      label="INPUT\nQwen/Qwen3-32B\nweights + tokenizer",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    env_setup [
      label="PROCESS\n01_start_container.sh\nVerify ROCm/PyTorch GPU",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    model_load [
      label="PROCESS\n02_serve_qwen3_32b.sh\nLoad BF16 model",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    server [
      label="ARTIFACT\nRunning Qwen3\nOpenAI-compatible server",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    workload_inputs [
      label="INPUT\nTokenizer + seed text\nlengths + batch + decode\nrandom seed",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    prompt_gen [
      label="PROCESS\n07_generate_prompts.py\nExact-token workloads",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    prompts [
      label="ARTIFACT\nshort / medium / long\nlarge-batch / decode JSONL",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    partition_after -> env_setup;
    machine_manifest -> env_setup;
    software -> env_setup;
    weights -> model_load;
    env_setup -> model_load;
    model_load -> server;

    weights -> prompt_gen [label="tokenizer"];
    workload_inputs -> prompt_gen;
    prompt_gen -> prompts [label="verified token counts"];
  }

  subgraph cluster_baseline {
    label="E-F. Baseline Execution & Service Metrics";
    color="#6b89c7";

    warmup [
      label="PROCESS\nWarmup",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    prefill [
      label="PROCESS\nPrefill",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    first_token [
      label="PROCESS\nFirst token",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    decode [
      label="PROCESS\nIterative decode",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    request_logs [
      label="ARTIFACT\nPer-request/per-token\nbenchmark records",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    service_metrics [
      label="ARTIFACT\nTTFT p50/p90/p95/p99\nTPOT p50/p90/p95/p99\nITL + tokens/s + requests/s",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    server -> warmup;
    prompts -> warmup;
    warmup -> prefill;
    prefill -> first_token;
    first_token -> decode;
    decode -> request_logs;
    request_logs -> service_metrics;
  }

  subgraph cluster_measure {
    label="G-K. Measurement & Profiling";
    color="#b17cb8";

    telemetry_proc [
      label="PROCESS\nAMD SMI monitoring\nutilization, clocks, power,\ntemperature, memory",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    telemetry [
      label="ARTIFACT\nTimestamped telemetry\n+ peak memory",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    timeline_proc [
      label="PROCESS\nrocprofv3 system trace\nHIP/HSA/kernel/memory/sync",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    timeline [
      label="ARTIFACT\nGPU timeline\nlaunch gaps + copies\nhost/device synchronization",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    counter_query [
      label="PROCESS\nQuery installed\nrocprof-compute metrics/sets",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    counters_proc [
      label="PROCESS\nCounter profiling\nselected hot kernels",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    counters [
      label="ARTIFACT\nVALU/MFMA/HBM/cache\nLDS/VGPR/SGPR/occupancy\nstall evidence",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    latency_inputs [
      label="INPUT\nWorking-set sizes\nrandom dependent chain\niterations + clock state",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    latency_proc [
      label="PROCESS\nDependent pointer chase\nHBM/cache latency sweep",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    latency [
      label="ARTIFACT\ncycles/ticks per access\nns/access vs working set",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    bandwidth_inputs [
      label="INPUT\nLarge buffers\nstreaming configuration",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    bandwidth_proc [
      label="PROCESS\nParallel HBM\nstreaming benchmark",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    bandwidth [
      label="ARTIFACT\nAchieved HBM GB/s\nread+write traffic",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    server -> telemetry_proc [label="benchmark interval"];
    telemetry_proc -> telemetry;

    server -> timeline_proc [label="profiled execution"];
    timeline_proc -> timeline;

    machine_manifest -> counter_query;
    counter_query -> counters_proc [
      label="version-correct\nmetric selection"
    ];
    server -> counters_proc;
    counters_proc -> counters;

    gpu -> latency_proc;
    latency_inputs -> latency_proc;
    latency_proc -> latency;

    gpu -> bandwidth_proc;
    bandwidth_inputs -> bandwidth_proc;
    bandwidth_proc -> bandwidth;
  }

  subgraph cluster_graphs {
    label="L-N. Static/Dynamic Graph Analysis";
    color="#4ca6a8";

    graph_inputs [
      label="INPUT\nModel/submodule\nshapes + dtype + workload",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    static_graph_proc [
      label="PROCESS\ntorch.fx / torch.export\nshape metadata + graph breaks\nliveness analysis",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    static_graph [
      label="ARTIFACT\nmodel_dfg.json\nmodel_dfg.dot",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    correlate [
      label="PROCESS\nStatic op -> dynamic kernel\ncorrelation",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    annotated [
      label="ARTIFACT\nannotated_dfg.json/dot\nduration + bytes + counters",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    movement [
      label="PROCESS\nConstruct data-movement graph\nHBM/cache/LDS/register/KV",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    movement_graph [
      label="ARTIFACT\ndata_movement_graph.json/dot\nmeasured vs estimated bytes",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    weights -> graph_inputs;
    prompts -> graph_inputs;
    graph_inputs -> static_graph_proc;
    static_graph_proc -> static_graph;

    static_graph -> correlate;
    timeline -> correlate;
    counters -> correlate;
    correlate -> annotated;

    annotated -> movement;
    bandwidth -> movement;
    latency -> movement;
    topology -> movement;
    movement -> movement_graph;
  }

  subgraph cluster_analysis {
    label="O. Bottleneck Analysis";
    color="#d06a6a";

    bottleneck [
      label="PROCESS\nEvidence-based bottleneck analysis",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    classify [
      label="DECISION\nDominant bottleneck?",
      shape=diamond,
      style=filled,
      fillcolor="#ffe2ad"
    ];

    report [
      label="ARTIFACT\nRanked bottleneck report\nwith measured evidence",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    service_metrics -> bottleneck;
    telemetry -> bottleneck;
    timeline -> bottleneck;
    counters -> bottleneck;
    latency -> bottleneck;
    bandwidth -> bottleneck;
    annotated -> bottleneck;
    movement_graph -> bottleneck;

    bottleneck -> classify;
    classify -> report;
  }

  subgraph cluster_optimization {
    label="P-Q. Optimization";
    color="#df9b42";

    opt_decision [
      label="DECISION\nSelect optimization",
      shape=diamond,
      style=filled,
      fillcolor="#ffe2ad"
    ];

    fusion [
      label="PROCESS\nFusion / mega-kernel",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    tiling [
      label="PROCESS\nTiling / layout",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    prefetch_opt [
      label="PROCESS\nPrefetch + double buffering\nsoftware pipeline",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    persistent [
      label="PROCESS\nPersistent kernel",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    kv [
      label="PROCESS\nKV-cache optimization",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    runtime_opt [
      label="PROCESS\nCompiler/runtime/batching\nscheduling optimization",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    hypothesis [
      label="ARTIFACT\nOptimization hypothesis\nexpected metric delta\ncorrectness constraints",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    implement [
      label="PROCESS\nImplement + rebuild",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    optimized [
      label="ARTIFACT\nOptimized variant",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    report -> opt_decision;

    opt_decision -> fusion [label="HBM/intermediate traffic"];
    opt_decision -> tiling [label="locality"];
    opt_decision -> prefetch_opt [label="latency"];
    opt_decision -> persistent [label="launch/state"];
    opt_decision -> kv [label="KV traffic"];
    opt_decision -> runtime_opt [label="runtime/scheduling"];

    fusion -> hypothesis;
    tiling -> hypothesis;
    prefetch_opt -> hypothesis;
    persistent -> hypothesis;
    kv -> hypothesis;
    runtime_opt -> hypothesis;

    hypothesis -> implement;
    implement -> optimized;
  }

  subgraph cluster_validation {
    label="R-T. Validation & Iteration";
    color="#679267";

    validation [
      label="PROCESS\nCorrectness + numerical\nregression + memory checks",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    validation_result [
      label="DECISION\nCorrect?",
      shape=diamond,
      style=filled,
      fillcolor="#ffe2ad"
    ];

    reprofiling [
      label="PROCESS\nRe-run SAME workload\nmetrics + telemetry + traces\n+ selected counters",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    delta [
      label="ARTIFACT\nA/B deltas\nTTFT / TPOT / throughput\nmemory / HBM / kernels",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    success [
      label="DECISION\nImprovement without\nunacceptable regression?",
      shape=diamond,
      style=filled,
      fillcolor="#ffe2ad"
    ];

    final_package [
      label="ARTIFACT\nFinal reproducible package\ncode + manifests + workloads\nmetrics + traces + graphs",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    optimized -> validation;
    prompts -> validation [label="same fixed workload"];
    validation -> validation_result;

    validation_result -> opt_decision [
      label="no",
      color="#c43c3c"
    ];

    validation_result -> reprofiling [label="yes"];

    machine_manifest -> reprofiling [
      label="same environment"
    ];

    reprofiling -> delta;
    delta -> success;

    success -> bottleneck [
      label="no: iterate",
      color="#c43c3c"
    ];

    success -> final_package [
      label="yes"
    ];
  }

  subgraph cluster_multigpu {
    label="U. Optional Future Multi-GPU";
    color="#8b6bb3";
    style=dashed;

    single_gpu_na [
      label="CURRENT SINGLE MI300X\nInter-GPU traffic = N/A\nRCCL collectives = N/A\nxGMI model traffic = N/A\ncomm/compute overlap = N/A",
      shape=note,
      style="filled,dashed",
      fillcolor="#eee4fa"
    ];

    multi_input [
      label="FUTURE INPUT\n>=2 GPUs + topology\nRCCL workload",
      shape=ellipse,
      style="filled,dashed",
      fillcolor="#eee4fa"
    ];

    multi_measure [
      label="FUTURE PROCESS\nCollective timeline\nxGMI/PCIe traffic\ncomm/compute overlap",
      shape=box,
      style="rounded,filled,dashed",
      fillcolor="#eee4fa"
    ];

    multi_metrics [
      label="FUTURE ARTIFACT\nCollective duration\nlink traffic + overlap",
      shape=folder,
      style="filled,dashed",
      fillcolor="#eee4fa"
    ];

    gpu -> single_gpu_na [style=dashed];
    multi_input -> multi_measure [style=dashed];
    multi_measure -> multi_metrics [style=dashed];
    multi_metrics -> bottleneck [style=dashed];
  }

  subgraph cluster_legend {
    label="Legend";
    color="#cccccc";

    legend_input [
      label="INPUT",
      shape=ellipse,
      style=filled,
      fillcolor="#d9efff"
    ];

    legend_process [
      label="PROCESS",
      shape=box,
      style="rounded,filled",
      fillcolor="#eeeeee"
    ];

    legend_artifact [
      label="OUTPUT / ARTIFACT",
      shape=folder,
      style=filled,
      fillcolor="#dff5df"
    ];

    legend_decision [
      label="DECISION",
      shape=diamond,
      style=filled,
      fillcolor="#ffe2ad"
    ];

    legend_future [
      label="OPTIONAL / FUTURE",
      shape=box,
      style="rounded,filled,dashed",
      fillcolor="#eee4fa"
    ];
  }
}
EOF

###############################################################################
# Validation
###############################################################################
cat > "$ROOT/validate_kit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "Checking shell syntax..."
for f in ./*.sh; do
    bash -n "$f"
done

echo "Checking Python syntax..."
python3 -m py_compile \
    07_generate_prompts.py \
    08_static_dfg.py

echo "Checking required files..."
required=(
    README.md
    .env.example
    00_collect_system.sh
    01_start_container.sh
    02_serve_qwen3_32b.sh
    03_bench_serving.sh
    04_bench_prefill.sh
    05_monitor_amd_smi.sh
    06_build_and_run_hbm_latency.sh
    hbm_latency.hip
    06b_build_and_run_hbm_bandwidth.sh
    hbm_bandwidth.hip
    07_generate_prompts.py
    08_static_dfg.py
    09_trace_wrapper.sh
    10_compute_profile_wrapper.sh
    mi300x_qwen3_end_to_end_dfg.dot
)

for f in "${required[@]}"; do
    [[ -s "$f" ]] || {
        echo "ERROR: missing/empty $f"
        exit 1
    }
done

if command -v dot >/dev/null 2>&1; then
    mkdir -p graphs
    dot -Tsvg mi300x_qwen3_end_to_end_dfg.dot \
        -o graphs/mi300x_qwen3_end_to_end_dfg.svg

    dot -Tpng mi300x_qwen3_end_to_end_dfg.dot \
        -o graphs/mi300x_qwen3_end_to_end_dfg.png

    echo "Graphviz validation passed."
else
    echo "dot not installed; skipping Graphviz rendering."
fi

echo
echo "Validation passed."
EOF

###############################################################################
# Permissions + validation
###############################################################################
chmod +x \
    "$ROOT/"*.sh \
    "$ROOT/"*.py

(
    cd "$ROOT"
    ./validate_kit.sh
)

###############################################################################
# ZIP
###############################################################################
if command -v zip >/dev/null 2>&1; then
    zip -qr "$ZIP" "$ROOT"
else
    python3 - "$ROOT" "$ZIP" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for p in root.rglob("*"):
        if p.is_file():
            z.write(p, p.as_posix())
PY
fi

###############################################################################
# Final manifest
###############################################################################
echo
echo "============================================================"
echo "CREATED: $ZIP"
echo "============================================================"
echo
echo "Archive manifest:"
if command -v unzip >/dev/null 2>&1; then
    unzip -l "$ZIP"
else
    python3 - "$ZIP" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for i in z.infolist():
        print(f"{i.file_size:10d}  {i.filename}")
PY
fi

echo
echo "DFG source:"
echo "  $ROOT/mi300x_qwen3_end_to_end_dfg.dot"
echo
echo "DFG rendered SVG:"
echo "  $ROOT/graphs/mi300x_qwen3_end_to_end_dfg.svg"
echo
echo "ZIP:"
echo "  $(pwd)/$ZIP"

