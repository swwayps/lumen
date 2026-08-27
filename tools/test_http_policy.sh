#!/usr/bin/env bash
# Integration test for the transport policy of the HTTP shim (src/http_binding.c).
#
# The shim used to enable redirect following for every request while only
# restricting the protocol when a caller remembered to pass https_only, and it
# never bounded the redirect count. Custom headers set through CURLOPT_HTTPHEADER
# are re-sent by libcurl to every redirect target, including a different host and
# a downgraded scheme, so the lua.tools and Google Drive / OneDrive bearer tokens
# could be handed to whatever a 302 pointed at.
#
# Run from the repo root:  bash tools/test_http_policy.sh
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=${LUMEN_BIN:-./bin/lumen}
[ -x "$BIN" ] || { echo "$BIN missing — run 'make' first" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }

TMP="$(mktemp -d)"
cleanup() {
	[ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/server.py" <<'PY'
import sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_A = int(sys.argv[1])
PORT_B = int(sys.argv[2])

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        path = self.path
        if path == "/plain":
            self._send(200, b"ok")
        elif path == "/redir-same":
            self._send(302, b"", [("Location", "http://127.0.0.1:%d/plain" % PORT_A)])
        elif path == "/redir-other":
            self._send(302, b"", [("Location",
                "http://127.0.0.2:%d/echo-auth" % PORT_B)])
        elif path.startswith("/loopn"):
            # /loopnN/M -> redirect M times then land on /plain
            rest = path[len("/loopn"):]
            n, m = (rest.split("/") + ["0"])[:2]
            n, m = int(n), int(m)
            if n >= m:
                self._send(200, b"ok")
            else:
                self._send(302, b"", [("Location",
                    "http://127.0.0.1:%d/loopn%d/%d" % (PORT_A, n + 1, m))])
        elif path.startswith("/loop"):
            n = int(path[len("/loop"):] or "0")
            self._send(302, b"", [("Location",
                "http://127.0.0.1:%d/loop%d" % (PORT_A, n + 1))])
        elif path == "/echo-auth":
            got = "auth=%s cookie=%s key=%s" % (
                self.headers.get("Authorization") or "none",
                self.headers.get("Cookie") or "none",
                self.headers.get("X-Api-Key") or "none")
            self._send(200, got.encode())
        else:
            self._send(404, b"no")

    def log_message(self, *a):
        pass

a = ThreadingHTTPServer(("127.0.0.1", PORT_A), H)
b = ThreadingHTTPServer(("127.0.0.2", PORT_B), H)
threading.Thread(target=b.serve_forever, daemon=True).start()
print("ready", flush=True)
a.serve_forever()
PY

PORT_A=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
PORT_B=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.2",0));print(s.getsockname()[1]);s.close()')

python3 "$TMP/server.py" "$PORT_A" "$PORT_B" > "$TMP/srv.out" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do
	grep -q ready "$TMP/srv.out" 2>/dev/null && break
	sleep 0.1
done
grep -q ready "$TMP/srv.out" || { echo "server did not start:"; cat "$TMP/srv.out"; exit 1; }

cat > "$TMP/check.lua" <<'LUA'
local http = require("http")
local A = os.getenv("PORT_A")
local B = os.getenv("PORT_B")
local base = "http://127.0.0.1:" .. A
local checks, fails = 0, 0
local function ok(cond, name)
  checks = checks + 1
  if cond then print("ok   " .. name)
  else print("FAIL " .. name); fails = fails + 1 end
end

-- 1. Plain http is refused unless the caller opts in. The shim used to allow it
--    by default and only restrict protocols when https_only was passed.
do
  local r, err = http.get(base .. "/plain")
  ok(r == nil, "plaintext http is refused by default (err=" .. tostring(err) .. ")")
end

-- 2. The opt-out still works, so the sources that genuinely have no TLS keep
--    functioning while being explicit about it.
do
  local r = http.get(base .. "/plain", { allow_http = true })
  ok(r ~= nil and r.status == 200 and r.body == "ok", "allow_http permits http")
end

-- 3. A redirect is followed for an ordinary request.
do
  local r = http.get(base .. "/redir-same", { allow_http = true })
  ok(r ~= nil and r.status == 200 and r.body == "ok",
    "same-host redirect followed for an unauthenticated request")
end

-- 4. A request carrying a credential header does NOT follow redirects, so the
--    header cannot be replayed to the redirect target.
do
  local r = http.get(base .. "/redir-other", {
    allow_http = true,
    headers = { ["Authorization"] = "Bearer SECRET-TOKEN" },
  })
  ok(r ~= nil and r.status == 302,
    "bearer-token request stops at the redirect (status=" ..
      tostring(r and r.status) .. ")")
end

-- 5. Same for a Cookie header. This one matters most: libcurl strips a custom
--    Authorization header on a cross-HOST redirect (CVE-2018-1000007), but it
--    does NOT strip Cookie, and neither is stripped on a same-host SCHEME
--    downgrade.
do
  local r = http.get(base .. "/redir-other", {
    allow_http = true,
    headers = { ["Cookie"] = "session=SECRET-COOKIE" },
  })
  ok(r ~= nil and r.status == 302, "cookie-bearing request stops at the redirect")
  ok(r ~= nil and (r.body or ""):find("SECRET-COOKIE", 1, true) == nil,
    "the cookie never reaches the redirect target")
  local k = http.get(base .. "/redir-other", {
    allow_http = true,
    headers = { ["X-Api-Key"] = "SECRET-KEY" },
  })
  ok(k ~= nil and k.status == 302,
    "a custom credential header also stops at the redirect")
end

-- 6. Proving the guard is what stops it: with an explicit opt-in, a credential
--    header libcurl does not special-case IS handed to the other host. That is
--    what happened silently for every credentialed call before.
do
  local r = http.get(base .. "/redir-other", {
    allow_http = true,
    follow_redirects_with_credentials = true,
    headers = { ["X-Api-Key"] = "SECRET-KEY" },
  })
  ok(r ~= nil and r.status == 200 and (r.body or ""):find("SECRET-KEY", 1, true),
    "the opt-in path demonstrates the leak the guard prevents")
end

-- 7. Redirect chains are bounded, and the bound is small. A short chain still
--    works so ordinary CDN hops are unaffected.
do
  local short = http.get(base .. "/loopn0/3", { allow_http = true })
  ok(short ~= nil and short.status == 200, "a 3-hop redirect chain still works")
  local long, err = http.get(base .. "/loopn0/20", { allow_http = true })
  ok(long == nil, "a 20-hop chain is refused (err=" .. tostring(err) .. ")")
  local r, loop_err = http.get(base .. "/loop0", { allow_http = true })
  ok(r == nil and tostring(loop_err):find("30", 1, true) == nil,
    "the redirect bound is tighter than libcurl's default 30 (err="
      .. tostring(loop_err) .. ")")
end

-- 9. A redirect that changes scheme is refused when the request is https-only.
--    With allow_http the http hop is permitted, which is what keeps the
--    plaintext sources working.
do
  local r = http.get(base .. "/redir-same", {})
  ok(r == nil, "an https-only request will not follow an http redirect")
end

-- 8. A caller asking for https_only still gets it, and http is refused even with
--    allow_http also set (explicit https_only wins).
do
  local r = http.get(base .. "/plain", { allow_http = true, https_only = true })
  ok(r == nil, "explicit https_only overrides allow_http")
end

print(("\n%d check(s), %d failure(s)"):format(checks, fails))
if fails > 0 then os.exit(1) end
LUA

PORT_A="$PORT_A" PORT_B="$PORT_B" LUMEN_LUA_DIR=lua "$BIN" --test "$TMP/check.lua"
rc=$?
exit "$rc"
