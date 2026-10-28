#!/usr/bin/env python3

import re
from pathlib import Path
import pandas as pd

FIRST_DISPATCH = 140369
LAST_DISPATCH  = 141148

base = Path("workloads/qwen3_32b_launchstats/MI300X_A1")
perf_file = base / "pmc_perf.csv"
dispatch_file = base / "pmc_dispatch_info.csv"

out = Path("results/qwen3_32b_cijk_inference_rank.csv")
out.parent.mkdir(parents=True, exist_ok=True)

# ------------------------------------------------------------
# Load files
# ------------------------------------------------------------
if not perf_file.exists():
    raise SystemExit(f"ERROR: not found: {perf_file}")

perf = pd.read_csv(perf_file)

print("pmc_perf.csv columns:")
print(perf.columns.tolist())
print()

required_perf = {
    "Dispatch_ID",
    "Kernel_Name",
    "Start_Timestamp",
    "End_Timestamp",
}

missing = required_perf - set(perf.columns)

if missing:
    raise SystemExit(
        "ERROR: pmc_perf.csv is missing required columns: "
        + ", ".join(sorted(missing))
    )

# ------------------------------------------------------------
# Convert numeric fields
# ------------------------------------------------------------
for c in ["Dispatch_ID", "Start_Timestamp", "End_Timestamp"]:
    perf[c] = pd.to_numeric(perf[c], errors="coerce")

perf = perf.dropna(
    subset=["Dispatch_ID", "Start_Timestamp", "End_Timestamp"]
).copy()

perf["Dispatch_ID"] = perf["Dispatch_ID"].astype(int)

# pmc_perf.csv can have multiple rows for the same dispatch,
# e.g. one row per performance counter.
#
# Timing must therefore be counted ONCE per dispatch.
dispatches = (
    perf[
        [
            "Dispatch_ID",
            "Kernel_Name",
            "Start_Timestamp",
            "End_Timestamp",
        ]
    ]
    .drop_duplicates()
    .copy()
)

print("Unique dispatches in pmc_perf.csv:", len(dispatches))
print(
    "Dispatch range:",
    dispatches["Dispatch_ID"].min(),
    "..",
    dispatches["Dispatch_ID"].max(),
)
print()

# ------------------------------------------------------------
# Restrict to the inference interval identified previously
# ------------------------------------------------------------
window = dispatches[
    dispatches["Dispatch_ID"].between(
        FIRST_DISPATCH,
        LAST_DISPATCH,
    )
].copy()

print(
    "Dispatches in target interval:",
    len(window),
)

if len(window) == 0:
    raise SystemExit(
        f"ERROR: no dispatches found in "
        f"{FIRST_DISPATCH}..{LAST_DISPATCH}"
    )

window["Duration_ns"] = (
    window["End_Timestamp"]
    - window["Start_Timestamp"]
)

# ------------------------------------------------------------
# Select Cijk GEMMs
# ------------------------------------------------------------
cijk = window[
    window["Kernel_Name"]
    .astype(str)
    .str.contains("Cijk_", regex=False)
].copy()

print("Cijk dispatches in interval:", len(cijk))
print()

if len(cijk) == 0:
    raise SystemExit("ERROR: no Cijk kernels found")

# ------------------------------------------------------------
# Extract CK tuning parameters from kernel name
# ------------------------------------------------------------
def extract(pattern, s):
    m = re.search(pattern, str(s))
    return m.group(1) if m else ""

cijk["MT"] = cijk["Kernel_Name"].map(
    lambda s: extract(r"(MT\d+x\d+x\d+)", s)
)

cijk["MI"] = cijk["Kernel_Name"].map(
    lambda s: extract(r"(MI\d+x\d+x\d+)", s)
)

# ------------------------------------------------------------
# Rank EXACT kernel variants
# ------------------------------------------------------------
rank = (
    cijk.groupby(
        ["Kernel_Name", "MT", "MI"],
        dropna=False
    )
    .agg(
        Calls=("Dispatch_ID", "size"),
        Total_ns=("Duration_ns", "sum"),
        Mean_ns=("Duration_ns", "mean"),
        Median_ns=("Duration_ns", "median"),
        Min_ns=("Duration_ns", "min"),
        Max_ns=("Duration_ns", "max"),
        First_Dispatch=("Dispatch_ID", "min"),
        Last_Dispatch=("Dispatch_ID", "max"),
    )
    .reset_index()
)

rank["Total_ms"] = rank["Total_ns"] / 1e6
rank["Mean_us"] = rank["Mean_ns"] / 1e3
rank["Median_us"] = rank["Median_ns"] / 1e3

total_cijk_ns = rank["Total_ns"].sum()
total_window_ns = window["Duration_ns"].sum()

rank["Cijk_Time_Pct"] = (
    100.0 * rank["Total_ns"] / total_cijk_ns
)

rank["Window_Dispatch_Time_Pct"] = (
    100.0 * rank["Total_ns"] / total_window_ns
)

rank = (
    rank
    .sort_values("Total_ns", ascending=False)
    .reset_index(drop=True)
)

rank.insert(0, "Rank", rank.index + 1)

rank["Cumulative_Cijk_Pct"] = (
    rank["Cijk_Time_Pct"].cumsum()
)

rank.to_csv(out, index=False)

# ------------------------------------------------------------
# Display useful summary
# ------------------------------------------------------------
print("=" * 100)
print("Cijk inference ranking")
print("=" * 100)

print(
    f"Inference dispatch interval : "
    f"{FIRST_DISPATCH} .. {LAST_DISPATCH}"
)

print(f"Total interval dispatches   : {len(window)}")
print(f"Cijk dispatches             : {len(cijk)}")
print(f"Unique exact Cijk kernels   : {len(rank)}")
print(f"Total Cijk time             : {total_cijk_ns / 1e6:.3f} ms")
print()

cols = [
    "Rank",
    "MT",
    "MI",
    "Calls",
    "Total_ms",
    "Mean_us",
    "Median_us",
    "Cijk_Time_Pct",
    "Cumulative_Cijk_Pct",
    "First_Dispatch",
    "Last_Dispatch",
]

pd.set_option("display.width", 240)
pd.set_option("display.max_columns", None)
pd.set_option("display.max_colwidth", 80)

print(rank[cols].head(20).to_string(
    index=False,
    formatters={
        "Total_ms": "{:.3f}".format,
        "Mean_us": "{:.3f}".format,
        "Median_us": "{:.3f}".format,
        "Cijk_Time_Pct": "{:.2f}".format,
        "Cumulative_Cijk_Pct": "{:.2f}".format,
    },
))

print()
print("Full result:")
print(out)
