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
PORT=""
NO_INTERFERENCE=0
SKIP_ANALYZE=0
CONFIG=""
WORKLOAD="redis"
IF_CPU_WORKERS=4
IF_VM_WORKERS=2
IF_VM_BYTES="1G"
MYSQL_CNF="${MYSQL_CNF:-/etc/schedpilot-mysql.cnf}"
FAIL_FAST=1
INVALID_RUNS=0

while [ $# -gt 0 ]; do
	case "$1" in
	--workload) WORKLOAD="$2"; shift 2 ;;
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
	--continue-on-error) FAIL_FAST=0; shift ;;
	-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

# Per-workload defaults (redis | nginx | mysql)
case "$WORKLOAD" in
nginx)
	[ -n "$PORT" ] || PORT=8080
	[ -n "$CONFIG" ] || CONFIG="$ROOT/configs/nginx.conf"
	;;
mysql)
	[ -n "$PORT" ] || PORT=3307
	[ -n "$CONFIG" ] || CONFIG="$ROOT/configs/mysql.conf"
	;;
*)
	WORKLOAD=redis
	[ -n "$PORT" ] || PORT=6399
	[ -n "$CONFIG" ] || CONFIG="$ROOT/configs/redis.conf"
	;;
esac

[ -n "$RESULTS" ] || RESULTS="$ROOT/results/$(hostname)-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS"
echo "[exp] results=$RESULTS workload=$WORKLOAD port=$PORT runs=$RUNS duration=${DURATION}s warmup=${WARMUP}s arms=$ARMS"

# ---------- environment + workload server ----------
"$ROOT/scripts/env_check.sh" --label "$(basename "$RESULTS")" \
	--json "$RESULTS/env_check.json" >"$RESULTS/env_check.log" 2>&1 || true

SERVER_PID=""
EXT_PID=""
case "$WORKLOAD" in
redis)
	mkdir -p /tmp/schedpilot-redis
	# If a redis-server already listens on $PORT (e.g. left over from a
	# manual start), adopt it and re-pin all of its threads to SERVER_CPUS
	# instead of starting a second instance that cannot bind and silently
	# leaves the unpinned one in place. Otherwise start a fresh pinned one.
	SERVER_OWNED=0
	EXISTING_PID="$(ss -ltnpH "sport = :$PORT" 2>/dev/null |
		grep -o 'pid=[0-9]*' | head -n1 | cut -d= -f2)"
	if [ -z "$EXISTING_PID" ]; then
		EXISTING_PID="$(pgrep -f "redis-server.*--port $PORT" | head -n1 || true)"
	fi
	if [ -n "$EXISTING_PID" ]; then
		SERVER_PID="$EXISTING_PID"
		for p in $(pgrep -x redis-server); do
			taskset -apc "$SERVER_CPUS" "$p" >/dev/null 2>&1 || true
		done
	else
		taskset -c "$SERVER_CPUS" redis-server "$ROOT/bench/redis-schedpilot.conf" \
			--port "$PORT" >"$RESULTS/redis-server.log" 2>&1 &
		SERVER_PID=$!
		SERVER_OWNED=1
	fi
	for _ in $(seq 1 30); do
		redis-cli -p "$PORT" ping >/dev/null 2>&1 && break
		sleep 0.5
	done
	redis-cli -p "$PORT" ping >/dev/null 2>&1 || { echo "[FAIL] redis-server did not start" >&2; exit 1; }
	;;
nginx)
	mkdir -p /tmp/schedpilot-www
	echo "schedpilot-nginx-benchmark-payload-0123456789" >/tmp/schedpilot-www/index.html
	nginx -c "$ROOT/bench/nginx-schedpilot.conf" 2>"$RESULTS/nginx-start.log" || {
		echo "[FAIL] nginx did not start" >&2; exit 1; }
	SERVER_PID="$(pgrep -f 'nginx: master process' | head -n1 || true)"
	for _ in $(seq 1 30); do
		curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
		sleep 0.5
	done
	# Scenario v3: server and interference share the same CPU set
	# (co-location); the benchmark client stays isolated on CLIENT_CPUS.
	for p in $(pgrep -x nginx); do
		taskset -pc "$SERVER_CPUS" "$p" >/dev/null 2>&1 || true
	done
	;;
