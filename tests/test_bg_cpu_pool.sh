#!/usr/bin/env bash
# Verify the dynamic BG CPU pool (P1, opt-in).
#
# Starts a target redis-server inside its own cgroup v2 subtree (so the test
# is independent of other redis instances on the host) plus a stress-ng (BG)
# service, brings up SchedPilot with a config that confines BG tasks to
# `bg.cpu_pool` while latency-relevant targets exist, and asserts:
#   1. stress-ng worker affinity is restricted to the pool CPUs,
#   2. removing the target releases the confinement (affinity restored),
#   3. the daemon log records both the confine and release decisions.
#
# Requires root and a built repo. The pool is applied by the daemon
# (sched_setaffinity on all BG threads); no kernel-side change is needed.
#
#   tests/test_bg_cpu_pool.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$(mktemp /tmp/bgpool-config.XXXXXX.conf)"
LOGDIR="$(mktemp -d /tmp/bgpool-logs.XXXXXX)"
PASS=0
FAIL=0
REDIS_PID=""
STRESS_PID=""
MNT_CG2=""
CG=""
RT=""

say() { echo "[bgpool-test] $*"; }
ok() {
	echo "[bgpool-test] PASS  $1"
	PASS=$((PASS + 1))
}
bad() {
	echo "[bgpool-test] FAIL  $1"
	FAIL=$((FAIL + 1))
}

cleanup() {
	"$ROOT/scripts/schedpilotctl.sh" rollback >/dev/null 2>&1 || true
	[ -n "$REDIS_PID" ] && kill "$REDIS_PID" 2>/dev/null
	[ -n "$STRESS_PID" ] && kill "$STRESS_PID" 2>/dev/null
	wait 2>/dev/null
	sleep 1
	[ -n "$RT" ] && rmdir "$RT" 2>/dev/null
	[ -n "$CG" ] && rmdir "$CG" 2>/dev/null
	if [ -n "$MNT_CG2" ]; then
		umount "$MNT_CG2" 2>/dev/null
		rmdir "$MNT_CG2" 2>/dev/null
	fi
	rm -f "$CFG"
}
trap cleanup EXIT

[ "$(id -u)" = "0" ] || {
	echo "[bgpool-test] must run as root" >&2
	exit 1
}
for f in build/scx_schedpilot build/schedpilotd scripts/schedpilotctl.sh; do
	[ -e "$ROOT/$f" ] || {
		echo "[bgpool-test] $f missing; run scripts/build.sh first" >&2
		exit 1
	}
done

# Locate a cgroup v2 tree (auto-mount on legacy v1 systems).
CG_ROOT=""
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
	CG_ROOT=/sys/fs/cgroup
elif [ -f /sys/fs/cgroup/unified/cgroup.controllers ]; then
	CG_ROOT=/sys/fs/cgroup/unified
else
	MNT_CG2=/tmp/bgpool-cgroup2.$$
	mkdir -p "$MNT_CG2"
	if mount -t cgroup2 none "$MNT_CG2" 2>/dev/null &&
		[ -f "$MNT_CG2/cgroup.controllers" ]; then
		CG_ROOT="$MNT_CG2"
	else
		echo "[bgpool-test] cgroup v2 not available (kernel support required)" >&2
		exit 1
	fi
fi
CG="$CG_ROOT/schedpilot-bgpool"
RT="$CG/svc"
mkdir -p "$RT"

cat >"$CFG" <<EOF
[targets]
process_names =
cgroup_paths = $RT
exclude_names = redis-benchmark, schedpilotd, scx_schedpilot

[bg]
process_names = stress-ng
cpu_pool = 2-3

[classifier]
alpha = 0.3
wake_hi = 500
lat_moderate = true

[policy]
adaptive = false
classify_pmu = false
llc_affinity = false
bg_contain = true
preempt = true

[log]
dir = $LOGDIR
EOF

say "starting redis-server (port 6404) inside $RT"
(
	echo "$BASHPID" >"$RT/cgroup.procs"
	exec redis-server --port 6404 --save '' --appendonly no
) >/tmp/bgpool-redis.log 2>&1 &
REDIS_PID=$!

say "starting stress-ng (BG) workers"
( exec stress-ng --cpu 2 --timeout 45s ) >/tmp/bgpool-stress.log 2>&1 &
STRESS_PID=$!
sleep 2

say "starting SchedPilot (class mode) with bg.cpu_pool=2-3"
"$ROOT/scripts/schedpilotctl.sh" start --mode class --config "$CFG" \
	>/tmp/bgpool-start.log 2>&1 || bad "schedpilotctl start failed"
sleep 8

TID="$(pgrep -x 'stress-ng-cpu' | head -n1 || pgrep -f 'stress-ng-cpu' | head -n1 || true)"
if [ -z "$TID" ]; then
	bad "no stress-ng worker found"
else
	AFF="$(taskset -pc "$TID" 2>/dev/null | awk -F': ' '{print $2}')"
	say "stress-ng tid=$TID affinity=$AFF"
	POOLED=1
	for cpu in $(printf '%s' "$AFF" | tr ',' ' '); do
		case "$cpu" in
		2 | 3) : ;;
		*) POOLED=0 ;;
		esac
	done
	if [ "$POOLED" = "1" ] && [ -n "$AFF" ]; then
		ok "BG worker confined to pool CPUs ($AFF)"
	else
		bad "BG worker affinity not confined ($AFF)"
	fi
fi

DAEMON_LOG="$ROOT/logs/schedpilotd.log"
if grep -q "bg cpu pool: confined" "$DAEMON_LOG" 2>/dev/null; then
	ok "daemon log records pool confinement"
else
	bad "no 'confined' record in daemon log"
fi

say "killing target (redis) to trigger pool release"
kill "$REDIS_PID" 2>/dev/null
REDIS_PID=""
sleep 6

if [ -n "$TID" ]; then
	AFF2="$(taskset -pc "$TID" 2>/dev/null | awk -F': ' '{print $2}')"
	say "stress-ng tid=$TID affinity after release=$AFF2"
	COUNT="$(printf '%s' "$AFF2" | python3 -c '
import sys
n = 0
for p in sys.stdin.read().strip().split(","):
    p = p.strip()
    if "-" in p:
        a, b = p.split("-")
        n += int(b) - int(a) + 1
    elif p:
        n += 1
print(n)')"
	if [ "${COUNT:-0}" -ge 4 ]; then
		ok "confinement released, affinity restored ($AFF2)"
	else
		bad "affinity not restored ($AFF2)"
	fi
fi
if grep -q "bg cpu pool: released" "$DAEMON_LOG" 2>/dev/null; then
	ok "daemon log records pool release"
else
	bad "no 'released' record in daemon log"
fi

say "NUMA reporting field check"
JSONL="$(ls -t "$LOGDIR"/schedpilotd-*.jsonl 2>/dev/null | head -n1)"
if [ -n "$JSONL" ] && grep -q 'numa_local_pct' "$JSONL"; then
	ok "JSONL samples carry NUMA locality fields"
else
	bad "no numa_local_pct field in JSONL"
fi

say "summary pass=$PASS fail=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "[bgpool-test] BG CPU POOL PASS"
	exit 0
fi
echo "[bgpool-test] BG CPU POOL FAIL"
exit 1
