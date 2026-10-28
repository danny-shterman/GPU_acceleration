#!/usr/bin/env python3

from pathlib import Path
import csv

files = {
    "launchstats":
        "workloads/qwen3_32b_launchstats/MI300X_A1/pmc_kernel_top.csv",
    "compute_util":
        "workloads/qwen3_32b_cijk_compute_util/MI300X_A1/pmc_kernel_top.csv",
    "memory":
        "workloads/qwen3_32b_cijk_mem_thruput/MI300X_A1/pmc_kernel_top.csv",
    "flops":
        "workloads/qwen3_32b_cijk_compute_flops/MI300X_A1/pmc_kernel_top.csv",
}

for name, filename in files.items():
    path = Path(filename)

    print(f"\n{'=' * 80}")
    print(f"PROFILE: {name}")
    print(f"FILE: {path}")
    print(f"{'=' * 80}")

    if not path.is_file():
        print("FILE NOT FOUND")
        continue

    with path.open(newline="", errors="replace") as f:
        reader = csv.DictReader(f)

        print("Columns:", reader.fieldnames)

        for i, row in enumerate(reader):
            if i >= 20:
                break
            print(f"{i + 1:2d}: {row}")
