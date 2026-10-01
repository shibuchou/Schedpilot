#!/usr/bin/env bash
# Generate a self-contained status snapshot HTML for demo/reporting.
#   scripts/status_html.sh [output.html]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/status.html}"

{
	echo "<!DOCTYPE html><html><head><meta charset='utf-8'><title>SchedPilot status</title>"
	echo "<style>body{font-family:monospace;margin:24px}table{border-collapse:collapse}"
	echo "td,th{border:1px solid #ccc;padding:4px 10px;text-align:left}th{background:#f3f3f3}</style></head><body>"
	echo "<h2>SchedPilot status</h2>"
	echo "<table>"
	echo "<tr><th>field</th><th>value</th></tr>"
	printf "<tr><td>time</td><td>%s</td></tr>\n" "$(date -Is)"
	printf "<tr><td>kernel</td><td>%s</td></tr>\n" "$(uname -r)"
	printf "<tr><td>sched_ext.state</td><td>%s</td></tr>\n" "$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo n/a)"
	printf "<tr><td>sched_ext.ops</td><td>%s</td></tr>\n" "$(ls /sys/kernel/sched_ext/*/ops 2>/dev/null | xargs -r -n1 cat 2>/dev/null | tr '\n' ' ')"
	printf "<tr><td>loader/daemon</td><td>%s</td></tr>\n" "$("$ROOT/scripts/schedpilotctl.sh" status 2>/dev/null | head -n1)"
	echo "</table>"
	echo "<h3>cfg</h3><pre>$("$ROOT/build/schedpilotd" --dump-cfg 2>/dev/null || echo 'loader not running')</pre>"
	echo "<h3>stats</h3><pre>$("$ROOT/build/scx_schedpilot" --stats 2>/dev/null | tail -n 2 || echo 'loader not running')</pre>"
	echo "</body></html>"
} >"$OUT"
echo "wrote $OUT"
