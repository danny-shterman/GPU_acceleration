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
