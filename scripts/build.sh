#!/usr/bin/env bash
# SchedPilot build driver.
#
# Dev build (vendored sched_ext headers, any 6.12-ish BTF for compile check):
#   scripts/build.sh --dev [--vmlinux /path/to/vmlinux.h]
#
# Target build on the frozen environment (openEuler 24.03 LTS SP4) using the
# exact kernel tree headers (authoritative for competition results):
#   scripts/build.sh --kernel-src /root/kernel-src [--install]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="dev"
KERNEL_SRC="${KERNEL_SRC:-}"
VMLINUX="${VMLINUX:-}"
INSTALL=0
JOBS="$(nproc)"

while [ $# -gt 0 ]; do
	case "$1" in
	--dev) MODE="dev"; shift ;;
	--kernel-src) MODE="kernel"; KERNEL_SRC="$2"; shift 2 ;;
	--vmlinux) VMLINUX="$2"; shift 2 ;;
	--install) INSTALL=1; shift ;;
	--jobs) JOBS="$2"; shift 2 ;;
	-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
	*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

mkdir -p "$ROOT/build"
echo "[schedpilot] build mode=$MODE root=$ROOT"

build_daemon() {
	echo "[schedpilot] building userspace daemon"
	make -C "$ROOT" daemon
}

if [ "$MODE" = "dev" ]; then
	if [ -n "$VMLINUX" ]; then
		cp -f "$VMLINUX" "$ROOT/build/vmlinux.h"
	fi
	if [ ! -f "$ROOT/build/vmlinux.h" ] && [ ! -f "$ROOT/bpf/vmlinux.h" ]; then
		echo "[schedpilot] generating build/vmlinux.h from running kernel BTF"
		bpftool btf dump file /sys/kernel/btf/vmlinux format c >"$ROOT/build/vmlinux.h"
	fi
	make -C "$ROOT" all
	build_daemon
	echo "[schedpilot] dev build done:"
	ls -l "$ROOT/build/scx_schedpilot" "$ROOT/build/schedpilotd" \
		"$ROOT/build/scx_schedpilot.bpf.o"
	exit 0
fi

# ---- kernel-tree build (SP4) ----------------------------------------------
[ -n "$KERNEL_SRC" ] || { echo "[FAIL] --kernel-src DIR is required" >&2; exit 1; }
SCHED_EXT_DIR="$KERNEL_SRC/tools/sched_ext"
[ -d "$SCHED_EXT_DIR" ] || { echo "[FAIL] $SCHED_EXT_DIR not found" >&2; exit 1; }
[ -f "$SCHED_EXT_DIR/Makefile" ] || { echo "[FAIL] $SCHED_EXT_DIR/Makefile not found" >&2; exit 1; }

cp "$ROOT/bpf/scx_schedpilot.bpf.c" "$SCHED_EXT_DIR/scx_schedpilot.bpf.c"
cp "$ROOT/bpf/intf.h" "$SCHED_EXT_DIR/intf.h"
cp "$ROOT/loader/scx_schedpilot.c" "$SCHED_EXT_DIR/scx_schedpilot.c"

if ! grep -qw 'scx_schedpilot' "$SCHED_EXT_DIR/Makefile"; then
	echo "[schedpilot] adding scx_schedpilot to $SCHED_EXT_DIR/Makefile"
	sed -i 's/^c-sched-targets = \(.*\)$/c-sched-targets = \1 scx_schedpilot/' \
		"$SCHED_EXT_DIR/Makefile"
fi

SCX_BUILD_DIR="${SCX_BUILD_DIR:-$ROOT/build/scx-tools}"
mkdir -p "$SCX_BUILD_DIR"
make -C "$SCHED_EXT_DIR" O="$SCX_BUILD_DIR" LLVM="${LLVM:-1}" scx_schedpilot -j"$JOBS"

LOADER_BIN="$SCX_BUILD_DIR/build/bin/scx_schedpilot"
[ -x "$LOADER_BIN" ] || { echo "[FAIL] loader not produced: $LOADER_BIN" >&2; exit 1; }

if [ "$INSTALL" = "1" ]; then
	install -m 0755 "$LOADER_BIN" /usr/local/bin/scx_schedpilot
	echo "[schedpilot] installed /usr/local/bin/scx_schedpilot"
else
	cp -f "$LOADER_BIN" "$ROOT/build/scx_schedpilot"
fi

build_daemon

echo "[schedpilot] kernel-tree build done"
if [ "$INSTALL" = "1" ] && [ -x /usr/local/bin/scx_schedpilot ]; then
	/usr/local/bin/scx_schedpilot --status || true
fi
