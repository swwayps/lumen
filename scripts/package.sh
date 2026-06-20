#!/usr/bin/env bash
# package.sh — assemble dist/lumen-linux.zip (the release asset).
# Layout inside the zip:
#   lumen          (static binary, built by scripts/_build-portable.sh)
#   lua/*.lua      (injector, shims, polyfill, etc.)
#   lua/menu/*.js  (ordered fragments of the injected settings menu)
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
# Frontend asset(s) injected into the shell ship alongside the .lua modules and
# are read at boot from LUMEN_LUA_DIR.
cp lua/*.js "$STAGE/lua/" 2>/dev/null || true
# The settings menu is split into ordered source fragments under lua/menu/,
# concatenated into one script at boot (see boot.lua read_menu_js). Ship them all.
if [ -d lua/menu ]; then
  mkdir -p "$STAGE/lua/menu"
  cp lua/menu/*.js "$STAGE/lua/menu/"
fi
( cd "$STAGE" && zip -qr "$OLDPWD/$OUT" lumen lua )
echo "wrote $OUT"
unzip -l "$OUT" | tail -n +2 | head
