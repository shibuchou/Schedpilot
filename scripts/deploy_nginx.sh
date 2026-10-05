#!/usr/bin/env bash
# Deployment entry for the measured-best Nginx configuration.
#
# Measured (nginx-5, scenario v3, 10 runs x 60s, 0 invalid):
#   classification + adaptive (C): +127.4% QPS / p99 -64.9% (paired +124.8% / -62.5%)
#   basic (B):                     +37.7% QPS / p99 -35.8% (paired +37.1% / -32.0%)
# Earlier builds showed classification-mode tail latency issues on Nginx (P1);
# after the migration-penalty cap and BG-slice fixes they are resolved, so
# adaptive (C) is now the recommended mode. Use --mode basic as the
# conservative fallback (also covered by tests/test_nginx_basic.sh).
#
#   scripts/deploy_nginx.sh [--mode adaptive|basic] [--no-verify]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="adaptive"
VERIFY=1

while [ $# -gt 0 ]; do
	case "$1" in
	--mode) MODE="$2"; shift 2 ;;
	--no-verify) VERIFY=0; shift ;;
	*) echo "[FAIL] unknown arg: $1" >&2; exit 1 ;;
	esac
done
case "$MODE" in
adaptive | basic) : ;;
*) echo "[FAIL] --mode must be adaptive or basic" >&2; exit 1 ;;
esac

"$ROOT/scripts/schedpilotctl.sh" rollback >/dev/null 2>&1 || true
if [ "$MODE" = "basic" ]; then
	"$ROOT/scripts/schedpilotctl.sh" start --mode basic --no-daemon
else
	"$ROOT/scripts/schedpilotctl.sh" start --mode adaptive --config "$ROOT/configs/nginx.conf"
fi

if [ "$VERIFY" = "1" ]; then
	st="$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing)"
	ops="$(ls /sys/kernel/sched_ext/*/ops 2>/dev/null | xargs -r -n1 cat 2>/dev/null | tr '\n' ' ')"
	echo "[deploy-nginx] mode=$MODE sched_ext.state=$st ops=$ops"
	[ "$st" = "enabled" ] || {
		echo "[FAIL] sched_ext not enabled" >&2
		exit 1
	}
	case "$ops" in
	*schedpilot*) : ;;
	*)
		echo "[FAIL] unexpected ops: $ops" >&2
		exit 1
		;;
	esac
	if [ "$MODE" = "adaptive" ] && ! pgrep -f 'build/schedpilotd' >/dev/null 2>&1; then
		echo "[FAIL] schedpilotd not running (adaptive mode needs the daemon)" >&2
		exit 1
	fi
fi
echo "[deploy-nginx] $MODE mode active (recommended: adaptive; stop with schedpilotctl.sh rollback)"
