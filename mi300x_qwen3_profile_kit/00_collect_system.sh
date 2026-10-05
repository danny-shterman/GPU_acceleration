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
