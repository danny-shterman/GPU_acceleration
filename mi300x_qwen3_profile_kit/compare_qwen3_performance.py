
#!/usr/bin/env python3
"""
Compare Qwen3-32B serving/prefill performance.

Usage:
    python3 compare_qwen3_performance.py BASELINE_DIR CHANGED_DIR

Example:
    python3 compare_qwen3_performance.py \
        results/baseline_v0 \
        results/optimized_qk_norm

Only Python standard library is required.
"""

import argparse
import csv
import re
import statistics
from collections import defaultdict
from pathlib import Path


NUMBER = r"[-+]?(?:\d+(?:,\d{3})*(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"

METRIC_LINE = re.compile(
    rf"^\s*(?P<label>[A-Za-z][^:\n]{{2,110}}?)"
    rf"\s*:\s*(?P<value>{NUMBER})"
    rf"\s*(?P<unit>ms|us|µs|s|tok/s|tokens/s|req/s|requests/s|%)?"
    rf"\s*$",
    re.IGNORECASE,
)

METRIC_WORDS = (
    "ttft", "tpot", "itl", "e2el", "latency",
    "throughput", "tokens per second",
    "tokens/sec", "tokens/s", "tok/s",
    "requests per second", "req/s",
    "prefill time", "prefill latency",
    "decode time", "time to first",
    "time per output", "generation speed",
    "generation time", "total time",
)

LOWER_IS_BETTER = (
    "ttft", "tpot", "itl", "e2el", "latency",
    "duration", "time",
)

HIGHER_IS_BETTER = (
    "throughput", "tok/s", "tokens/s",
    "tokens per second", "tokens/sec",
    "req/s", "requests per second",
    "generation speed",
)


def normalize_label(label):
    label = re.sub(r"\s+", " ", label.strip())
    return label.lower()


def direction_for(label):
    s = normalize_label(label)

    if any(x in s for x in HIGHER_IS_BETTER):
        return "higher"

    if any(x in s for x in LOWER_IS_BETTER):
        return "lower"

    return None


def parse_metrics(path):
    """Return metric label -> list of measurements."""
    data = defaultdict(list)

    with path.open("r", errors="replace") as f:
        for line in f:
            match = METRIC_LINE.match(line)

            if not match:
                continue

            label = normalize_label(match.group("label"))

            if not any(word in label for word in METRIC_WORDS):
                continue

            if direction_for(label) is None:
                continue

            raw = match.group("value").replace(",", "")
            value = float(raw)

            unit = (match.group("unit") or "").lower()

            # Normalize explicit trailing units.
            if unit == "s" and direction_for(label) == "lower":
                value *= 1000
                label += " [milliseconds]"
            elif unit in ("us", "µs"):
                value /= 1000
                label += " [milliseconds]"
            elif unit == "ms":
                label += " [milliseconds]"
            elif unit:
                label += f" [{unit}]"

            data[label].append(value)

    return dict(data)


def serving_files(directory):
    repeated = sorted(
        directory.glob("serving_run_*.log")
    )

    if repeated:
        return repeated

    single = directory / "serving.log"
    return [single] if single.exists() else []


def collect_serving(directory):
    files = serving_files(directory)

    values = defaultdict(list)

    for path in files:
        parsed = parse_metrics(path)

        for label, measurements in parsed.items():
            # Preserve the separate run observations.
            # Usually one occurrence of each metric per run.
            values[label].extend(measurements)

    return dict(values), files


def collect_prefill(directory):
    path = directory / "prefill.log"

    if not path.exists():
        return {}, []

    return parse_metrics(path), [path]


def compare_values(baseline, changed, direction):
    base = statistics.median(baseline)
    new = statistics.median(changed)

    if base <= 0 or new <= 0:
        return base, new, None, None

    if direction == "lower":
        # Positive improvement means latency decreased.
        improvement = (base - new) / base * 100
        speedup = base / new
    else:
        # Positive improvement means throughput increased.
        improvement = (new - base) / base * 100
        speedup = new / base

    return base, new, improvement, speedup


