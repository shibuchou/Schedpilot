#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Parse wrk output (nginx benchmark) and emit a JSON summary.

wrk reports 50/75/90/99th percentile latencies and Requests/sec.
p95 is not reported by wrk and is left null (documented limitation).
"""
import json
import re
import sys

FIELDS = ("rps", "avg_ms", "max_ms", "p50_ms", "p75_ms", "p90_ms", "p95_ms",
          "p99_ms", "p999_ms")


def _to_ms(value, unit):
    v = float(value)
    if unit == "us":
        return v / 1000.0
    if unit == "ms":
        return v
    if unit == "s":
        return v * 1000.0
    return v


def parse(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    entry = {k: None for k in FIELDS}

    m = re.search(r'Requests/sec:\s*([0-9.]+)', text)
    if m:
        entry["rps"] = float(m.group(1))

    m = re.search(
        r'Latency\s+([0-9.]+)(us|ms|s)\s+([0-9.]+)(us|ms|s)\s+([0-9.]+)(us|ms|s)',
        text)
    if m:
        entry["avg_ms"] = _to_ms(m.group(1), m.group(2))
        entry["max_ms"] = _to_ms(m.group(5), m.group(6))

    for pct_name, key in (("50", "p50_ms"), ("75", "p75_ms"),
                          ("90", "p90_ms"), ("99", "p99_ms")):
        m = re.search(r'^\s*%s%%\s+([0-9.]+)(us|ms|s)\s*$' % pct_name,
                      text, flags=re.M)
        if m:
            entry[key] = _to_ms(m.group(1), m.group(2))

    return {
        "source": path,
        "primary": "HTTP_GET",
        "primary_data": entry,
        "tests": {"HTTP_GET": entry},
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: parse_wrk.py <wrk output>", file=sys.stderr)
        sys.exit(2)
    print(json.dumps(parse(sys.argv[1]), indent=2))
