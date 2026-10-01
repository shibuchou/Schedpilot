#!/usr/bin/env bash
# Fault-injection verification of SchedPilot fail-open paths.
# Must run as root on a sched_ext-enabled kernel; requires exclusive use of
# the scheduler (run when no experiment is in progress).
#
#   tests/test_fault_injection.sh [--results DIR]
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${ROOT}/results/fault-injection-${TS}"
while [ $# -gt 0 ]; do
	case "$1" in
	--results) OUT="$2"; shift 2 ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done
mkdir -p "$OUT"
PASS=0; FAIL=0
say()  { echo "[fault] $*" | tee -a "$OUT/fault.log"; }
ok()   { say "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { say "FAIL  $1"; FAIL=$((FAIL + 1)); }

state() { cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing; }
wait_state() { # $1 expected, $2 timeout_s
	local expect="$1" t="$2" i=0
	while [ "$i" -lt $((t * 10)) ]; do
		[ "$(state)" = "$expect" ] && return 0
		sleep 0.1; i=$((i + 1))
	done
	return 1
}

say "results=$OUT"

# ---- T1: loader kill -> scheduler detaches -> default fair scheduler -------
say '--- T1: kill loader -KILL, expect sched_ext disabled within 5s ---'
"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1 || true
"$ROOT/scripts/schedpilotctl.sh" start --mode basic --no-daemon >"$OUT/t1-start.log" 2>&1
if [ "$(state)" = "enabled" ]; then
	LOADER_PID="$(cat /run/schedpilot/scx_schedpilot.pid 2>/dev/null || cat /tmp/schedpilot/scx_schedpilot.pid 2>/dev/null)"
	if [ -n "$LOADER_PID" ]; then
		kill -KILL "$LOADER_PID" 2>/dev/null || true
		if wait_state disabled 5; then
			ok "loader kill -> state disabled (fair scheduler restored)"
		else
			bad "loader kill did not detach within 5s (state=$(state))"
		fi
	else
		bad "loader pidfile not found"
	fi
else
	bad "scheduler did not start (state=$(state))"
fi

# ---- T2: daemon crash -> heartbeat stale -> scheduler stays enabled --------
say '--- T2: kill daemon -KILL, expect scheduler stays enabled and heartbeat goes stale ---'
"$ROOT/scripts/schedpilotctl.sh" stop >/dev/null 2>&1 || true
"$ROOT/scripts/schedpilotctl.sh" start --mode adaptive --config "$ROOT/configs/redis.conf" \
	>"$OUT/t2-start.log" 2>&1
if [ "$(state)" = "enabled" ]; then
	DAEMON_PID="$(cat /run/schedpilot/schedpilotd.pid 2>/dev/null || cat /tmp/schedpilot/schedpilotd.pid 2>/dev/null)"
	if [ -n "$DAEMON_PID" ]; then
		kill -KILL "$DAEMON_PID" 2>/dev/null || true
		sleep 3
		if [ "$(state)" = "enabled" ]; then
			ok "daemon crash -> scheduler still enabled (BPF fail-open)"
		else
			bad "scheduler lost after daemon crash (state=$(state))"
		fi
		HB="$("$ROOT/build/schedpilotd" --status 2>/dev/null | grep -o '"heartbeat_age_s":[0-9]*' | cut -d: -f2)"
		if [ -n "$HB" ] && [ "$HB" -ge 2 ]; then
			ok "heartbeat stale after crash (age=${HB}s >= 2s timeout)"
		else
			bad "heartbeat age unexpected: ${HB:-unknown}"
		fi
		"$ROOT/scripts/schedpilotctl.sh" daemon-start --config "$ROOT/configs/redis.conf" \
			>"$OUT/t2-daemon-restart.log" 2>&1 || true
		sleep 2
		HB2="$("$ROOT/build/schedpilotd" --status 2>/dev/null | grep -o '"heartbeat_age_s":[0-9]*' | cut -d: -f2)"
		if [ -n "$HB2" ] && [ "$HB2" -le 1 ]; then
			ok "daemon restart -> heartbeat resumed (age=${HB2}s)"
		else
			bad "heartbeat did not resume: ${HB2:-unknown}"
		fi
	else
		bad "daemon pidfile not found"
	fi
else
	bad "adaptive scheduler did not start (state=$(state))"
fi

# ---- T3: rollback ----------------------------------------------------------
say '--- T3: rollback, expect disabled and no schedpilot ops ---'
"$ROOT/scripts/schedpilotctl.sh" rollback >"$OUT/t3-rollback.log" 2>&1 && \
	ok "rollback command succeeded" || bad "rollback command failed"
[ "$(state)" = "disabled" ] && ok "state disabled after rollback" || bad "state=$(state) after rollback"

say "SUMMARY pass=$PASS fail=$FAIL results=$OUT"
[ "$FAIL" -eq 0 ]
