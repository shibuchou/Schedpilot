#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""SchedPilot experiment statistics.

Reads the A/B/C/D results tree produced by bench/abcd_experiment.sh and writes:
  - summary.csv     : per-arm statistics (median/IQR/mean/std/95% CI)
  - per_run.csv     : one row per measurement
  - summary.md      : human-readable report with baseline deltas, Mann-Whitney
                      U tests and attribution chain (B-A, C-B, D-C, D-A)
  - summary_*.png   : optional boxplots when matplotlib is available
"""
import argparse
import csv
import json
import math
import os
import statistics
import sys
from collections import OrderedDict

METRIC_KEYS = [
    ("qps", "throughput (req/s)", True),
    ("p50_ms", "p50 latency (ms)", False),
    ("p95_ms", "p95 latency (ms)", False),
    ("p99_ms", "p99 latency (ms)", False),
    ("p999_ms", "p99.9 latency (ms)", False),
    ("csw", "context switches (perf stat)", False),
    ("migrations", "CPU migrations (perf stat)", False),
    ("ipc", "Redis process IPC (perf stat)", True),
    ("mpki", "Redis process LLC MPKI (perf stat)", False),
]

T_TABLE = {
    2: 12.706, 3: 4.303, 4: 3.182, 5: 2.776, 6: 2.571, 7: 2.447,
    8: 2.365, 9: 2.306, 10: 2.262, 11: 2.228, 12: 2.201, 13: 2.179,
    14: 2.160, 15: 2.145, 16: 2.131, 17: 2.120, 18: 2.110, 19: 2.101,
    20: 2.093, 21: 2.086, 22: 2.080, 23: 2.074, 24: 2.069, 25: 2.064,
    26: 2.060, 27: 2.056, 28: 2.052, 29: 2.048, 30: 2.045, 40: 2.021,
    50: 2.009, 60: 2.000,
}


def t_crit(n):
    if n <= 1:
        return float("nan")
    keys = sorted(T_TABLE)
    for k in keys:
        if n <= k:
            return T_TABLE[k]
    return 1.96


def parse_perf_stat(path):
    """Extract counters from `perf stat -p PID -e ...` text output."""
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.replace(",", "").split()
        if len(parts) < 2:
            continue
        try:
            value = float(parts[0])
        except ValueError:
            continue
        name = parts[1]
        if "context-switches" in name:
            out["csw"] = value
        elif "cpu-migrations" in name:
            out["migrations"] = value
        elif name == "cycles":
            out["cycles"] = value
        elif name == "instructions":
            out["instructions"] = value
        elif "cache-references" in name:
            out["cache_refs"] = value
        elif "cache-misses" in name:
            out["cache_misses"] = value
        elif "task-clock" in name:
            out["task_clock_ms"] = value
    if out.get("cycles") and out.get("instructions"):
        out["ipc"] = out["instructions"] / out["cycles"]
    if out.get("instructions") and out.get("cache_misses") is not None:
        out["mpki"] = out["cache_misses"] / out["instructions"] * 1000.0
    return out


def load_runs(results):
    per_run = []
    for arm in sorted(os.listdir(results)):
        arm_dir = os.path.join(results, arm)
        if not os.path.isdir(arm_dir):
            continue
        for run_name in sorted(os.listdir(arm_dir)):
            run_dir = os.path.join(arm_dir, run_name)
            if not os.path.isdir(run_dir):
                continue
            row = {"arm": arm, "run": run_name}
            try:
                meta = json.load(open(os.path.join(run_dir, "meta.json")))
                primary = meta.get("primary", {})
                row.update({
                    "qps": primary.get("rps"),
                    "p50_ms": primary.get("p50_ms"),
                    "p95_ms": primary.get("p95_ms"),
                    "p99_ms": primary.get("p99_ms"),
                    "p999_ms": primary.get("p999_ms"),
                })
            except Exception:
                pass
            row.update(parse_perf_stat(os.path.join(run_dir, "perf_stat.txt")))
            row["dir"] = run_dir
            if row.get("qps") is not None:
                per_run.append(row)
    return per_run


def stats_for(values):
    values = [v for v in values if v is not None and not math.isnan(v)]
    n = len(values)
    if n == 0:
        return {"n": 0}
    mean = statistics.fmean(values)
    std = statistics.stdev(values) if n > 1 else 0.0
    med = statistics.median(values)
    s = sorted(values)
    q1 = s[len(s) // 4]
    q3 = s[(3 * len(s)) // 4]
    half = t_crit(n) * std / math.sqrt(n) if n > 1 else 0.0
    return {
        "n": n, "median": med, "q1": q1, "q3": q3, "iqr": q3 - q1,
        "mean": mean, "std": std, "ci95_half": half,
        "min": s[0], "max": s[-1],
    }


def mann_whitney_p(a, b):
    """Two-sided Mann-Whitney U p-value, normal approximation with tie
    correction. Small samples: report p but interpret cautiously."""
    a = [v for v in a if v is not None]
    b = [v for v in b if v is not None]
    n1, n2 = len(a), len(b)
    if n1 < 3 or n2 < 3:
        return None
    combined = [(v, 0) for v in a] + [(v, 1) for v in b]
    combined.sort(key=lambda x: x[0])
    ranks = [0.0] * len(combined)
    i = 0
    tie_sum = 0.0
    while i < len(combined):
        j = i
        while j + 1 < len(combined) and combined[j + 1][0] == combined[i][0]:
            j += 1
        avg_rank = (i + j) / 2.0 + 1
        for k in range(i, j + 1):
            ranks[k] = avg_rank
        tie_sum += (j - i + 1) ** 3 - (j - i + 1)
        i = j + 1
    r1 = sum(ranks[k] for k in range(len(combined)) if combined[k][1] == 0)
    u1 = r1 - n1 * (n1 + 1) / 2.0
    mu = n1 * n2 / 2.0
    n = n1 + n2
    sigma = math.sqrt(n1 * n2 / 12.0 * ((n + 1) - tie_sum / (n * (n - 1))))
    if sigma == 0:
        return None
    z = (u1 - mu) / sigma
    # two-sided normal p-value
    p = math.erfc(abs(z) / math.sqrt(2.0))
    return p


def fmt(v, digits=3):
    if v is None:
        return "-"
    return f"{v:.{digits}f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--baseline", default="A")
    args = ap.parse_args()

    results = args.results
    per_run = load_runs(results)
    arms = OrderedDict()
    for row in per_run:
        arms.setdefault(row["arm"], []).append(row)

    os.makedirs(results, exist_ok=True)
    with open(os.path.join(results, "per_run.csv"), "w", newline="") as f:
        fieldnames = ["arm", "run"] + [k for k, _, _ in METRIC_KEYS] + ["dir"]
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for row in per_run:
            w.writerow(row)

    summary = OrderedDict()
    for arm, rows in arms.items():
        summary[arm] = OrderedDict()
        for key, _, _ in METRIC_KEYS:
            summary[arm][key] = stats_for([r.get(key) for r in rows])

    with open(os.path.join(results, "summary.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["arm", "metric", "n", "median", "iqr", "mean", "std",
                    "ci95_half", "min", "max"])
        for arm, metrics in summary.items():
            for key, _, _ in METRIC_KEYS:
                s = metrics.get(key, {})
                w.writerow([arm, key, s.get("n", 0),
                            s.get("median", ""), s.get("iqr", ""),
                            s.get("mean", ""), s.get("std", ""),
                            s.get("ci95_half", ""), s.get("min", ""),
                            s.get("max", "")])

    lines = []
    lines.append("# SchedPilot experiment summary\n")
    lines.append(f"- results: `{results}`")
    lines.append(f"- baseline arm: **{args.baseline}** "
                 "(openEuler default fair-class scheduler; competition text: default CFS)")
    lines.append("- delta is (arm - baseline) / baseline; negative latency delta = better\n")

    baseline_rows = arms.get(args.baseline, [])
    if not baseline_rows:
        lines.append("**No baseline arm data found.**\n")

    header = "| arm | n | QPS median [IQR] | QPS delta | p99 med (ms) | p99 delta | p99 delta 95% CI | p99 p-value |"
    lines.append(header)
    lines.append("|---|---|---|---|---|---|---|---|")

    for arm, rows in arms.items():
        qps = stats_for([r.get("qps") for r in rows])
        p99 = stats_for([r.get("p99_ms") for r in rows])
        bq = stats_for([r.get("qps") for r in baseline_rows])
        bp = stats_for([r.get("p99_ms") for r in baseline_rows])

        def pct(arm_s, base_s, lower_better=False):
            if not arm_s.get("median") or not base_s.get("median"):
                return "-"
            d = (arm_s["median"] - base_s["median"]) / base_s["median"] * 100.0
            return f"{d:+.1f}%"

        ci = "-"
        if arm != args.baseline and p99.get("n", 0) > 1 and bp.get("n", 0) > 1:
            a = [r.get("p99_ms") for r in rows if r.get("p99_ms") is not None]
            b = [r.get("p99_ms") for r in baseline_rows
                 if r.get("p99_ms") is not None]
            # Welch style CI for the mean difference scaled to baseline mean
            if len(a) > 1 and len(b) > 1:
                ma, mb = statistics.fmean(a), statistics.fmean(b)
                sa = statistics.stdev(a) / math.sqrt(len(a))
                sb = statistics.stdev(b) / math.sqrt(len(b))
                se = math.sqrt(sa * sa + sb * sb)
                tcrit = max(t_crit(len(a)), t_crit(len(b)))
                lo = ((ma - mb) - tcrit * se) / mb * 100.0
                hi = ((ma - mb) + tcrit * se) / mb * 100.0
                ci = f"[{lo:+.1f}%, {hi:+.1f}%]"

        pval = "-"
        if arm != args.baseline and p99.get("n", 0) >= 3 and bp.get("n", 0) >= 3:
            p = mann_whitney_p(
                [r.get("p99_ms") for r in rows],
                [r.get("p99_ms") for r in baseline_rows])
            if p is not None:
                pval = f"{p:.4f}"

        lines.append(
            f"| {arm} | {qps.get('n', 0)} | "
            f"{fmt(qps.get('median'))} [{fmt(qps.get('iqr'))}] | "
            f"{pct(qps, bq)} | "
            f"{fmt(p99.get('median'))} [{fmt(p99.get('iqr'))}] | "
            f"{pct(p99, bp)} | {ci} | {pval} |")

    lines.append("\n## Attribution chain\n")
    lines.append("| step | comparison | QPS delta (median) | p99 delta (median) |")
    lines.append("|---|---|---|---|")
    chain = [("sched_ext effect", "B", "A"), ("classification effect", "C", "B"),
             ("adaptive policy effect", "D", "C"), ("total effect", "D", "A"),
             ("ablation: no PMU", "d-no-pmu", "D"),
             ("ablation: no LLC control", "d-no-llc", "D"),
             ("ablation: no BG contain", "d-no-bg", "D")]
    for label, arm, base in chain:
        if arm not in arms or base not in arms:
            continue
        aq = stats_for([r.get("qps") for r in arms[arm]]).get("median")
        bq = stats_for([r.get("qps") for r in arms[base]]).get("median")
        ap = stats_for([r.get("p99_ms") for r in arms[arm]]).get("median")
        bp = stats_for([r.get("p99_ms") for r in arms[base]]).get("median")
        dq = f"{(aq - bq) / bq * 100:+.1f}%" if aq and bq else "-"
        dp = f"{(ap - bp) / bp * 100:+.1f}%" if ap and bp else "-"
        lines.append(f"| {label} | {arm} vs {base} | {dq} | {dp} |")

    with open(os.path.join(results, "summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")

    # Optional plots
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        for key, label, _ in [("qps", "throughput (req/s)", True),
                              ("p99_ms", "p99 latency (ms)", False)]:
            data = [[r.get(key) for r in rows if r.get(key) is not None]
                    for _, rows in arms.items()]
            if not any(data):
                continue
            fig, ax = plt.subplots(figsize=(8, 4.5))
            ax.boxplot(data, labels=list(arms.keys()))
            ax.set_ylabel(label)
            ax.grid(True, alpha=0.3)
            fig.tight_layout()
            fig.savefig(os.path.join(results, f"summary_{key}.png"), dpi=150)
            plt.close(fig)
    except Exception:
        pass

    print("\n".join(lines))
    print(f"\nwritten: {results}/summary.md, summary.csv, per_run.csv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