def make_rows(category, baseline_data, changed_data):
    rows = []

    labels = sorted(
        set(baseline_data) | set(changed_data)
    )

    for label in labels:
        base_samples = baseline_data.get(label, [])
        new_samples = changed_data.get(label, [])

        direction = direction_for(label)

        if not base_samples or not new_samples:
            rows.append({
                "category": category,
                "metric": label,
                "direction": direction or "",
                "baseline_samples": len(base_samples),
                "changed_samples": len(new_samples),
                "baseline_median": "",
                "changed_median": "",
                "improvement_pct": "",
                "speedup": "",
                "status": "MISSING",
            })
            continue

        b, n, improvement, speedup = compare_values(
            base_samples,
            new_samples,
            direction,
        )

        # Multiple occurrences within one prefill log
        # may be different test cases, not repeated runs.
        # Never pretend these are equivalent test cases.
        if category == "prefill" and (
            len(base_samples) != 1 or len(new_samples) != 1
        ):
            status = "AMBIGUOUS: multiple test cases"
        elif improvement is None:
            status = "INVALID: nonpositive value"
        elif improvement > 0:
            status = "FASTER"
        elif improvement < 0:
            status = "SLOWER"
        else:
            status = "UNCHANGED"

        rows.append({
            "category": category,
            "metric": label,
            "direction": direction,
            "baseline_samples": len(base_samples),
            "changed_samples": len(new_samples),
            "baseline_median": b,
            "changed_median": n,
            "improvement_pct": improvement,
            "speedup": speedup,
            "status": status,
        })

    return rows


COLUMNS = [
    "category",
    "metric",
    "direction",
    "baseline_samples",
    "changed_samples",
    "baseline_median",
    "changed_median",
    "improvement_pct",
    "speedup",
    "status",
]


def format_number(value, decimals=3):
    if value is None or value == "":
        return "N/A"
    return f"{value:,.{decimals}f}"


def generate_report(rows, baseline_dir, changed_dir,
                    baseline_files, changed_files):
    out = []

    out.append("=" * 100)
    out.append("QWEN3-32B BASELINE VS OPTIMIZED PERFORMANCE")
    out.append("=" * 100)
    out.append(f"Baseline: {baseline_dir}")
    out.append(f"Changed:  {changed_dir}")
    out.append("")
    out.append("Baseline files:")
    out.extend(f"  {p.name}" for p in baseline_files)
    out.append("Changed files:")
    out.extend(f"  {p.name}" for p in changed_files)
    out.append("")

    for category in ("serving", "prefill"):
        out.append("-" * 100)
        out.append(category.upper())
        out.append("-" * 100)

        subset = [r for r in rows if r["category"] == category]

        if not subset:
            out.append("No supported metrics extracted.")
            out.append("")
            continue

        for r in subset:
            out.append(f"\n{r['metric']}")
            out.append(
                f"  Baseline:    "
                f"{format_number(r['baseline_median'])}"
                f"   (n={r['baseline_samples']})"
            )
            out.append(
                f"  Changed:     "
                f"{format_number(r['changed_median'])}"
                f"   (n={r['changed_samples']})"
            )

            if r["improvement_pct"] is not None and \
                    r["improvement_pct"] != "":
                out.append(
                    f"  Improvement: "
                    f"{r['improvement_pct']:+.2f}%"
                )
                out.append(
                    f"  Speedup:     "
                    f"{r['speedup']:.4f}x"
                )

            out.append(f"  Status:      {r['status']}")

        out.append("")

    out.append("=" * 100)
    out.append("INTERPRETATION")
    out.append("=" * 100)
    out.append("Positive improvement = faster/better.")
    out.append("Negative improvement = regression.")
    out.append("For latency, lower is better.")
    out.append("For throughput, higher is better.")
    out.append(
        "Serving metrics are medians across available "
        "benchmark observations."
    )
    out.append(
        "Prefill metrics with multiple occurrences are "
        "marked ambiguous because they may represent "
        "different workload sizes."
    )
    out.append(
        "Results are not a statistical significance test."
    )
    out.append(
        "Only identical workloads and configurations "
        "provide a valid A/B comparison."
    )

    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser(
        description="Compare baseline and modified Qwen3-32B."
    )

    parser.add_argument(
        "baseline",
        type=Path,
        help="Directory containing baseline logs",
    )
    parser.add_argument(
        "changed",
        type=Path,
        help="Directory containing modified-model logs",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("results/performance_comparison"),
        help="Report output directory",
    )

    args = parser.parse_args()

    for directory in (args.baseline, args.changed):
        if not directory.is_dir():
            parser.error(f"Directory does not exist: {directory}")

    baseline_serving, bfiles = collect_serving(args.baseline)
    changed_serving, cfiles = collect_serving(args.changed)

    baseline_prefill, bpfiles = collect_prefill(args.baseline)
    changed_prefill, cpfiles = collect_prefill(args.changed)

    rows = (
        make_rows(
            "serving", baseline_serving, changed_serving
        )
        + make_rows(
            "prefill", baseline_prefill, changed_prefill
        )
    )

    args.output.mkdir(parents=True, exist_ok=True)

    csv_path = args.output / "comparison.csv"
    txt_path = args.output / "comparison.txt"

    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(rows)

    report = generate_report(
        rows,
        args.baseline,
        args.changed,
        bfiles + bpfiles,
        cfiles + cpfiles,
    )

    txt_path.write_text(report)
    print(report)

    print(f"CSV saved:  {csv_path}")
    print(f"Text saved: {txt_path}")


if __name__ == "__main__":
    main()

