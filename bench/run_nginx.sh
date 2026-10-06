#!/usr/bin/env bash
# One Nginx measurement run. Assumes nginx is running on --port and the
# desired scheduler arm is already active.
#
#   run_nginx.sh --arm A --run-id 01 --out results/x/A/run-01 \
#       --client-cpus 4-7 --interference-cpus 0-3 --port 8080 \
#       --duration 60 [--no-interference] [--warmup 10]
set -u

ARM=""; RUN_ID=""; OUT=""; SERVER_CPUS=""; CLIENT_CPUS=""
INTERFERENCE_CPUS="0-3"; PORT=8080; DURATION=60; WARMUP=10
WITH_INTERFERENCE=1
IF_CPU_WORKERS=4
IF_VM_WORKERS=2
IF_VM_BYTES="1G"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ $# -gt 0 ]; do
	case "$1" in
	--arm) ARM="$2"; shift 2 ;;
	--run-id) RUN_ID="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	--server-cpus) SERVER_CPUS="$2"; shift 2 ;;
	--client-cpus) CLIENT_CPUS="$2"; shift 2 ;;
	--interference-cpus) INTERFERENCE_CPUS="$2"; shift 2 ;;
	--if-cpu-workers) IF_CPU_WORKERS="$2"; shift 2 ;;
	--if-vm-workers) IF_VM_WORKERS="$2"; shift 2 ;;
	--if-vm-bytes) IF_VM_BYTES="$2"; shift 2 ;;
	--port) PORT="$2"; shift 2 ;;
	--duration) DURATION="$2"; shift 2 ;;
	--warmup) WARMUP="$2"; shift 2 ;;
	--no-interference) WITH_INTERFERENCE=0; shift ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

[ -n "$OUT" ] && [ -n "$ARM" ] || { echo "[FAIL] --arm and --out required" >&2; exit 1; }
mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1

NGINX_PID="$(pgrep -f 'nginx: master process' | head -n1 || true)"
[ -n "$NGINX_PID" ] || NGINX_PID="$(pgrep -x nginx | head -n1 || true)"
[ -n "$NGINX_PID" ] || { echo "[FAIL] nginx not running" >&2; exit 1; }

echo "[run] arm=$ARM run=$RUN_ID date=$(date -Is)"
echo "[run] nginx_pid=$NGINX_PID port=$PORT duration=$DURATION warmup=$WARMUP interference=$WITH_INTERFERENCE"

"$ROOT/scripts/schedpilotctl.sh" status >"$OUT/sched_status_before.txt" 2>&1 || true
if [ -x "$ROOT/build/schedpilotd" ]; then
	"$ROOT/build/schedpilotd" --dump-cfg >"$OUT/cfg_before.json" 2>&1 || true
fi
if [ -x "$ROOT/build/scx_schedpilot" ]; then
	"$ROOT/build/scx_schedpilot" --stats >"$OUT/sched_stats_before.txt" 2>&1 || true
fi
cp /proc/stat "$OUT/proc_stat_before.txt"

if [ "$WITH_INTERFERENCE" = "1" ]; then
	"$ROOT/bench/interference.sh" start --cpus "$INTERFERENCE_CPUS" \
		--cpu-workers "$IF_CPU_WORKERS" --vm-workers "$IF_VM_WORKERS" \
		--vm-bytes "$IF_VM_BYTES" >/dev/null || true
	sleep 2
	"$ROOT/bench/interference.sh" status | grep -q running || {
		echo "[FAIL] interference is not running after start" >&2
		exit 1
	}
fi

echo "[run] warmup ${WARMUP}s"
timeout "$WARMUP" wrk -t2 -c50 -d "${WARMUP}s" "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true

echo "[run] perf stat collecting"
NGINX_PIDS="$(pgrep -d, -x nginx || echo $NGINX_PID)"
perf stat -p "$NGINX_PIDS" -e task-clock,context-switches,cpu-migrations,cycles,instructions,cache-references,cache-misses \
	-o "$OUT/perf_stat.txt" -- sleep "$DURATION" >/dev/null 2>&1 &
PERF_PID=$!

echo "[run] wrk -t2 -c50 -d ${DURATION}s (client pinned to cpus $CLIENT_CPUS)"
taskset -c "$CLIENT_CPUS" wrk -t2 -c50 -d "${DURATION}s" --latency \
	"http://127.0.0.1:$PORT/" >"$OUT/wrk.out" 2>&1 || true
wait "$PERF_PID" 2>/dev/null || true

if [ "$WITH_INTERFERENCE" = "1" ]; then
	"$ROOT/bench/interference.sh" stop >/dev/null || true
fi
"$ROOT/scripts/schedpilotctl.sh" status >"$OUT/sched_status_after.txt" 2>&1 || true
if [ -x "$ROOT/build/schedpilotd" ]; then
	"$ROOT/build/schedpilotd" --dump-cfg >"$OUT/cfg_after.json" 2>&1 || true
fi
if [ -x "$ROOT/build/scx_schedpilot" ]; then
	"$ROOT/build/scx_schedpilot" --stats >"$OUT/sched_stats_after.txt" 2>&1 || true
fi
cp /proc/stat "$OUT/proc_stat_after.txt"
dmesg 2>/dev/null | tail -n 50 >"$OUT/dmesg_after.txt" || true

# ---------- parse ----------
python3 "$ROOT/bench/parse_wrk.py" "$OUT/wrk.out" >"$OUT/summary.json" 2>/dev/null \
	|| true

echo "[run] done arm=$ARM run=$RUN_ID"
[ -f "$OUT/summary.json" ] && cat "$OUT/summary.json"
