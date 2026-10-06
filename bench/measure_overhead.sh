#!/usr/bin/env bash
# Scheduler overhead accounting (P1).
#
# During one fixed window (default 20s) under the Redis mixed co-location
# scenario with the *currently loaded* scheduler, measures and attributes:
#   - daemon CPU time           (perf stat on schedpilotd)
#   - BPF program runtime/calls (bpftool prog show run_time_ns/run_cnt deltas)
#   - dispatch-call rate        (BPF stats map, build/scx_schedpilot --stats)
#   - per-request cost vs redis-benchmark throughput
#
# Prereqs: SchedPilot running (pinned maps), redis-server on --port,
# redis-benchmark, perf, bpftool, stress-ng.
#
#   bench/measure_overhead.sh [--duration 20] [--port 6399] [--no-interference]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DURATION=20
PORT=6399
WITH_IF=1
SERVER_CPUS=0-3
CLIENT_CPUS=4-7

while [ $# -gt 0 ]; do
	case "$1" in
	--duration) DURATION="$2"; shift 2 ;;
	--port) PORT="$2"; shift 2 ;;
	--no-interference) WITH_IF=0; shift ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/results/overhead-$TS"
mkdir -p "$OUT"

DAEMON_PID="$(pgrep -f 'build/schedpilotd' | head -n1 || true)"
[ -n "$DAEMON_PID" ] || {
	echo "[FAIL] schedpilotd not running (start SchedPilot first)" >&2
	exit 1
}
REDIS_PID="$(pgrep -f "redis-server .*:$PORT" | head -n1 || true)"
[ -n "$REDIS_PID" ] || REDIS_PID="$(pgrep -x redis-server | head -n1 || true)"
[ -n "$REDIS_PID" ] || {
	echo "[FAIL] redis-server not running on port $PORT" >&2
	exit 1
}
command -v perf >/dev/null || {
	echo "[FAIL] perf not installed" >&2
	exit 1
}

bpf_snapshot() {
	bpftool prog show -j 2>/dev/null | python3 -c '
import sys, json
try:
    progs = json.load(sys.stdin)
except Exception:
    print("0 0"); raise SystemExit
rt = cnt = 0
for p in progs:
    name = (p.get("name") or "")
    if "schedpilot" in name or "scx" in name:
        rt += p.get("run_time_ns", 0) or 0
        cnt += p.get("run_cnt", 0) or 0
print(rt, cnt)
'
}

stats_dispatch() {
	"$ROOT/build/scx_schedpilot" --stats 2>/dev/null |
		grep -o 'dispatch_calls=[0-9]*' | head -n1 | cut -d= -f2
}

echo "[overhead] daemon=$DAEMON_PID redis=$REDIS_PID duration=${DURATION}s interference=$WITH_IF"
if [ "$WITH_IF" = "1" ]; then
	"$ROOT/bench/interference.sh" start --cpus "$SERVER_CPUS" \
		--cpu-workers 4 --vm-workers 2 --vm-bytes 1G >/dev/null || true
	sleep 2
fi

echo "[overhead] warmup 5s"
timeout 5 redis-benchmark -h 127.0.0.1 -p "$PORT" -t get -c 50 \
	-n 100000000 -q >/dev/null 2>&1 || true

RATE="$(redis-benchmark -h 127.0.0.1 -p "$PORT" -t get -c 50 -n 100000 -q 2>/dev/null |
	grep -oE '[0-9]+(\.[0-9]+)? requests per second' | head -n1 | awk '{print $1}')"
[ -n "$RATE" ] || RATE=20000
TOTAL="$(python3 -c "r=float('$RATE'); d=float('$DURATION'); print(max(50000, int(round(r*d/1000.0))*1000))")"
echo "[overhead] estimated rate=$RATE rps total=$TOTAL requests"

BPF_BEFORE="$(bpf_snapshot)"
DISP_BEFORE="$(stats_dispatch)"
perf stat -p "$DAEMON_PID" -e task-clock -o "$OUT/daemon_perf.txt" \
	-- sleep "$DURATION" >/dev/null 2>&1 &
PERF_PID=$!

taskset -c "$CLIENT_CPUS" redis-benchmark -h 127.0.0.1 -p "$PORT" -t get \
	-c 50 -n "$TOTAL" --precision 3 >"$OUT/redis.out" 2>&1 || true
wait "$PERF_PID" 2>/dev/null || true

BPF_AFTER="$(bpf_snapshot)"
DISP_AFTER="$(stats_dispatch)"
if [ "$WITH_IF" = "1" ]; then
	"$ROOT/bench/interference.sh" stop >/dev/null || true
fi

python3 - "$OUT" "$DURATION" "$BPF_BEFORE" "$BPF_AFTER" "$DISP_BEFORE" "$DISP_AFTER" <<'PY'
import os, re, sys
out, dur = sys.argv[1], float(sys.argv[2])
b0 = tuple(int(x) for x in sys.argv[3].split())
b1 = tuple(int(x) for x in sys.argv[4].split())
d0 = sys.argv[5] or "0"
d1 = sys.argv[6] or "0"
try:
    disp = int(d1) - int(d0)
except ValueError:
    disp = None

txt = open(os.path.join(out, "redis.out"), errors="replace").read()
m = re.search(r"([\d.]+) requests completed in ([\d.]+) seconds", txt)
qps = float(m.group(1)) / float(m.group(2)) if m else float("nan")
reqs = float(m.group(1)) if m else float("nan")

dcpu_ms = float("nan")
for line in open(os.path.join(out, "daemon_perf.txt"), errors="replace"):
    mm = re.match(r"\s*([\d,]+\.?\d*)\s+msec task-clock", line)
    if mm:
        dcpu_ms = float(mm.group(1).replace(",", ""))

bpf_ns = max(0, b1[0] - b0[0])
bpf_calls = max(0, b1[1] - b0[1])
lines = []
lines.append("# Scheduler overhead measurement\n")
lines.append(f"- window: {dur:.0f}s; redis-benchmark: {reqs:.0f} requests, {qps:.0f} QPS")
lines.append(f"- schedpilotd CPU: {dcpu_ms:.1f} ms ({100*dcpu_ms/1000.0/dur:.3f}% of one CPU)")
if bpf_calls > 0:
    lines.append(f"- BPF prog runtime: {bpf_ns/1e6:.1f} ms ({100*bpf_ns/1e9/dur:.3f}% of one CPU), "
                 f"calls: {bpf_calls}, avg: {bpf_ns/max(1,bpf_calls):.0f} ns/call")
else:
    lines.append("- BPF prog runtime: not exposed for struct_ops callbacks on this kernel "
                 "(bpftool reports no run_time_ns); kernel-side scheduler cost is therefore "
                 "reported only via the dispatch-call rate below")
if disp is not None:
    lines.append(f"- dispatch calls: {disp} (~{disp/dur:.0f}/s)")
lines.append("\n| per request | ns |\n|---|---|")
if reqs and reqs > 0:
    if dcpu_ms == dcpu_ms:
        lines.append(f"| daemon CPU | {dcpu_ms*1e6/reqs:.1f} |")
    if bpf_calls > 0:
        lines.append(f"| BPF prog runtime | {bpf_ns/reqs:.1f} |")
    if disp is not None:
        lines.append(f"| dispatches | {disp/reqs:.3f} |")
md = "\n".join(lines) + "\n"
open(os.path.join(out, "summary.md"), "w").write(md)
print(md)
PY
echo "[overhead] results: $OUT"
