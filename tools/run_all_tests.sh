#!/usr/bin/env bash
# Run every host test in tools/ against ./bin/lumen (Lua) and node (JS).
# A test is considered failed when the runner exits non-zero or its output
# carries a failure marker. Prints one line per test plus a summary.
set -uo pipefail

cd "$(dirname "$0")/.."

BIN=${LUMEN_BIN:-./bin/lumen}
pass=0
fail=0
failed_names=()

run_one() {
	local name="$1"
	shift
	local out rc
	out=$("$@" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qE '(^|[^A-Za-z])FAIL(:|ED)|assertion failed|stack traceback|[1-9][0-9]* failed'; then
		echo "FAIL  $name"
		printf '%s\n' "$out" | tail -12 | sed 's/^/      /'
		fail=$((fail + 1))
		failed_names+=("$name")
	else
		echo "ok    $name"
		pass=$((pass + 1))
	fi
}

for t in tools/test_*.lua; do
	run_one "$t" env LUMEN_LUA_DIR=lua "$BIN" --test "$t"
done

if command -v node >/dev/null 2>&1; then
	for t in tools/test_*.js; do
		run_one "$t" node "$t"
	done
fi

for t in tools/test_*.sh; do
	[ "$t" = "tools/run_all_tests.sh" ] && continue
	run_one "$t" bash "$t"
done

echo "----"
echo "passed: $pass  failed: $fail"
if [ "$fail" -ne 0 ]; then
	printf 'failed tests:\n'
	printf '  %s\n' "${failed_names[@]}"
	exit 1
fi
