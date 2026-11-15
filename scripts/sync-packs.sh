#!/bin/sh
# Refresh the packs bundled with the app from a packs repository before a release build.
# Usage: scripts/sync-packs.sh [git-url-or-local-path] [subdir]
# Default pulls dabbers/dabterm-packs (create it to host packs outside the app repo).
set -eu
SRC="${1:-https://github.com/dabbers/dabterm-packs.git}"
SUB="${2:-}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/dabterm/Resources/packs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ -d "$SRC" ]; then cp -R "$SRC/." "$TMP/"; else git clone --depth 1 -q "$SRC" "$TMP"; fi
for pack in "$TMP/$SUB"/*/; do
  [ -f "$pack/pack.json" ] || continue
  name="$(basename "$pack")"
  rm -rf "$DEST/$name"
  mkdir -p "$DEST/$name"
  cp -R "$pack/." "$DEST/$name/"
  echo "synced $name $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$pack/pack.json" | head -1)"
done
