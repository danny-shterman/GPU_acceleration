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
