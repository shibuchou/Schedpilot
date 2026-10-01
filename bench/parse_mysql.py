#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Parse sysbench OLTP output and emit a JSON summary.

Throughput metric is transactions/sec (stored in `rps` so the shared
analyzer treats it as the primary throughput). sysbench 1.0.20 reports one
configurable percentile (we run with --percentile=99); p95/p50 are left null.
"""
import json
import re
import sys

FIELDS = ("rps", "tps", "qps", "transactions", "queries", "avg_ms", "min_ms",
          "max_ms", "p50_ms", "p95_ms", "p99_ms", "p999_ms")


def parse(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    entry = {k: None for k in FIELDS}

    m = re.search(r'transactions:\s+([0-9]+)\s+\(([0-9.]+) per sec\.\)', text)
    if m:
        entry["transactions"] = int(m.group(1))
        entry["tps"] = float(m.group(2))
        entry["rps"] = float(m.group(2))

    m = re.search(r'queries:\s+([0-9]+)\s+\(([0-9.]+) per sec\.\)', text)
    if m:
        entry["queries"] = int(m.group(1))
        entry["qps"] = float(m.group(2))

    m = re.search(
        r'Latency \(ms\):\s*\n\s*min:\s*([0-9.]+)\s*\n\s*avg:\s*([0-9.]+)\s*\n'
        r'\s*max:\s*([0-9.]+)\s*\n\s*[0-9]+th percentile:\s*([0-9.]+)', text)
    if m:
        entry["min_ms"] = float(m.group(1))
        entry["avg_ms"] = float(m.group(2))
        entry["max_ms"] = float(m.group(3))
        entry["p99_ms"] = float(m.group(4))

    return {
        "source": path,
        "primary": "SYSBENCH_OLTP",
        "primary_data": entry,
        "tests": {"SYSBENCH_OLTP": entry},
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: parse_mysql.py <sysbench output>", file=sys.stderr)
        sys.exit(2)
    print(json.dumps(parse(sys.argv[1]), indent=2))
