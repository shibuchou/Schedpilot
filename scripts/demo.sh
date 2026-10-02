#!/usr/bin/env bash
# One-click SchedPilot demo: env check -> quick A vs D curve -> rollback.
#   scripts/demo.sh [duration_s] [runs]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DURATION="${1:-20}"
RUNS="${2:-1}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/results/demo-${TS}"

echo "== SchedPilot demo =="
[ -x "$ROOT/build/scx_schedpilot" ] || { echo "[FAIL] run scripts/build.sh first"; exit 1; }

"$ROOT/scripts/env_check.sh" 2>/dev/null | tail -n 6
"$ROOT/scripts/schedpilotctl.sh" rollback >/dev/null 2>&1 || true

echo "== quick A vs D on Redis (duration=${DURATION}s) =="
"$ROOT/bench/abcd_experiment.sh" --workload redis --runs "$RUNS" \
	--duration "$DURATION" --warmup 5 --arms A,D --results "$OUT"

echo
echo "== demo summary =="
cat "$OUT/summary.md" 2>/dev/null || echo "no summary"
"$ROOT/scripts/schedpilotctl.sh" rollback >/dev/null 2>&1 || true
echo "== done; results at $OUT =="