mysql)
	pgrep -x mysqld >/dev/null 2>&1 || mysqld --defaults-file="$MYSQL_CNF" --daemonize 2>"$RESULTS/mysql-start.log"
	SERVER_PID="$(pgrep -x mysqld | head -n1 || true)"
	for _ in $(seq 1 30); do
		mysqladmin --defaults-file="$MYSQL_CNF" ping >/dev/null 2>&1 && break
		sleep 0.5
	done
	mysqladmin --defaults-file="$MYSQL_CNF" ping >/dev/null 2>&1 || {
		echo "[FAIL] mysqld did not start" >&2; exit 1; }
	# Scenario v3: mysqld threads co-located with interference on SERVER_CPUS.
	[ -n "$SERVER_PID" ] && taskset -apc "$SERVER_CPUS" "$SERVER_PID" >/dev/null 2>&1 || true
	;;
esac
echo "[exp] workload=$WORKLOAD server_pid=${SERVER_PID:-none} port=$PORT"

cleanup() {
	echo "[exp] cleanup"
	"$ROOT/bench/interference.sh" stop >/dev/null 2>&1 || true
	"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1 || true
	[ -n "${EXT_PID:-}" ] && kill "$EXT_PID" 2>/dev/null || true
	case "$WORKLOAD" in
	redis) [ "${SERVER_OWNED:-0}" = "1" ] && [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true ;;
	nginx) nginx -s stop -c "$ROOT/bench/nginx-schedpilot.conf" >/dev/null 2>&1 || true ;;
	mysql) mysqladmin --defaults-file="$MYSQL_CNF" shutdown >/dev/null 2>&1 || true ;;
	esac
}
trap cleanup EXIT INT TERM

# ---------- experiment metadata (kernel / commit / binary hashes) ----------
KERNEL_REL="$(uname -r)"
SHA_LOADER="$(sha256sum "$ROOT/build/scx_schedpilot" 2>/dev/null | awk '{print $1}')"
SHA_DAEMON="$(sha256sum "$ROOT/build/schedpilotd" 2>/dev/null | awk '{print $1}')"
SHA_BPF="$(sha256sum "$ROOT/build/scx-tools/build/obj/sched_ext/scx_schedpilot.bpf.o" 2>/dev/null | awk '{print $1}')"
[ -n "$SHA_BPF" ] || SHA_BPF="$(sha256sum "$ROOT/build/scx_schedpilot.bpf.o" 2>/dev/null | awk '{print $1}')"

cat >"$RESULTS/experiment.meta.json" <<EOF
{
  "started": "$(date -Is)",
  "host": "$(hostname)",
  "scenario": "v3 (service + interference share SERVER_CPUS; client isolated)",
  "kernel": "$KERNEL_REL",
  "workload": "$WORKLOAD",
  "port": $PORT,
  "config": "$CONFIG",
  "runs": $RUNS,
  "duration_s": $DURATION,
  "warmup_s": $WARMUP,
  "arms": "$ARMS",
  "fail_fast": $FAIL_FAST,
  "server_cpus": "$SERVER_CPUS",
  "client_cpus": "$CLIENT_CPUS",
  "interference_cpus": "$INTERFERENCE_CPUS",
  "interference": $([ "$NO_INTERFERENCE" = "1" ] && echo false || echo true),
  "interference_cpu_workers": $IF_CPU_WORKERS,
  "interference_vm_workers": $IF_VM_WORKERS,
  "interference_vm_bytes": "$IF_VM_BYTES",
  "baseline_note": "Baseline is the openEuler default fair-class scheduler (competition text: default CFS); Linux 6.6 fair-class internals are not assumed identical to mainline classic CFS.",
  "git_commit": "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)",
  "binaries": {
    "scx_schedpilot_sha256": "$SHA_LOADER",
    "schedpilotd_sha256": "$SHA_DAEMON",
    "bpf_object_sha256": "$SHA_BPF"
  }
}
EOF

setup_arm() {
	local arm="$1" out="$2"
	EXT_PID=""
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
	d-no-preempt)
		"$ROOT/scripts/schedpilotctl.sh" start --mode adaptive --config "$CONFIG" --policy on --log-dir "$out/logs" --ablation preempt=0
		;;
	X-simple|X-flatcg)
		"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1
		local extbin="$ROOT/build/external/$arm"
		[ -x "$extbin" ] || { echo "[FAIL] external scheduler missing: $extbin" >&2; exit 1; }
		nohup "$extbin" >"$out/external.log" 2>&1 &
		EXT_PID=$!
		;;
	*)
		echo "[FAIL] unknown arm: $arm" >&2; exit 1
		;;
	esac
	sleep 2

	# Scheduler state validation: a broken arm must never produce data.
	local st ops
	st="$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing)"
	ops="$(ls /sys/kernel/sched_ext/*/ops 2>/dev/null | xargs -r -n1 cat 2>/dev/null | tr '\n' ' ')"
	if [ "$arm" = "A" ]; then
		case "$ops" in
		*schedpilot*) echo "[FAIL] arm A: schedpilot still registered (ops=$ops)" >&2; return 1 ;;
		esac
	else
		[ "$st" = "enabled" ] || { echo "[FAIL] arm $arm: sched_ext state=$st" >&2; return 1; }
		case "$arm" in
		X-*) : ;;
		*) case "$ops" in
		   *schedpilot*) : ;;
		   *) echo "[FAIL] arm $arm: unexpected ops=$ops" >&2; return 1 ;;
		   esac ;;
		esac
	fi
	return 0
}

