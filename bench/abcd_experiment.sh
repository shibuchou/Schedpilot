#!/usr/bin/env bash
# SchedPilot A/B/C/D progressive comparison + ablations.
#
#   A  = openEuler default fair-class scheduler (competition text: default CFS)
#   B  = basic sched_ext scheduler (single shared DSQ)
#   C  = + task classification (LAT/COMP/CACHE DSQs, static policy)
#   D  = SchedPilot full adaptive (classification + adaptive knobs + LL affinity
#        + BG containment + wakeup preemption)
#
# Ablations of D:
#   d-no-pmu  = PMU classification disabled (scheduling features only)
#   d-no-llc  = LLC affinity / migration penalty disabled
#   d-no-bg   = BG vtime containment disabled
#
# Runs are interleaved with rotated arm order to de-bias thermal/background
# drift. Per-run raw data lands under <results>/<arm>/run-NN/.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS=20
DURATION=60
WARMUP=10
RESULTS=""
ARMS="A,B,C,D"
SERVER_CPUS="0-3"
CLIENT_CPUS="4-7"
INTERFERENCE_CPUS="0-3"
PORT=6399
NO_INTERFERENCE=0
SKIP_ANALYZE=0
CONFIG="$ROOT/configs/redis.conf"
IF_CPU_WORKERS=4
IF_VM_WORKERS=2
IF_VM_BYTES="1G"

while [ $# -gt 0 ]; do
	case "$1" in
	--runs) RUNS="$2"; shift 2 ;;
	--duration) DURATION="$2"; shift 2 ;;
	--warmup) WARMUP="$2"; shift 2 ;;
	--results) RESULTS="$2"; shift 2 ;;
	--arms) ARMS="$2"; shift 2 ;;
	--server-cpus) SERVER_CPUS="$2"; shift 2 ;;
	--client-cpus) CLIENT_CPUS="$2"; shift 2 ;;
	--interference-cpus) INTERFERENCE_CPUS="$2"; shift 2 ;;
	--port) PORT="$2"; shift 2 ;;
	--config) CONFIG="$2"; shift 2 ;;
	--if-cpu-workers) IF_CPU_WORKERS="$2"; shift 2 ;;
	--if-vm-workers) IF_VM_WORKERS="$2"; shift 2 ;;
	--if-vm-bytes) IF_VM_BYTES="$2"; shift 2 ;;
	--no-interference) NO_INTERFERENCE=1; shift ;;
	--skip-analyze) SKIP_ANALYZE=1; shift ;;
	-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

[ -n "$RESULTS" ] || RESULTS="$ROOT/results/$(hostname)-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS"
echo "[exp] results=$RESULTS runs=$RUNS duration=${DURATION}s warmup=${WARMUP}s arms=$ARMS"

# ---------- environment + redis server ----------
"$ROOT/scripts/env_check.sh" --label "$(basename "$RESULTS")" \
	--json "$RESULTS/env_check.json" >"$RESULTS/env_check.log" 2>&1 || true

REDIS_LOG="$RESULTS/redis-server.log"
mkdir -p /tmp/schedpilot-redis
taskset -c "$SERVER_CPUS" redis-server "$ROOT/bench/redis-schedpilot.conf" \
	--port "$PORT" >"$REDIS_LOG" 2>&1 &
REDIS_PID=$!
for _ in $(seq 1 30); do
	redis-cli -p "$PORT" ping >/dev/null 2>&1 && break
	sleep 0.5
done
redis-cli -p "$PORT" ping >/dev/null 2>&1 || { echo "[FAIL] redis-server did not start" >&2; exit 1; }
echo "[exp] redis-server pid=$REDIS_PID port=$PORT cpus=$SERVER_CPUS"

cleanup() {
	echo "[exp] cleanup"
	"$ROOT/bench/interference.sh" stop >/dev/null 2>&1 || true
	"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1 || true
	kill "$REDIS_PID" 2>/dev/null || true
	rm -f "$RESULTS/redis-server.pid"
}
trap cleanup EXIT INT TERM
echo "$REDIS_PID" >"$RESULTS/redis-server.pid"

