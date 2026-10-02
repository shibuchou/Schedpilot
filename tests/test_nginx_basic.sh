#!/usr/bin/env bash
# Regression test for the recommended Nginx deployment entry:
# deploy exactly the measured configuration (scripts/deploy_nginx.sh, basic
# mode) with the documented command, run a short mixed load and verify the
# scheduler stayed healthy, then roll back.
#
# Must run as root on a sched_ext-enabled machine with nginx + wrk installed.
#   tests/test_nginx_basic.sh [--load-seconds 10]
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECONDS_LOAD=10
while [ $# -gt 0 ]; do
	case "$1" in
	--load-seconds) SECONDS_LOAD="$2"; shift 2 ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/results/nginx-basic-${TS}"
mkdir -p "$OUT"
PASS=0
FAIL=0
say() { echo "[nginx-basic] $*" | tee -a "$OUT/test.log"; }
ok() { say "PASS $1"; PASS=$((PASS + 1)); }
bad() { say "FAIL $1"; FAIL=$((FAIL + 1)); }
state() { cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing; }

cleanup() {
	"$ROOT/bench/interference.sh" stop >/dev/null 2>&1 || true
	nginx -s stop -c "$ROOT/bench/nginx-schedpilot.conf" >/dev/null 2>&1 || true
	"$ROOT/scripts/schedpilotctl.sh" rollback >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

say "results=$OUT"
for t in nginx wrk; do
	command -v "$t" >/dev/null 2>&1 || { bad "$t not installed"; say "SUMMARY pass=$PASS fail=$FAIL"; exit 1; }
done

DMESG_START="$(dmesg 2>/dev/null | wc -l)"

# 1) deploy with the documented entry (same command as measured basic mode)
if "$ROOT/scripts/deploy_nginx.sh" >>"$OUT/deploy.log" 2>&1; then
	ok "deploy_nginx.sh (basic mode) succeeded"
else
	bad "deploy_nginx.sh failed (see $OUT/deploy.log)"
fi
[ "$(state)" = "enabled" ] && ok "sched_ext enabled after deploy" || bad "state=$(state) after deploy"
SEQ_BEFORE="$(cat /sys/kernel/sched_ext/enable_seq 2>/dev/null || echo -1)"

# 2) short mixed load with nginx + interference + isolated client
mkdir -p /tmp/schedpilot-www
echo "schedpilot-nginx-benchmark-payload-0123456789" >/tmp/schedpilot-www/index.html
nginx -c "$ROOT/bench/nginx-schedpilot.conf" || bad "nginx failed to start"
sleep 1
for p in $(pgrep -x nginx); do taskset -pc 0-3 "$p" >/dev/null 2>&1 || true; done
"$ROOT/bench/interference.sh" start --cpus 0-3 --cpu-workers 4 --vm-workers 2 --vm-bytes 1G \
	>>"$OUT/interference.log" 2>&1 || true
sleep 2
taskset -c 4-7 wrk -t2 -c50 -d "${SECONDS_LOAD}s" --latency http://127.0.0.1:8080/ \
	>"$OUT/wrk.out" 2>&1 || bad "wrk load failed"
grep -q 'Requests/sec' "$OUT/wrk.out" && ok "wrk produced results" || bad "no Requests/sec in wrk output"
"$ROOT/bench/interference.sh" stop >/dev/null 2>&1 || true

# 3) scheduler must have stayed healthy during the load
SEQ_AFTER="$(cat /sys/kernel/sched_ext/enable_seq 2>/dev/null || echo -1)"
[ "$(state)" = "enabled" ] && ok "scheduler still enabled after load" || bad "state=$(state) after load"
[ "$SEQ_AFTER" = "$SEQ_BEFORE" ] && ok "no scheduler re-enable during load" || bad "enable_seq changed ${SEQ_BEFORE}->${SEQ_AFTER}"
NEW_DMESG="$(dmesg 2>/dev/null | tail -n +$((DMESG_START + 1)))"
HIT="$(printf '%s\n' "$NEW_DMESG" | grep -aiE 'sched_ext:.*(watchdog|stall)' | tail -n 1)"
[ -z "$HIT" ] && ok "no watchdog/stall events" || bad "kernel log: $HIT"

# 4) rollback
"$ROOT/scripts/schedpilotctl.sh" rollback >/dev/null 2>&1 || true
[ "$(state)" = "disabled" ] && ok "rollback restores default fair scheduler" || bad "state=$(state) after rollback"

say "SUMMARY pass=$PASS fail=$FAIL results=$OUT"
[ "$FAIL" -eq 0 ]
