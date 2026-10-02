#!/usr/bin/env bash
# Deployment entry for the measured-best Nginx configuration.
#
# Measured (nginx-2, scenario v3, 20 runs): basic mode (B) gives
#   +43.8% QPS and p99 -37.7% vs the default fair baseline (p<0.0001).
# Classification mode (class/adaptive) raises Nginx tail latency (P1).
#
#   scripts/deploy_nginx.sh [--no-verify]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY=1
[ "${1:-}" = "--no-verify" ] && VERIFY=0

"$ROOT/scripts/schedpilotctl.sh" rollback >/dev/null 2>&1 || true
"$ROOT/scripts/schedpilotctl.sh" start --mode basic --no-daemon

if [ "$VERIFY" = "1" ]; then
	st="$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo missing)"
	ops="$(ls /sys/kernel/sched_ext/*/ops 2>/dev/null | xargs -r -n1 cat 2>/dev/null | tr '\n' ' ')"
	echo "[deploy-nginx] sched_ext.state=$st ops=$ops"
	[ "$st" = "enabled" ] || { echo "[FAIL] sched_ext not enabled" >&2; exit 1; }
	case "$ops" in
	*schedpilot*) : ;;
	*) echo "[FAIL] unexpected ops: $ops" >&2; exit 1 ;;
	esac
fi
echo "[deploy-nginx] basic mode active (measured best for Nginx; stop with schedpilotctl.sh rollback)"
