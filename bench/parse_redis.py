#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Parse redis-benchmark output and emit a JSON summary.

Includes a fixed-SLO goodput metric computed from the cumulative-count
percentile distribution: goodput = rps * (count(latency <= SLO) / total).
SLO is configurable via SP_SLO_MS (default 5.0 ms).
"""
import json
import os
import re
import sys

SLO_MS = float(os.environ.get("SP_SLO_MS", "5.0"))

FIELDS = ("rps", "avg_ms", "min_ms", "p50_ms", "p95_ms", "p99_ms", "p999_ms",
          "max_ms", "slo_ms", "slo_pct", "slo_goodput_rps")


def parse(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    tests = {}
    blocks = re.split(r'^====== (.+?) ======\s*$', text, flags=re.M)
    for i in range(1, len(blocks), 2):
        name = blocks[i].strip()
        body = blocks[i + 1] if i + 1 < len(blocks) else ""
        entry = {k: None for k in FIELDS}

        m = re.search(r'throughput summary:\s*([0-9.]+)\s*requests per second', body)
        if m:
            entry["rps"] = float(m.group(1))

        m = re.search(
            r'latency summary \(msec\):\s*\n\s*avg\s+min\s+p50\s+p95\s+p99\s+max\s*\n'
            r'\s*([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)',
            body)
        if m:
            (entry["avg_ms"], entry["min_ms"], entry["p50_ms"], entry["p95_ms"],
             entry["p99_ms"], entry["max_ms"]) = map(float, m.groups())

        total = 0
        best = 0
        for pct, val, cnt in re.findall(
                r'([0-9]+(?:\.[0-9]+)?)%\s*<=\s*([0-9.]+)\s*milliseconds'
                r'(?:\s*\(cumulative count ([0-9]+)\))?', body):
            v = float(val)
            if cnt:
                c = int(cnt)
                total = max(total, c)
                if v <= SLO_MS:
                    best = max(best, c)
            if float(pct) >= 99.9 and entry["p999_ms"] is None:
                entry["p999_ms"] = v

        entry["slo_ms"] = SLO_MS
        if entry["rps"] and total:
            entry["slo_pct"] = 100.0 * best / total
            entry["slo_goodput_rps"] = entry["rps"] * best / total
        tests[name] = entry

    primary = "GET" if "GET" in tests else (next(iter(tests)) if tests else None)
    return {
        "source": path,
        "tests": tests,
        "primary": primary,
        "primary_data": tests.get(primary, {}) if primary else {},
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: parse_redis.py <redis-benchmark output>", file=sys.stderr)
        sys.exit(2)
    print(json.dumps(parse(sys.argv[1]), indent=2))
