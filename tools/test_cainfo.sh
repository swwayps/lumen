#!/usr/bin/env bash
# The shipped bin/lumen links a static libcurl built without --with-ca-bundle, so
# its compiled-in trust-store path is the build container's (Ubuntu 22.04). On
# Fedora, RHEL or openSUSE that path does not exist and every TLS handshake
# fails. The failure is fail-closed, but the workaround a user reaches for is
# exporting SSL_CERT_FILE, which puts the trust store under the environment's
# control — so the shim resolves the store itself and ignores the environment.
#
# Run from the repo root:  bash tools/test_cainfo.sh
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
checks=0
check() {
	checks=$((checks + 1))
	if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

command -v cc >/dev/null 2>&1 || { echo "SKIP: no cc"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/probe.c" <<'EOF'
#include "../src/cainfo.h"
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
	if (argc > 1 && strcmp(argv[1], "--list") == 0) {
		const char *const *f = lumen_ca_file_candidates();
		for (int i = 0; f[i]; i++) printf("file %s\n", f[i]);
		const char *const *d = lumen_ca_dir_candidates();
		for (int i = 0; d[i]; i++) printf("dir %s\n", d[i]);
		return 0;
	}
	printf("resolved_file=%s\n", lumen_ca_file() ? lumen_ca_file() : "(none)");
	printf("resolved_dir=%s\n", lumen_ca_dir() ? lumen_ca_dir() : "(none)");
	return 0;
}
EOF

cc -O0 -I src -o "$TMP/probe" "$TMP/probe.c" src/cainfo.c 2>"$TMP/cc.err" || {
	echo "FAIL could not build the probe:"
	cat "$TMP/cc.err"
	exit 1
}

LIST="$("$TMP/probe" --list)"

# Every distro this project supports must be represented.
for want in \
	/etc/ssl/certs/ca-certificates.crt \
	/etc/pki/tls/certs/ca-bundle.crt \
	/etc/ssl/ca-bundle.pem \
	/etc/ssl/cert.pem \
	/etc/ca-certificates/extracted/tls-ca-bundle.pem; do
	check "the probe list covers $want" 'printf "%s" "$LIST" | grep -qxF "file $want"'
done
check "the probe list covers a hashed cert directory" \
	'printf "%s" "$LIST" | grep -qxF "dir /etc/ssl/certs"'

# On this machine a real bundle must be found, and it must be a file that exists.
OUT="$("$TMP/probe")"
RESOLVED="$(printf '%s' "$OUT" | sed -n 's/^resolved_file=//p')"
check "a trust store is resolved on this host (got $RESOLVED)" \
	'[ "$RESOLVED" != "(none)" ]'
check "the resolved trust store exists" '[ -f "$RESOLVED" ]'

# The environment must NOT be able to redirect it.
FAKE="$TMP/fake-ca.pem"
: > "$FAKE"
ENVOUT="$(SSL_CERT_FILE="$FAKE" CURL_CA_BUNDLE="$FAKE" SSL_CERT_DIR="$TMP" "$TMP/probe")"
check "SSL_CERT_FILE cannot redirect the trust store" \
	'! printf "%s" "$ENVOUT" | grep -qF "$FAKE"'
check "the resolved store is unchanged under a hostile environment" \
	'printf "%s" "$ENVOUT" | grep -qxF "resolved_file=$RESOLVED"'

# The transport must actually apply it: a real TLS request has to verify.
if [ -x ./bin/lumen ]; then
	cat > "$TMP/tls.lua" <<'LUA'
local http = require("http")
local r, err = http.get("https://api.perondepot.xyz/all/", { timeout = 25 })
if r and r.status then
  print("TLS_OK status=" .. tostring(r.status))
else
  print("TLS_FAIL " .. tostring(err))
end
LUA
	TLS="$(LUMEN_LUA_DIR=lua ./bin/lumen --test "$TMP/tls.lua" 2>&1)"
	case "$TLS" in
	*TLS_OK*)
		check "a live TLS request verifies with the resolved store" 'true' ;;
	*"Could not resolve host"* | *"Couldn't resolve"* | *"Connection"* | *timeout*)
		echo "ok   a live TLS request was skipped (no network): $TLS"
		checks=$((checks + 1)) ;;
	*)
		echo "FAIL a live TLS request verifies with the resolved store: $TLS"
		checks=$((checks + 1))
		fails=$((fails + 1)) ;;
	esac
fi

# And the binding must reference the resolver at all.
check "the HTTP binding sets CURLOPT_CAINFO" \
	'grep -q "CURLOPT_CAINFO" src/http_binding.c'
check "the HTTP binding sets CURLOPT_CAPATH" \
	'grep -q "CURLOPT_CAPATH" src/http_binding.c'

echo
echo "$checks check(s), $fails failure(s)"
[ "$fails" -eq 0 ] || exit 1
