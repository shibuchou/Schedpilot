#!/usr/bin/env bash
# Background interference control for the Redis co-location scenario.
#
#   interference.sh start --cpus 0-3 [--cpu-workers 2] [--vm-workers 1] [--vm-bytes 1G]
#   interference.sh stop
#   interference.sh status
set -u

RUN_DIR="${SP_RUN_DIR:-/run/schedpilot}"
[ -w /run ] 2>/dev/null || RUN_DIR="/tmp/schedpilot"
PID_FILE="$RUN_DIR/interference.pid"

is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

cmd_start() {
	CPUS=""; CPU_WORKERS=2; VM_WORKERS=1; VM_BYTES="1G"
	while [ $# -gt 0 ]; do
		case "$1" in
		--cpus) CPUS="$2"; shift 2 ;;
		--cpu-workers) CPU_WORKERS="$2"; shift 2 ;;
		--vm-workers) VM_WORKERS="$2"; shift 2 ;;
		--vm-bytes) VM_BYTES="$2"; shift 2 ;;
		*) echo "unknown arg: $1" >&2; exit 1 ;;
		esac
	done
	[ -n "$CPUS" ] || { echo "[FAIL] --cpus required" >&2; exit 1; }
	command -v stress-ng >/dev/null || { echo "[FAIL] stress-ng not installed" >&2; exit 1; }
	mkdir -p "$RUN_DIR"
	if is_running; then
		echo "[schedpilot] interference already running pid=$(cat "$PID_FILE")"
		return 0
	fi
	taskset -c "$CPUS" stress-ng --cpu "$CPU_WORKERS" --cpu-method matrixprod \
		--vm "$VM_WORKERS" --vm-bytes "$VM_BYTES" --vm-keep \
		--timeout 0 --metrics-brief >/dev/null 2>&1 &
	echo $! >"$PID_FILE"
	sleep 1
	if ! is_running; then
		echo "[FAIL] interference exited immediately (stress-ng failed to start)" >&2
		rm -f "$PID_FILE"
		return 1
	fi
	echo "[schedpilot] interference started pid=$(cat "$PID_FILE") cpus=$CPUS cpu_workers=$CPU_WORKERS vm_workers=$VM_WORKERS"
}

cmd_stop() {
	if is_running; then
		pid="$(cat "$PID_FILE")"
		pkill -TERM -P "$pid" 2>/dev/null || true
		kill -TERM "$pid" 2>/dev/null || true
		sleep 0.5
		pkill -KILL -P "$pid" 2>/dev/null || true
		kill -KILL "$pid" 2>/dev/null || true
		echo "[schedpilot] interference stopped pid=$pid"
	else
		echo "[schedpilot] interference not running"
	fi
	rm -f "$PID_FILE"
}

case "${1:-status}" in
start) shift; cmd_start "$@" ;;
stop) cmd_stop ;;
status) is_running && echo "running pid=$(cat "$PID_FILE")" || echo "not running" ;;
*) echo "usage: $0 {start|stop|status}" >&2; exit 1 ;;
esac