# Mark a run as invalid (contaminated / setup failure) and optionally abort.
invalid() {
	local arm="$1" out="$2" reason="$3"
	INVALID_RUNS=$((INVALID_RUNS + 1))
	echo "$reason" >"$out/INVALID"
	echo "$(date -Is) arm=$arm run=$run reason=$reason" >>"$RESULTS/invalid.log"
	echo "[FAIL] invalid run: arm=$arm reason=$reason"
	if [ "$FAIL_FAST" = "1" ]; then
		echo "[exp] fail-fast enabled: aborting"
		exit 1
	fi
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
		if ! setup_arm "$arm" "$out" >"$out/setup.log" 2>&1; then
			invalid "$arm" "$out" "arm setup validation failed"
			continue
		fi
		SEQ_BEFORE="$(cat /sys/kernel/sched_ext/enable_seq 2>/dev/null || echo -1)"
		if [ "$WORKLOAD" = "redis" ]; then
			redis-cli -p "$PORT" flushall >/dev/null 2>&1 || true
		fi

		EXTRA=()
		[ "$NO_INTERFERENCE" = "1" ] && EXTRA+=(--no-interference)
		RUN_RC=0
		"$ROOT/bench/run_${WORKLOAD}.sh" \
			--arm "$arm" --run-id "$run" --out "$out" \
			--server-cpus "$SERVER_CPUS" --client-cpus "$CLIENT_CPUS" \
			--interference-cpus "$INTERFERENCE_CPUS" \
			--if-cpu-workers "$IF_CPU_WORKERS" \
			--if-vm-workers "$IF_VM_WORKERS" \
			--if-vm-bytes "$IF_VM_BYTES" \
			--port "$PORT" --duration "$DURATION" --warmup "$WARMUP" \
			"${EXTRA[@]}" >"$out/run.stdout" 2>&1 || RUN_RC=$?

		# Post-run contamination check: scheduler must still be the one we
		# started (no watchdog abort / fallback to fair mid-measurement).
		ST_AFTER="$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing)"
		SEQ_AFTER="$(cat /sys/kernel/sched_ext/enable_seq 2>/dev/null || echo -1)"
		INVALID_REASON=""
		if [ "$RUN_RC" != "0" ]; then
			INVALID_REASON="run script failed rc=$RUN_RC (setup/interference gate)"
		elif [ "$arm" != "A" ] && { [ "$ST_AFTER" != "enabled" ] || [ "$SEQ_AFTER" != "$SEQ_BEFORE" ]; }; then
			INVALID_REASON="contaminated: state=$ST_AFTER enable_seq ${SEQ_BEFORE}->${SEQ_AFTER}"
		fi

		if [ -n "${EXT_PID:-}" ]; then
			kill "$EXT_PID" 2>/dev/null || true
			EXT_PID=""
		fi

		python3 - "$out" "$arm" "$run" "$INVALID_REASON" <<'PY' >"$out/meta.json"
import json, os, sys
out, arm, run, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
meta = {"arm": arm, "run": int(run), "out": out,
        "invalid": bool(reason), "invalid_reason": reason}
for name in ("summary.json", "redis_summary.json"):
    path = os.path.join(out, name)
    if os.path.exists(path):
        try:
            summary = json.load(open(path))
            meta["primary"] = summary.get("primary_data", {})
        except Exception as e:
            meta["error"] = str(e)
        break
print(json.dumps(meta, indent=2))
PY

		if [ -n "$INVALID_REASON" ]; then
			invalid "$arm" "$out" "$INVALID_REASON"
		fi

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
if [ "$INVALID_RUNS" -gt 0 ]; then
	echo "[FAIL] $INVALID_RUNS invalid run(s); see $RESULTS/invalid.log"
	exit 1
fi
