#!/usr/bin/env bash
# SchedPilot environment capability check.
#
# Records the facts required for the v0.3 provincial MVP report:
# OS / kernel / kernel config / BTF / CONFIG_SCHED_CLASS_EXT / toolchain /
# libbpf / PMU / governor / cache-NUMA topology / workload tools.
#
# Usage: env_check.sh [--json OUT.json] [--label NAME]
set -u

JSON_OUT=""
LABEL="$(hostname)-$(date +%Y%m%d-%H%M%S)"
while [ $# -gt 0 ]; do
	case "$1" in
	--json) JSON_OUT="$2"; shift 2 ;;
	--label) LABEL="$2"; shift 2 ;;
	-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date -Is)"

pass=0; fail=0; warn=0
declare -a ROWS=()

emit() { # status key value
	local st="$1" key="$2" val="$3"
	case "$st" in
	OK) pass=$((pass+1)) ;;
	FAIL) fail=$((fail+1)) ;;
	WARN) warn=$((warn+1)) ;;
	esac
	ROWS+=("$st|$key|$val")
	printf '%-4s %-28s %s\n' "[$st]" "$key" "$val"
}

jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'; }

echo "=== SchedPilot environment check ($TS) ==="
echo "label: $LABEL"

# --- OS / kernel -----------------------------------------------------------
OS_PRETTY="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
KREL="$(uname -r)"
emit OK os "$OS_PRETTY"
emit OK kernel "$KREL"
emit OK cmdline "$(tr ' ' ' ' </proc/cmdline 2>/dev/null || echo unknown)"

# --- kernel config / BTF / sched_ext --------------------------------------
KCFG="/boot/config-$KREL"
if [ -f "$KCFG" ]; then
	CONF_SRC="$(grep -m1 '^CONFIG_SCHED_CLASS_EXT=' "$KCFG" 2>/dev/null || true)"
	BTF_CFG="$(grep -m1 '^CONFIG_DEBUG_INFO_BTF=' "$KCFG" 2>/dev/null || true)"
	BPF_CFG="$(grep -m1 '^CONFIG_BPF_SYSCALL=' "$KCFG" 2>/dev/null || true)"
elif [ -f /proc/config.gz ]; then
	CONF_SRC="$(zcat /proc/config.gz 2>/dev/null | grep -m1 '^CONFIG_SCHED_CLASS_EXT=' || true)"
	BTF_CFG="$(zcat /proc/config.gz 2>/dev/null | grep -m1 '^CONFIG_DEBUG_INFO_BTF=' || true)"
	BPF_CFG="$(zcat /proc/config.gz 2>/dev/null | grep -m1 '^CONFIG_BPF_SYSCALL=' || true)"
	KCFG="/proc/config.gz"
else
	CONF_SRC=""; BTF_CFG=""; BPF_CFG=""
fi

if echo "$CONF_SRC" | grep -q '=y\|=m'; then
	emit OK kernel.config_sched_class_ext "${CONF_SRC:-not found}"
else
	emit FAIL kernel.config_sched_class_ext "${CONF_SRC:-config file unavailable: $KCFG}"
fi
emit OK kernel.config_debug_info_btf "${BTF_CFG:-unknown}"
emit OK kernel.config_bpf_syscall "${BPF_CFG:-unknown}"

if [ -r /sys/kernel/btf/vmlinux ]; then
	emit OK btf "/sys/kernel/btf/vmlinux ($(stat -c%s /sys/kernel/btf/vmlinux 2>/dev/null) bytes)"
else
	emit FAIL btf "/sys/kernel/btf/vmlinux missing"
fi

if [ -d /sys/kernel/sched_ext ]; then
	st="$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo unknown)"
	ops="$(ls /sys/kernel/sched_ext/*/ops 2>/dev/null | xargs -r -n1 cat 2>/dev/null | tr '\n' ' ')"
	emit OK sched_ext "state=$st ops=${ops:-none}"
else
	emit FAIL sched_ext "/sys/kernel/sched_ext missing (CONFIG_SCHED_CLASS_EXT not enabled?)"
fi

# --- toolchain -------------------------------------------------------------
CLANG_BIN="$(command -v clang || true)"
if [ -n "$CLANG_BIN" ]; then
	emit OK clang "$($CLANG_BIN --version | head -n1)"
else
	emit FAIL clang "clang not found (need >= 17, >= 18 recommended)"
fi
for t in gcc make bpftool perf pkg-config; do
	if command -v "$t" >/dev/null 2>&1; then
		v="$("$t" --version 2>/dev/null | head -n1 | cut -c1-80)"
		emit OK "tool.$t" "$v"
	else
		emit FAIL "tool.$t" "not found"
	fi
