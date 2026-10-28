rm -rf results/cijk_analysis_csv
mkdir -p \
  results/cijk_analysis_csv/util \
  results/cijk_analysis_csv/mem \
  results/cijk_analysis_csv/flops

UTIL=$(realpath workloads/qwen3_32b_cijk_compute_util/MI300X_A1)
MEM=$(realpath workloads/qwen3_32b_cijk_mem_thruput/MI300X_A1)
FLOPS=$(realpath workloads/qwen3_32b_cijk_compute_flops/MI300X_A1)

(
  cd results/cijk_analysis_csv/util
  rocprof-compute analyze \
    -p "$UTIL" \
    --output-format csv
)

(
  cd results/cijk_analysis_csv/mem
  rocprof-compute analyze \
    -p "$MEM" \
    --output-format csv
)

(
  cd results/cijk_analysis_csv/flops
  rocprof-compute analyze \
    -p "$FLOPS" \
    --output-format csv
)
