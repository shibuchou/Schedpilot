#!/usr/bin/env bash
# Verify cgroup-based targeting end-to-end.
#
# Starts a redis-server and a stress-ng inside dedicated cgroup v2 subtrees,
# then brings up SchedPilot (BPF scheduler + daemon) with a cgroup-based
# config and asserts:
#   1. redis-server is discovered through its cgroup subtree (tracked),
#   2. stress-ng workers are discovered and labeled BG,
#   3. classification samples reach the JSONL log (redis L-SYNC / stress BG),
#   4. the BPF class map receives entries (class_map_entries > 0).
#
# A cgroup v2 tree is auto-detected; on legacy v1 systems (stock openEuler
# default layout) cgroup2 is mounted under /tmp and the config paths are
# rewritten accordingly. Requires root and a built repo.
#
#   tests/test_cgroup_targeting.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="$(mktemp -d /tmp/cgt-logs.XXXXXX)"
CFG="$(mktemp /tmp/cgt-config.XXXXXX.conf)"
PASS=0
FAIL=0
REDIS_PID=""
STRESS_PID=""
MNT_CG2=""
CG=""
RT=""
BT=""

say() { echo "[cgroup-test] $*"; }
ok() {
	echo "[cgroup-test] PASS  $1"
	PASS=$((PASS + 1))
}
bad() {
	echo "[cgroup-test] FAIL  $1"
	FAIL=$((FAIL + 1))
}

cleanup() {
	"$ROOT/scripts/schedpilotctl.sh" rollback >/dev/null 2>&1 || true
	[ -n "$REDIS_PID" ] && kill "$REDIS_PID" 2>/dev/null
	[ -n "$STRESS_PID" ] && kill "$STRESS_PID" 2>/dev/null
	wait 2>/dev/null
	sleep 1
	[ -n "$RT" ] && rmdir "$RT" 2>/dev/null
	[ -n "$BT" ] && rmdir "$BT" 2>/dev/null
	[ -n "$CG" ] && rmdir "$CG" 2>/dev/null
	if [ -n "$MNT_CG2" ]; then
		umount "$MNT_CG2" 2>/dev/null
		rmdir "$MNT_CG2" 2>/dev/null
	fi
	rm -f "$CFG"
}
trap cleanup EXIT

[ "$(id -u)" = "0" ] || {
	echo "[cgroup-test] must run as root" >&2
	exit 1
}
for f in build/scx_schedpilot build/schedpilotd scripts/schedpilotctl.sh; do
	[ -e "$ROOT/$f" ] || {
		echo "[cgroup-test] $f missing; run scripts/build.sh first" >&2
		exit 1
	}
done

# Locate a cgroup v2 tree: unified root if present, otherwise mount cgroup2
# on demand (legacy v1 systems such as stock openEuler default layout).
CG_ROOT=""
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
	CG_ROOT=/sys/fs/cgroup
elif [ -f /sys/fs/cgroup/unified/cgroup.controllers ]; then
	CG_ROOT=/sys/fs/cgroup/unified
else
	MNT_CG2=/tmp/cgt-cgroup2.$$
	mkdir -p "$MNT_CG2"
	if mount -t cgroup2 none "$MNT_CG2" 2>/dev/null &&
		[ -f "$MNT_CG2/cgroup.controllers" ]; then
		CG_ROOT="$MNT_CG2"
	else
		echo "[cgroup-test] cgroup v2 not available (kernel support required)" >&2
		exit 1
	fi
fi
say "cgroup v2 root: $CG_ROOT"

CG="$CG_ROOT/schedpilot-test"
RT="$CG/redis"
BT="$CG/stress"

# Generate a config with paths under the detected cgroup v2 root and an
# absolute log dir for this test run.
sed -e "s#/sys/fs/cgroup/schedpilot-test#$CG#g" \
	-e "s#^dir = logs#dir = $LOGDIR#" \
	"$ROOT/configs/cgroup-demo.conf" >"$CFG"

say "creating cgroups under $CG"
mkdir -p "$RT" "$BT"

say "starting redis-server (port 6401) inside $RT"
(
	echo "$BASHPID" >"$RT/cgroup.procs"
	exec redis-server --port 6401 --save '' --appendonly no
) >/tmp/cgt-redis.log 2>&1 &
REDIS_PID=$!

say "starting stress-ng inside $BT"
(
	echo "$BASHPID" >"$BT/cgroup.procs"
	exec stress-ng --cpu 2 --timeout 40s
) >/tmp/cgt-stress.log 2>&1 &
STRESS_PID=$!
sleep 2

say "starting SchedPilot (adaptive) with cgroup-based config"
if ! "$ROOT/scripts/schedpilotctl.sh" start --mode adaptive --config "$CFG" >/tmp/cgt-start.log 2>&1; then
	bad "schedpilotctl start failed (see /tmp/cgt-start.log)"
else
	st="$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing)"
	[ "$st" = "enabled" ] && ok "sched_ext state=enabled" || bad "sched_ext state=$st"
fi
sleep 10

say "asserting discovery and classification"
LOG="$(ls -t "$LOGDIR"/schedpilotd-*.jsonl 2>/dev/null | head -n1)"
if [ -n "$LOG" ] && grep -q '"comm":"redis-server"' "$LOG"; then
	ok "redis-server discovered through cgroup subtree"
else
	bad "redis-server not discovered (log=${LOG:-none})"
fi
if [ -n "$LOG" ] && grep -q '"comm":"stress-ng-cpu"' "$LOG" &&
	grep -q '"class":"BG"' "$LOG"; then
	ok "stress-ng workers discovered and classified BG"
else
	bad "stress-ng (BG) not discovered/classified"
fi
if [ -n "$LOG" ] && grep '"comm":"redis-server"' "$LOG" |
	grep -q '"class":"L-SYNC"\|"class":"M-BOUND"\|"class":"C-COMPUTE"'; then
	ok "redis-server received a classified sample (not NORMAL)"
else
	bad "no classified redis-server sample"
fi

STATUS="$(cd "$ROOT" && scripts/schedpilotctl.sh status 2>/dev/null || true)"
ENTRIES="$(printf '%s' "$STATUS" | grep -o 'class_map_entries":[0-9]*' | head -n1 | cut -d: -f2)"
if [ -n "$ENTRIES" ] && [ "$ENTRIES" -gt 0 ] 2>/dev/null; then
	ok "BPF class_map received entries ($ENTRIES)"
else
	bad "class_map_entries empty (${ENTRIES:-unknown})"
fi

say "summary pass=$PASS fail=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "[cgroup-test] CGROUP TARGETING PASS"
	exit 0
fi
echo "[cgroup-test] CGROUP TARGETING FAIL"
exit 1
