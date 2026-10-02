#!/usr/bin/env bash
# SchedPilot lifecycle control: scheduler loader + control daemon.
#
#   schedpilotctl.sh start [--mode basic|class|adaptive] [--config FILE] [--no-daemon]
#   schedpilotctl.sh stop          # stop daemon + loader, fall back to fair scheduler
#   schedpilotctl.sh status
#   schedpilotctl.sh rollback      # safe: stop everything and verify sched_ext state
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${SP_RUN_DIR:-/run/schedpilot}"
[ -w /run ] 2>/dev/null || RUN_DIR="/tmp/schedpilot"
LOADER_PID="$RUN_DIR/scx_schedpilot.pid"
DAEMON_PID="$RUN_DIR/schedpilotd.pid"
LOG_DIR="${SP_LOG_DIR:-$ROOT/logs}"
MODE="adaptive"
CONFIG="$ROOT/configs/redis.conf"
WITH_DAEMON=1
DAEMON_EXTRA=()

loader_bin() {
	if [ -x "$ROOT/build/scx_schedpilot" ]; then echo "$ROOT/build/scx_schedpilot"; else echo "/usr/local/bin/scx_schedpilot"; fi
}
daemon_bin() {
	if [ -x "$ROOT/build/schedpilotd" ]; then echo "$ROOT/build/schedpilotd"; else echo ""; fi
}

is_running() { local f="$1"; [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; }

cmd_start() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--mode) MODE="$2"; shift 2 ;;
		--config) CONFIG="$2"; shift 2 ;;
		--no-daemon) WITH_DAEMON=0; shift ;;
		--policy) DAEMON_EXTRA+=("--policy" "$2"); shift 2 ;;
		--log-dir) DAEMON_EXTRA+=("--log-dir" "$2"); shift 2 ;;
		--ablation) DAEMON_EXTRA+=("--ablation" "$2"); shift 2 ;;
		--daemon-arg) DAEMON_EXTRA+=("$2"); shift 2 ;;
		*) echo "unknown arg: $1" >&2; exit 1 ;;
		esac
	done
	mkdir -p "$RUN_DIR" "$LOG_DIR"

	if is_running "$LOADER_PID"; then
		echo "[schedpilot] loader already running pid=$(cat "$LOADER_PID")"
	else
		echo "[schedpilot] starting scx_schedpilot --mode $MODE"
		nohup "$(loader_bin)" --mode "$MODE" >>"$LOG_DIR/scx_schedpilot.log" 2>&1 &
		echo $! >"$LOADER_PID"
		sleep 1
	fi

	st="$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing)"
	ops="$(ls /sys/kernel/sched_ext/*/ops 2>/dev/null | xargs -r -n1 cat 2>/dev/null | tr '\n' ' ')"
	echo "[schedpilot] sched_ext state=$st ops=$ops"
	case "$st" in
	enabled) ;;
	*) echo "[FAIL] scheduler did not become active" >&2; exit 1 ;;
	esac

	if [ "$WITH_DAEMON" = "1" ]; then
		if is_running "$DAEMON_PID"; then
			echo "[schedpilot] daemon already running pid=$(cat "$DAEMON_PID")"
		else
			BIN="$(daemon_bin)"
			[ -n "$BIN" ] || { echo "[FAIL] schedpilotd not built (run scripts/build.sh)" >&2; exit 1; }
			echo "[schedpilot] starting schedpilotd --config $CONFIG"
			nohup "$BIN" --config "$CONFIG" "${DAEMON_EXTRA[@]}" >>"$LOG_DIR/schedpilotd.log" 2>&1 &
			echo $! >"$DAEMON_PID"
			sleep 0.5
		fi
	fi
	echo "[schedpilot] started (mode=$MODE)"
}

