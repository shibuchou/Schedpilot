#!/usr/bin/env bash
# Deployment entry for the measured-best Nginx configuration.
#
# Measured (nginx-7, scenario v3, 20 runs x 60s, 0 invalid):
#   C = classification, STATIC policy (--mode class --policy off):
#       +137.1% QPS median / p99 -66.4% (paired +167.81% / -69.61%, 20/20)
#   D = classification + ADAPTIVE (--mode adaptive --policy on):
#       +138.1% QPS median / p99 -66.7% (paired +169.82% / -69.63%, 20/20)
#   basic (B): +42.9% QPS / p99 -36.3% (paired +61.14% / -42.22%, 20/20)
# C and D are statistically tied, so adaptive (D) is the default and
# --mode basic is the conservative fallback (tests/test_nginx_basic.sh).
# Earlier builds showed classification-mode tail latency issues on Nginx
# (nginx-5: D only +91.4%); after the migration-penalty cap and BG-slice
# fixes they are resolved - see docs/04_test_report.md §6.10/§6.13.
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