done
if pkg-config --exists libbpf 2>/dev/null; then
	emit OK libbpf "$(pkg-config --modversion libbpf)"
else
	emit WARN libbpf "pkg-config libbpf missing"
fi
if [ -f /usr/include/bpf/bpf_helpers.h ]; then
	emit OK libbpf.headers "/usr/include/bpf/bpf_helpers.h"
else
	emit FAIL libbpf.headers "/usr/include/bpf/bpf_helpers.h missing (need libbpf-dev)"
fi

# --- PMU -------------------------------------------------------------------
PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)"
emit OK perf_event_paranoid "$PARANOID"
PMU_TEST="$(perf stat -e cycles,instructions,cache-references,cache-misses true 2>&1 || true)"
if printf '%s' "$PMU_TEST" | grep -q 'cycles'; then
	emit OK pmu "$(printf '%s' "$PMU_TEST" | grep -E 'cycles|instructions' | tr -s ' ' | tr '\n' ';' | cut -c1-100)"
elif [ "$(id -u)" != "0" ] && [ "$PARANOID" -ge 2 ] 2>/dev/null; then
	emit WARN pmu "perf stat denied as non-root (paranoid=$PARANOID); run schedpilotd as root"
else
	emit WARN pmu "no hardware PMU counters available; daemon will degrade to scheduling-only features"
fi
if [ -d /sys/bus/event_source/devices/cpu_core ] || [ -d /sys/bus/event_source/devices/cpu ]; then
	emit OK pmu.pmu_device "$(ls -d /sys/bus/event_source/devices/cpu* 2>/dev/null | tr '\n' ' ')"
else
	emit WARN pmu.pmu_device "no CPU PMU device in sysfs"
fi

# --- CPU topology / governor ----------------------------------------------
emit OK cpu.model "$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')"
emit OK cpu.count "online=$(nproc) threads=$(grep -c ^processor /proc/cpuinfo)"
emit OK cpu.numa "$(lscpu 2>/dev/null | awk -F: '/NUMA node\(s\)/{gsub(/ /,"",$2); print $2}') NUMA node(s)"
emit OK cpu.caches "$(lscpu 2>/dev/null | awk -F: '/^L[123] cache/{gsub(/^ +/,"",$2); printf "%s ", $2}')"
GOVS="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unavailable)"
emit OK cpu.governor "$GOVS"
emit OK mem.total "$(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"

# --- workload tools --------------------------------------------------------
for t in redis-server redis-cli redis-benchmark memtier_benchmark nginx sysbench stress-ng; do
	if command -v "$t" >/dev/null 2>&1; then
		emit OK "workload.$t" "$(command -v "$t")"
	else
		emit WARN "workload.$t" "not installed"
	fi
done

# --- schedpilot state ------------------------------------------------------
if [ -x "$ROOT/build/scx_schedpilot" ]; then
	emit OK schedpilot.loader "$ROOT/build/scx_schedpilot"
else
	emit WARN schedpilot.loader "not built yet"
fi
if [ -x "$ROOT/build/schedpilotd" ]; then
	emit OK schedpilot.daemon "$ROOT/build/schedpilotd"
else
	emit WARN schedpilot.daemon "not built yet"
fi
if [ -d /sys/fs/bpf/schedpilot/v1 ]; then
	emit OK schedpilot.pinned_maps "$(ls /sys/fs/bpf/schedpilot/v1 | tr '\n' ' ')"
else
	emit OK schedpilot.pinned_maps "not loaded (expected before first run)"
fi
if [ -x "$ROOT/build/schedpilotd" ]; then
	"$ROOT/build/schedpilotd" --status 2>/dev/null || true
fi

echo
echo "=== summary: OK=$pass WARN=$warn FAIL=$fail ==="
if [ "$fail" -gt 0 ]; then
	echo "FATAL_CHECKS_FAILED=$fail (see [FAIL] rows above)"
fi

if [ -n "$JSON_OUT" ]; then
	{
		printf '{\n  "label": "%s",\n  "timestamp": "%s",\n' "$(jesc "$LABEL")" "$TS"
		printf '  "checks": [\n'
		local_i=0
		for row in "${ROWS[@]}"; do
			st="${row%%|*}"; rest="${row#*|}"; key="${rest%%|*}"; val="${rest#*|}"
			[ "$local_i" -gt 0 ] && printf ',\n'
			printf '    {"status": "%s", "key": "%s", "value": "%s"}' \
				"$(jesc "$st")" "$(jesc "$key")" "$(jesc "$val")"
			local_i=$((local_i+1))
		done
		printf '\n  ],\n  "summary": {"ok": %d, "warn": %d, "fail": %d}\n}\n' \
			"$pass" "$warn" "$fail"
	} >"$JSON_OUT"
	echo "json written: $JSON_OUT"
fi

exit 0
