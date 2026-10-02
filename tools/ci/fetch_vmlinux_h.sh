#!/usr/bin/env bash
# Fetch an upstream (>= 6.12) kernel BTF and dump vmlinux.h for use in
# development/CI BPF builds. The frozen openEuler target build still uses the
# exact kernel tree via scripts/build.sh --kernel-src.
#
#   tools/ci/fetch_vmlinux_h.sh OUTPUT [VERSION]
set -euo pipefail

OUT="${1:-$PWD/vmlinux.h}"
VER="${2:-}"

if [ -z "$VER" ]; then
	# Prefer 6.14 to match the vendored scx dev headers; fall back to the
	# newest available 6.12+ build.
	VER="$(curl -s https://kernel.ubuntu.com/mainline/ \
		| grep -oE 'v6\.14\.[0-9]+/' | tr -d '/' | sort -V | tail -n1)"
	[ -n "$VER" ] || VER="$(curl -s https://kernel.ubuntu.com/mainline/ \
		| grep -oE 'v6\.1[2-9]\.[0-9]+/' | tr -d '/' | sort -V | tail -n1)"
fi
[ -n "$VER" ] || { echo "[FAIL] no >=6.12 mainline version found" >&2; exit 1; }

BASE="https://kernel.ubuntu.com/mainline/$VER/amd64"
DEB="$(curl -s "$BASE/" | grep -oE 'linux-image-unsigned-[^"]+_amd64\.deb' | grep generic | head -n1)"
[ -n "$DEB" ] || DEB="$(curl -s "$BASE/" | grep -oE 'linux-image-unsigned-[^"]+_amd64\.deb' | head -n1)"
[ -n "$DEB" ] || { echo "[FAIL] no linux-image-unsigned deb in $BASE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[ci] downloading $VER/$DEB"
curl -sL -o "$WORK/k.deb" "$BASE/$DEB"
mkdir -p "$WORK/root"
if command -v dpkg-deb >/dev/null 2>&1; then
	dpkg-deb -x "$WORK/k.deb" "$WORK/root"
elif command -v ar >/dev/null 2>&1; then
	# Fallback for non-Debian hosts: a .deb is an ar archive with
	# data.tar.{xz,zst,gz}.
	mkdir -p "$WORK/debx"
	(cd "$WORK/debx" && ar x "$WORK/k.deb")
	DATA_TAR="$(ls "$WORK"/debx/data.tar.* 2>/dev/null | head -n1)"
	[ -n "$DATA_TAR" ] || { echo "[FAIL] no data.tar.* after ar x" >&2; exit 1; }
	tar -xf "$DATA_TAR" -C "$WORK/root"
else
	echo "[FAIL] neither dpkg-deb nor ar available for deb extraction" >&2
	exit 1
fi
VMLINUZ="$(find "$WORK/root" -name 'vmlinuz-*' | head -n1)"
[ -n "$VMLINUZ" ] || { echo "[FAIL] vmlinuz not found in deb" >&2; exit 1; }

for d in gunzip unxz bunzip2 unlzma zstd lz4; do
	command -v "$d" >/dev/null 2>&1 || MISSING_DECOMP="$d${MISSING_DECOMP:+ $MISSING_DECOMP}"
done
if [ -n "${MISSING_DECOMP:-}" ]; then
	echo "[warn] missing decompressors: $MISSING_DECOMP (install zstd/lz4/xz-utils if extraction fails)" >&2
fi

cat >"$WORK/extract-vmlinux" <<'EOS'
#!/bin/sh
check_vmlinux() {
	readelf -h "$1" > /dev/null 2>&1 || return 1
	cat "$1"
	exit 0
}
try_decompress() {
	for pos in $(tr "$1\n$2" "\n$2=" < "$img" | grep -abo "^$2"); do
		pos=${pos%%:*}
		tail -c+$pos "$img" | $3 > "$tmp" 2> /dev/null
		check_vmlinux "$tmp"
	done
}
img="$1"
tmp=$(mktemp /tmp/vmlinux-XXXXXX)
trap 'rm -f "$tmp"' EXIT
try_decompress '\037\213\010' xy    gunzip
try_decompress '\3757zXZ\000' abcde unxz
try_decompress 'BZh'          xy    bunzip2
try_decompress '\135\0\0\0'   xxx   unlzma
try_decompress '\002!L\030'   xxx   'lz4 -d'
try_decompress '(\265/\375'   xxx   'zstd -d'
exit 1
EOS
chmod +x "$WORK/extract-vmlinux"
"$WORK/extract-vmlinux" "$VMLINUZ" >"$WORK/vmlinux"
[ -s "$WORK/vmlinux" ] || { echo "[FAIL] failed to extract vmlinux" >&2; exit 1; }

bpftool btf dump file "$WORK/vmlinux" format c >"$OUT"
echo "[ci] wrote $OUT from $VER ($DEB)"
