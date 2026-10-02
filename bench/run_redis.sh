#!/usr/bin/env bash
# One Redis measurement run. Assumes redis-server is already running on
# --port and the desired scheduler arm is already active.
#
#   run_redis.sh --arm A --run-id 01 --out results/x/A/run-01 \
#       --server-cpus 0-3 --client-cpus 4-7 --interference-cpus 0-3 \
#       --port 6399 --duration 60 [--no-interference] [--warmup 10]
set -u

ARM=""; RUN_ID=""; OUT=""; SERVER_CPUS=""; CLIENT_CPUS=""
INTERFERENCE_CPUS=""; PORT=6399; DURATION=60; WARMUP=10
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

REDIS_PID="$(pgrep -f "redis-server .*:$PORT|redis-server .*redis-schedpilot.conf" | head -n1 || true)"
[ -n "$REDIS_PID" ] || REDIS_PID="$(pgrep -x redis-server | head -n1 || true)"
[ -n "$REDIS_PID" ] || { echo "[FAIL] redis-server not running" >&2; exit 1; }

echo "[run] arm=$ARM run=$RUN_ID date=$(date -Is)"
echo "[run] redis_pid=$REDIS_PID port=$PORT duration=$DURATION warmup=$WARMUP interference=$WITH_INTERFERENCE"

# ---------- before snapshots ----------
"$ROOT/scripts/schedpilotctl.sh" status >"$OUT/sched_status_before.txt" 2>&1 || true
if [ -x "$ROOT/build/schedpilotd" ]; then
	"$ROOT/build/schedpilotd" --dump-cfg >"$OUT/cfg_before.json" 2>&1 || true
fi
if [ -x "$ROOT/build/scx_schedpilot" ]; then
	"$ROOT/build/scx_schedpilot" --stats >"$OUT/sched_stats_before.txt" 2>&1 || true
fi
redis-cli -p "$PORT" info stats >"$OUT/redis_info_before.txt" 2>/dev/null || true
cp /proc/stat "$OUT/proc_stat_before.txt"
dmesg 2>/dev/null | tail -n 50 >"$OUT/dmesg_before.txt" || true

# ---------- interference ----------
if [ "$WITH_INTERFERENCE" = "1" ]; then
	"$ROOT/bench/interference.sh" start --cpus "$INTERFERENCE_CPUS" \
		--cpu-workers "$IF_CPU_WORKERS" --vm-workers "$IF_VM_WORKERS" \
		--vm-bytes "$IF_VM_BYTES" >/dev/null || true
	sleep 2
fi

# ---------- warmup ----------
echo "[run] warmup ${WARMUP}s"
timeout "$WARMUP" redis-benchmark -h 127.0.0.1 -p "$PORT" -t get -c 50 \
	-n 100000000 -q >/dev/null 2>&1 || true

# ---------- estimate request count for target duration ----------
# Use a longer burst (100k requests) so the estimate reflects sustained
# steady-state throughput under interference, not a sub-second transient.
EST_OUT="$(redis-benchmark -h 127.0.0.1 -p "$PORT" -t get -c 50 -n 100000 -q 2>/dev/null || true)"
RATE="$(printf '%s' "$EST_OUT" | grep -oE '[0-9]+(\.[0-9]+)? requests per second' | head -n1 | awk '{print $1}')"
if [ -z "$RATE" ]; then RATE=20000; fi
TOTAL="$(python3 -c "r=float('${RATE}'); d=float('${DURATION}'); print(max(50000, int(round(r*d/1000.0))*1000))")"
echo "[run] estimated rate=$RATE rps -> total=$TOTAL requests"

# ---------- measure ----------
echo "[run] perf stat collecting scheduler/memory counters"
perf stat -p "$REDIS_PID" -e task-clock,context-switches,cpu-migrations,cycles,instructions,cache-references,cache-misses \
	-o "$OUT/perf_stat.txt" -- sleep "$DURATION" >/dev/null 2>&1 &
PERF_PID=$!

echo "[run] redis-benchmark -t get -n $TOTAL -c 50 (pinned to cpus $CLIENT_CPUS)"
taskset -c "$CLIENT_CPUS" redis-benchmark -h 127.0.0.1 -p "$PORT" -t get -c 50 \
	-n "$TOTAL" --precision 3 >"$OUT/redis.out" 2>&1 || true
wait "$PERF_PID" 2>/dev/null || true

# ---------- after snapshots ----------
redis-cli -p "$PORT" info stats >"$OUT/redis_info_after.txt" 2>/dev/null || true
redis-cli -p "$PORT" info cpu >"$OUT/redis_cpu_after.txt" 2>/dev/null || true
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
python3 "$ROOT/bench/parse_redis.py" "$OUT/redis.out" >"$OUT/summary.json"

echo "[run] done arm=$ARM run=$RUN_ID"
[ -f "$OUT/summary.json" ] && cat "$OUT/summary.json"
