#!/usr/bin/env bash
# Build in-tree sched_ext C example schedulers (scx_simple, scx_flatcg) from
# the target kernel tree and install them as external reference arms.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KSRC="${KERNEL_SRC:-$(ls -d /usr/src/linux-6.6.0-*.oe2403sp4.x86_64 2>/dev/null | head -n1)}"
BUILD="$ROOT/build/external"
OBJ="$ROOT/build/scx-external"

[ -n "$KSRC" ] || { echo "[FAIL] kernel source not found" >&2; exit 1; }
[ -d "$KSRC/tools/sched_ext" ] || { echo "[FAIL] $KSRC/tools/sched_ext missing" >&2; exit 1; }

mkdir -p "$BUILD" "$OBJ"
make -C "$KSRC/tools/sched_ext" O="$OBJ" LLVM="${LLVM:-1}" \
	scx_simple scx_flatcg -j"$(nproc)" 2>&1 | tail -n 5

cp -f "$OBJ/build/bin/scx_simple" "$BUILD/X-simple"
cp -f "$OBJ/build/bin/scx_flatcg" "$BUILD/X-flatcg"
echo "[external] installed:"
ls -l "$BUILD"