cat >"$RESULTS/experiment.meta.json" <<EOF
{
  "started": "$(date -Is)",
  "host": "$(hostname)",
  "kernel": "$(uname -r)",
  "runs": $RUNS,
  "duration_s": $DURATION,
  "warmup_s": $WARMUP,
  "arms": "$ARMS",
  "server_cpus": "$SERVER_CPUS",
  "client_cpus": "$CLIENT_CPUS",
  "interference_cpus": "$INTERFERENCE_CPUS",
  "interference": $([ "$NO_INTERFERENCE" = "1" ] && echo false || echo true),
  "interference_cpu_workers": $IF_CPU_WORKERS,
  "interference_vm_workers": $IF_VM_WORKERS,
  "interference_vm_bytes": "$IF_VM_BYTES",
  "redis_port": $PORT,
  "redis_config": "$CONFIG",
  "baseline_note": "Baseline is the openEuler default fair-class scheduler (competition text: default CFS); Linux 6.6 fair-class internals are not assumed identical to mainline classic CFS.",
  "git_commit": "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
}
EOF

setup_arm() {
	local arm="$1" out="$2"
	mkdir -p "$out/logs"
	case "$arm" in
	A)
		"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1
		;;
	B)
		"$ROOT/scripts/schedpilotctl.sh" start --mode basic --no-daemon
		;;
	C)
		"$ROOT/scripts/schedpilotctl.sh" start --mode class --config "$CONFIG" --policy off --log-dir "$out/logs"
		;;
	D)
		"$ROOT/scripts/schedpilotctl.sh" start --mode adaptive --config "$CONFIG" --policy on --log-dir "$out/logs"
		;;
	d-no-pmu)
		"$ROOT/scripts/schedpilotctl.sh" start --mode adaptive --config "$CONFIG" --policy on --log-dir "$out/logs" --ablation pmu_classify=0
		;;
	d-no-llc)
		"$ROOT/scripts/schedpilotctl.sh" start --mode adaptive --config "$CONFIG" --policy on --log-dir "$out/logs" --ablation llc_affinity=0
		;;
	d-no-bg)
		"$ROOT/scripts/schedpilotctl.sh" start --mode adaptive --config "$CONFIG" --policy on --log-dir "$out/logs" --ablation bg_contain=0
		;;
	*)
		echo "[FAIL] unknown arm: $arm" >&2; exit 1
		;;
	esac
	sleep 2
}

IFS=',' read -r -a ARM_LIST <<<"$ARMS"
N_ARMS=${#ARM_LIST[@]}

for run in $(seq 1 "$RUNS"); do
	# Rotate arm order each run to de-bias drift.
	offset=$(( (run - 1) % N_ARMS ))
	order=()
	for i in $(seq 0 $((N_ARMS - 1))); do
		order+=("${ARM_LIST[$(( (i + offset) % N_ARMS ))]}")
	done
	echo "[exp] ===== run $run/$RUNS order=${order[*]} ====="

	for arm in "${order[@]}"; do
		out="$RESULTS/$arm/run-$(printf '%02d' "$run")"
		mkdir -p "$out"
		echo "[exp] run=$run arm=$arm out=$out"
		setup_arm "$arm" "$out" >"$out/setup.log" 2>&1
		redis-cli -p "$PORT" flushall >/dev/null 2>&1 || true

		EXTRA=()
		[ "$NO_INTERFERENCE" = "1" ] && EXTRA+=(--no-interference)
		"$ROOT/bench/run_redis.sh" \
			--arm "$arm" --run-id "$run" --out "$out" \
			--server-cpus "$SERVER_CPUS" --client-cpus "$CLIENT_CPUS" \
			--interference-cpus "$INTERFERENCE_CPUS" \
			--if-cpu-workers "$IF_CPU_WORKERS" \
			--if-vm-workers "$IF_VM_WORKERS" \
			--if-vm-bytes "$IF_VM_BYTES" \
			--port "$PORT" --duration "$DURATION" --warmup "$WARMUP" \
			"${EXTRA[@]}" >"$out/run.stdout" 2>&1

		python3 - "$out" "$arm" "$run" <<'PY' >"$out/meta.json"
import json, os, sys
out, arm, run = sys.argv[1], sys.argv[2], sys.argv[3]
meta = {"arm": arm, "run": int(run), "out": out}
try:
    summary = json.load(open(os.path.join(out, "redis_summary.json")))
    meta["primary"] = summary.get("primary_data", {})
except Exception as e:
    meta["error"] = str(e)
print(json.dumps(meta, indent=2))
PY

		"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1 || true
		sleep 1
	done
done

echo "[exp] all runs done"
if [ "$SKIP_ANALYZE" = "0" ]; then
	python3 "$ROOT/bench/analyze_results.py" --results "$RESULTS" --baseline A \
		>"$RESULTS/summary_stdout.txt" 2>&1 || true
	[ -f "$RESULTS/summary.md" ] && cat "$RESULTS/summary.md"
fi
echo "[exp] results: $RESULTS"
