#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/lumen"
TEST_TMP="$(mktemp -d)"
FIRST_PID=""
FAILURES=0

cleanup() {
  if [ -n "$FIRST_PID" ] && kill -0 "$FIRST_PID" 2>/dev/null; then
    kill -TERM "$FIRST_PID" 2>/dev/null || true
    wait "$FIRST_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

mkdir -p "$TEST_TMP/lua" "$TEST_TMP/runtime" \
  "$TEST_TMP/runtime-first" "$TEST_TMP/runtime-second"
printf '%s\n' \
  'local marker = assert(os.getenv("LUMEN_BOOT_MARKER"), "missing marker")' \
  'local file = assert(io.open(marker, "w"))' \
  'file:write("booted\n"); file:close()' \
  'require("socket").sleep(5)' \
  > "$TEST_TMP/lua/boot.lua"

fail() { printf 'not ok: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
pass() { printf 'ok: %s\n' "$1"; }

HELP_MARKER="$TEST_TMP/help-booted"
HELP_OUTPUT="$(LUMEN_LUA_DIR="$TEST_TMP/lua" \
  LUMEN_BOOT_MARKER="$HELP_MARKER" XDG_RUNTIME_DIR="$TEST_TMP/runtime" \
  timeout 1 "$BIN" --help 2>&1)"
HELP_STATUS=$?
if [ "$HELP_STATUS" -eq 0 ] && [[ "$HELP_OUTPUT" == *"Usage:"* ]] \
    && [ ! -e "$HELP_MARKER" ]; then
  pass "--help prints usage without starting Lumen"
else
  fail "--help must exit before loading boot.lua (status=$HELP_STATUS)"
fi

BAD_MARKER="$TEST_TMP/bad-booted"
BAD_OUTPUT="$(LUMEN_LUA_DIR="$TEST_TMP/lua" \
  LUMEN_BOOT_MARKER="$BAD_MARKER" XDG_RUNTIME_DIR="$TEST_TMP/runtime" \
  timeout 1 "$BIN" --not-a-real-option 2>&1)"
BAD_STATUS=$?
if [ "$BAD_STATUS" -eq 2 ] && [[ "$BAD_OUTPUT" == *"Usage:"* ]] \
    && [ ! -e "$BAD_MARKER" ]; then
  pass "unknown options are rejected without starting Lumen"
else
  fail "unknown options must exit 2 before loading boot.lua (status=$BAD_STATUS)"
fi

FIRST_MARKER="$TEST_TMP/first-booted"
SECOND_MARKER="$TEST_TMP/second-booted"
LOCK_FILE="$TEST_TMP/lumen.lock"
LUMEN_LUA_DIR="$TEST_TMP/lua" LUMEN_BOOT_MARKER="$FIRST_MARKER" \
  LUMEN_SINGLETON_LOCK="$LOCK_FILE" \
  XDG_RUNTIME_DIR="$TEST_TMP/runtime-first" "$BIN" \
  > "$TEST_TMP/first.out" 2>&1 &
FIRST_PID=$!

for _ in $(seq 1 100); do
  [ -e "$FIRST_MARKER" ] && break
  kill -0 "$FIRST_PID" 2>/dev/null || break
  sleep 0.01
done

SECOND_OUTPUT="$(LUMEN_LUA_DIR="$TEST_TMP/lua" \
  LUMEN_BOOT_MARKER="$SECOND_MARKER" LUMEN_SINGLETON_LOCK="$LOCK_FILE" \
  XDG_RUNTIME_DIR="$TEST_TMP/runtime-second" \
  timeout 1 "$BIN" 2>&1)"
SECOND_STATUS=$?
if [ -e "$FIRST_MARKER" ] && [ "$SECOND_STATUS" -eq 0 ] \
    && [[ "$SECOND_OUTPUT" == *"already running"* ]] \
    && [ ! -e "$SECOND_MARKER" ]; then
  pass "a second Lumen instance exits even with a different runtime environment"
else
  fail "a second instance must not reach boot.lua (status=$SECOND_STATUS)"
fi

if [ "$FAILURES" -ne 0 ]; then
  printf 'test_cli: %d failed\n' "$FAILURES"
  exit 1
fi
printf 'test_cli: ALL PASS\n'
