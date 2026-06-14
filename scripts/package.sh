#!/usr/bin/env bash
# package.sh — assemble dist/lumen-linux.zip (the release asset).
# Layout inside the zip:
#   lumen          (static binary, built by scripts/_build-portable.sh)
#   lua/*.lua      (injector, shims, polyfill, etc.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -x bin/lumen ]; then
  echo "bin/lumen missing — run scripts/_build-portable.sh first" >&2
  exit 1
fi
command -v zip >/dev/null 2>&1 || { echo "zip not found" >&2; exit 1; }

OUT="dist/lumen-linux.zip"
mkdir -p dist
rm -f "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp bin/lumen "$STAGE/lumen"
mkdir -p "$STAGE/lua"
cp lua/*.lua "$STAGE/lua/"
# Frontend asset(s) injected into the shell (e.g. lumen_menu.js) ship alongside
# the .lua modules and are read at boot from LUMEN_LUA_DIR.
cp lua/*.js "$STAGE/lua/" 2>/dev/null || true
( cd "$STAGE" && zip -qr "$OLDPWD/$OUT" lumen lua )
echo "wrote $OUT"
unzip -l "$OUT" | tail -n +2 | head