cmd_daemon_start() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--config) CONFIG="$2"; shift 2 ;;
		--policy) DAEMON_EXTRA+=("--policy" "$2"); shift 2 ;;
		--log-dir) DAEMON_EXTRA+=("--log-dir" "$2"); shift 2 ;;
		--ablation) DAEMON_EXTRA+=("--ablation" "$2"); shift 2 ;;
		*) echo "unknown arg: $1" >&2; exit 1 ;;
		esac
	done
	mkdir -p "$RUN_DIR" "$LOG_DIR"
	BIN="$(daemon_bin)"
	[ -n "$BIN" ] || { echo "[FAIL] schedpilotd not built" >&2; exit 1; }
	if is_running "$DAEMON_PID"; then
		echo "daemon already running pid=$(cat "$DAEMON_PID")"; return 0
	fi
	nohup "$BIN" --config "$CONFIG" "${DAEMON_EXTRA[@]}" >>"$LOG_DIR/schedpilotd.log" 2>&1 &
	echo $! >"$DAEMON_PID"
	echo "[schedpilot] daemon started pid=$(cat "$DAEMON_PID")"
}

cmd_stop() {
	if is_running "$DAEMON_PID"; then
		pid="$(cat "$DAEMON_PID")"
		echo "[schedpilot] stopping daemon pid=$pid"
		kill "$pid" 2>/dev/null || true
		for _ in $(seq 1 30); do is_running "$DAEMON_PID" || break; sleep 0.1; done
		is_running "$DAEMON_PID" && kill -9 "$pid" 2>/dev/null || true
	fi
	rm -f "$DAEMON_PID"

	if is_running "$LOADER_PID"; then
		pid="$(cat "$LOADER_PID")"
		echo "[schedpilot] stopping loader pid=$pid (control detaches -> fair scheduler)"
		kill -TERM "$pid" 2>/dev/null || true
		for _ in $(seq 1 50); do is_running "$LOADER_PID" || break; sleep 0.1; done
		is_running "$LOADER_PID" && kill -KILL "$pid" 2>/dev/null || true
	fi
	rm -f "$LOADER_PID"

	sleep 0.3
	cmd_status || true
}

cmd_status() {
	local loader_pid="none" daemon_pid="none"
	is_running "$LOADER_PID" && loader_pid="$(cat "$LOADER_PID")"
	is_running "$DAEMON_PID" && daemon_pid="$(cat "$DAEMON_PID")"
	echo "loader_pid=$loader_pid daemon_pid=$daemon_pid"
	if [ -d /sys/kernel/sched_ext ]; then
		echo "sched_ext.state=$(cat /sys/kernel/sched_ext/state 2>/dev/null)"
		echo "sched_ext.ops=$(ls /sys/kernel/sched_ext/*/ops 2>/dev/null | xargs -r -n1 cat 2>/dev/null | tr '\n' ' ')"
	fi
	[ -x "$ROOT/build/scx_schedpilot" ] && "$ROOT/build/scx_schedpilot" --status
	if [ -x "$ROOT/build/schedpilotd" ]; then
		"$ROOT/build/schedpilotd" --status 2>/dev/null || echo "schedpilotd.status=unavailable"
	fi
}

cmd_rollback() {
	echo "[schedpilot] rollback: stopping daemon + loader"
	cmd_stop
	st="$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing)"
	if [ "$st" = "enabled" ]; then
		ops="$(ls /sys/kernel/sched_ext/*/ops 2>/dev/null | xargs -r -n1 cat 2>/dev/null | tr '\n' ' ')"
		if echo "$ops" | grep -q schedpilot; then
			echo "[FAIL] schedpilot still registered after rollback" >&2
			exit 1
		fi
	fi
	echo "[schedpilot] rollback ok (state=$st)"
}

CMD="${1:-status}"
shift || true
case "$CMD" in
start) cmd_start "$@" ;;
daemon-start) cmd_daemon_start "$@" ;;
daemon-stop) [ -f "$DAEMON_PID" ] && kill "$(cat "$DAEMON_PID")" 2>/dev/null; rm -f "$DAEMON_PID" ;;
stop) cmd_stop ;;
status) cmd_status ;;
rollback) cmd_rollback ;;
*) echo "usage: $0 {start|stop|status|rollback|daemon-start|daemon-stop}" >&2; exit 1 ;;
esac
