#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Backfill summary.json for existing experiment runs.

Re-parses raw workload outputs with the current parsers and updates both
<run>/summary.json and <run>/meta.json (primary_data), so older result
trees gain new metrics (e.g. fixed-SLO goodput) without re-running.

Usage: reparse_results.py <results-dir> [--slo-ms N]
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def parser_for(name):
    if name == "redis.out":
        return os.path.join(HERE, "parse_redis.py"), "summary.json"
    if name == "wrk.out":
        return os.path.join(HERE, "parse_wrk.py"), "summary.json"
    if name == "sysbench.out":
        return os.path.join(HERE, "parse_mysql.py"), "summary.json"
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--slo-ms", type=float, default=None)
    args = ap.parse_args()

    if args.slo_ms is not None:
        os.environ["SP_SLO_MS"] = str(args.slo_ms)

    updated = 0
    for root, dirs, files in os.walk(args.results):
        parser, outname = None, None
        for raw in ("redis.out", "wrk.out", "sysbench.out"):
            if raw in files:
                parser, outname = parser_for(raw)
                break
        if not parser:
            continue
        raw_path = os.path.join(root, raw)
        try:
            out = subprocess.check_output([sys.executable, parser, raw_path])
            summary = json.loads(out)
        except Exception as e:
            print(f"[warn] {raw_path}: {e}", file=sys.stderr)
            continue
        with open(os.path.join(root, outname), "w") as f:
            json.dump(summary, f, indent=2)
        meta_path = os.path.join(root, "meta.json")
        if os.path.exists(meta_path):
            try:
                meta = json.load(open(meta_path))
                meta["primary"] = summary.get("primary_data", {})
                with open(meta_path, "w") as f:
                    json.dump(meta, f, indent=2)
            except Exception as e:
                print(f"[warn] {meta_path}: {e}", file=sys.stderr)
        updated += 1
    print(f"reparsed {updated} runs under {args.results}")


if __name__ == "__main__":
    main()
