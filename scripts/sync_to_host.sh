#!/usr/bin/env bash
# Sync the SchedPilot tree to a remote host (run this from a Linux dev box).
# Usage: sync_to_host.sh HOST [DEST]
set -euo pipefail

HOST="$1"
DEST="${2:-~/schedpilot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v rsync >/dev/null 2>&1; then
	rsync -az --delete \
		--exclude build/ --exclude logs/ --exclude results/ \
		--exclude .git/ --exclude '*.o' --exclude '*.skel.h' \
		"$ROOT/" "$HOST:$DEST/"
else
	tar -C "$ROOT" --exclude=build --exclude=logs --exclude=results \
		--exclude=.git -czf - . | ssh "$HOST" "mkdir -p $DEST && tar -xzf - -C $DEST"
fi
echo "[schedpilot] synced to $HOST:$DEST"
