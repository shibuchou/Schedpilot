#!/usr/bin/env bash
# SchedPilot soak test: sustained Redis + interference load under the D arm,
# watching for scheduler/daemon/kernel anomalies.
#
#   tests/test_soak.sh [--duration 1800] [--cycle 60] [--results DIR]
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DURATION=1800
CYCLE=60
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${ROOT}/results/soak-${TS}"
while [ $# -gt 0 ]; do
	case "$1" in
	--duration) DURATION="$2"; shift 2 ;;
	--cycle) CYCLE="$2"; shift 2 ;;
	--results) OUT="$2"; shift 2 ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done
mkdir -p "$OUT"

state() { cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing; }
say() { echo "[soak] $*" | tee -a "$OUT/soak.log"; }

cleanup() {
	"$ROOT/bench/interference.sh" stop >/dev/null 2>&1 || true
	"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1 || true
	pgrep -f 'redis-server.*6399' | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

say "duration=${DURATION}s cycle=${CYCLE}s results=$OUT"

"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1 || true
mkdir -p /tmp/schedpilot-redis
redis-server "$ROOT/bench/redis-schedpilot.conf" --port 6399 >"$OUT/redis-server.log" 2>&1 &
REDIS_PID=$!
sleep 1
redis-cli -p 6399 ping >/dev/null 2>&1 || { say "redis failed to start"; exit 1; }

"$ROOT/scripts/schedpilotctl.sh" start --mode adaptive --config "$ROOT/configs/redis.conf" \
	>"$OUT/start.log" 2>&1
say "scheduler state=$(state)"

"$ROOT/bench/interference.sh" start --cpus 0-3 --cpu-workers 4 --vm-workers 2 --vm-bytes 1G \
	>"$OUT/interference.log" 2>&1

END=$(( $(date +%s) + DURATION ))
CYCLES=0
ERRORS=0
WATCHDOG=0
# Only scan kernel messages produced after the soak started, and only the
# genuine failure signatures (never the normal enabled/unregistered lines).
DMESG_START="$(dmesg 2>/dev/null | wc -l)"
while [ "$(date +%s)" -lt "$END" ]; do
	CYCLES=$((CYCLES + 1))
	say "cycle $CYCLES $(date -Is)"
	if ! redis-benchmark -h 127.0.0.1 -p 6399 -t get -c 50 -n 1000000 -q >/dev/null 2>&1; then
		ERRORS=$((ERRORS + 1))
		say "ANOMALY redis-benchmark failed"
	fi
	# anomaly checks
	st="$(state)"
	if [ "$st" != "enabled" ]; then
		ERRORS=$((ERRORS + 1))
		say "ANOMALY state=$st"
	fi
	if ! pgrep -x schedpilotd >/dev/null 2>&1; then
		ERRORS=$((ERRORS + 1))
		say "ANOMALY daemon not running"
	fi
	NEW_DMESG="$(dmesg 2>/dev/null | tail -n +$((DMESG_START + 1)))"
	HIT="$(printf '%s\n' "$NEW_DMESG" | grep -aiE 'sched_ext:.*(watchdog|stall)|BUG: |Oops' | tail -n 1)"
	if [ -n "$HIT" ]; then
		WATCHDOG=$((WATCHDOG + 1))
		say "ANOMALY kernel log: $HIT"
	fi
	"$ROOT/build/scx_schedpilot" --stats >"$OUT/stats-cycle-${CYCLES}.txt" 2>&1 || true
done

say "cycles=$CYCLES errors=$ERRORS watchdog_hits=$WATCHDOG"
say "final state=$(state)"
"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1 || true
POST_STATE="$(state)"
say "post-stop state=$POST_STATE"
if [ "$ERRORS" -eq 0 ] && [ "$WATCHDOG" -eq 0 ] && [ "$POST_STATE" = "disabled" ]; then
	say "SOAK PASS"
	exit 0
fi
say "SOAK FAIL (errors=$ERRORS watchdog=$WATCHDOG post_state=$POST_STATE)"
exit 1
