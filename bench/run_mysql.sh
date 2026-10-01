#!/usr/bin/env bash
# One MySQL OLTP measurement run (sysbench). Assumes mysqld is running on
# --port with the prepared schedpilot database.
#
#   run_mysql.sh --arm A --run-id 01 --out results/x/A/run-01 \
#       --client-cpus 4-7 --interference-cpus 0-3 --port 3307 \
#       --duration 60 [--no-interference] [--warmup 10]
set -u

ARM=""; RUN_ID=""; OUT=""; SERVER_CPUS=""; CLIENT_CPUS=""
INTERFERENCE_CPUS="0-3"; PORT=3307; DURATION=60; WARMUP=10
WITH_INTERFERENCE=1
IF_CPU_WORKERS=4
IF_VM_WORKERS=2
IF_VM_BYTES="1G"
THREADS=8
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MYSQL_CNF=/etc/schedpilot-mysql.cnf

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
	--threads) THREADS="$2"; shift 2 ;;
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

MYSQLD_PID="$(pgrep -x mysqld | head -n1 || true)"
[ -n "$MYSQLD_PID" ] || { echo "[FAIL] mysqld not running" >&2; exit 1; }

SYSBENCH_OPTS="--mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=root --mysql-db=schedpilot --tables=4 --threads=$THREADS"

echo "[run] arm=$ARM run=$RUN_ID date=$(date -Is)"
echo "[run] mysqld_pid=$MYSQLD_PID port=$PORT duration=$DURATION warmup=$WARMUP threads=$THREADS interference=$WITH_INTERFERENCE"

"$ROOT/scripts/schedpilotctl.sh" status >"$OUT/sched_status_before.txt" 2>&1 || true
if [ -x "$ROOT/build/schedpilotd" ]; then
	"$ROOT/build/schedpilotd" --dump-cfg >"$OUT/cfg_before.json" 2>&1 || true
fi
if [ -x "$ROOT/build/scx_schedpilot" ]; then
	"$ROOT/build/scx_schedpilot" --stats >"$OUT/sched_stats_before.txt" 2>&1 || true
fi
mysql --defaults-file="$MYSQL_CNF" -uroot -e 'SHOW GLOBAL STATUS' >"$OUT/mysql_status_before.txt" 2>/dev/null || true
cp /proc/stat "$OUT/proc_stat_before.txt"

if [ "$WITH_INTERFERENCE" = "1" ]; then
	"$ROOT/bench/interference.sh" start --cpus "$INTERFERENCE_CPUS" \
		--cpu-workers "$IF_CPU_WORKERS" --vm-workers "$IF_VM_WORKERS" \
		--vm-bytes "$IF_VM_BYTES" >/dev/null || true
	sleep 2
fi

echo "[run] warmup ${WARMUP}s"
timeout "$WARMUP" taskset -c "$CLIENT_CPUS" sysbench oltp_read_only $SYSBENCH_OPTS \
	--time="$WARMUP" run >/dev/null 2>&1 || true

echo "[run] perf stat collecting"
perf stat -p "$MYSQLD_PID" -e task-clock,context-switches,cpu-migrations,cycles,instructions,cache-references,cache-misses \
	-o "$OUT/perf_stat.txt" -- sleep "$DURATION" >/dev/null 2>&1 &
PERF_PID=$!

echo "[run] sysbench oltp_read_only ${DURATION}s (client pinned to cpus $CLIENT_CPUS)"
taskset -c "$CLIENT_CPUS" sysbench oltp_read_only $SYSBENCH_OPTS \
	--time="$DURATION" --percentile=99 run >"$OUT/sysbench.out" 2>&1 || true
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
mysql --defaults-file="$MYSQL_CNF" -uroot -e 'SHOW GLOBAL STATUS' >"$OUT/mysql_status_after.txt" 2>/dev/null || true
cp /proc/stat "$OUT/proc_stat_after.txt"
dmesg 2>/dev/null | tail -n 50 >"$OUT/dmesg_after.txt" || true

# ---------- parse ----------
python3 "$ROOT/bench/parse_mysql.py" "$OUT/sysbench.out" >"$OUT/summary.json" 2>/dev/null \
	|| true

echo "[run] done arm=$ARM run=$RUN_ID"
[ -f "$OUT/summary.json" ] && cat "$OUT/summary.json"
