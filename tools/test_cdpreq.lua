-- Run via the built binary:
--   LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_cdpreq.lua
--
-- cdpreq.lua is the blocking one-shot CDP client behind the Ryuu sign-in (the
-- injector's own connections push Runtime.evaluate and never read a command
-- result back). Both sides are blocking, so a same-thread fake server would
-- deadlock: the endpoint runs as a separate process (tools/fake_cdp_server.py).
package.path = "lua/?.lua;" .. package.path
local socket = require("socket")
local cdpreq = require("cdpreq")

local fails, checks = 0, 0
local function ok(cond, name)
  checks = checks + 1
  if cond then io.write("ok " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); fails = fails + 1 end
end

-- ── pure: websocket path extraction ────────────────────────────────────────
ok(cdpreq.ws_path("ws://127.0.0.1:8080/devtools/page/AB12") == "/devtools/page/AB12",
   "ws_path: devtools page")
ok(cdpreq.ws_path("ws://127.0.0.1:8080/devtools/browser") == "/devtools/browser",
   "ws_path: browser endpoint")
ok(cdpreq.ws_path("http://127.0.0.1:8080/devtools/page/AB") == nil, "ws_path: not a ws url")
ok(cdpreq.ws_path("ws://127.0.0.1:8080") == nil, "ws_path: no path")
ok(cdpreq.ws_path("") == nil, "ws_path: empty")
ok(cdpreq.ws_path(nil) == nil, "ws_path: nil")

-- ── IO against the out-of-process fake endpoint ────────────────────────────
local WS = "ws://127.0.0.1:1/devtools/page/TEST"

local function start_server(mode)
  local port_file = os.tmpname()
  os.remove(port_file)
  local cmd = "python3 tools/fake_cdp_server.py " .. mode .. " " .. port_file
    .. " >/dev/null 2>&1 &"
  os.execute(cmd)
  -- The port file is written atomically, so any content is the complete port.
  for _ = 1, 100 do
    local fh = io.open(port_file, "r")
    if fh then
      local body = fh:read("*a"); fh:close()
      local port = tonumber((tostring(body):gsub("%s", "")))
      if port then os.remove(port_file); return port end
    end
    socket.sleep(0.05)
  end
  os.remove(port_file)
  return nil
end

local function with_server(mode, fn)
  local port = start_server(mode)
  if not port then return nil, "server did not start" end
  return fn(port)
end

local value, err = with_server("ok", function(port)
  return cdpreq.evaluate(port, WS, "1+1", 6)
end)
ok(value == "hello", "evaluate: unwraps the returnByValue result")

local raw
raw, err = with_server("noise-then-result", function(port)
  return cdpreq.request(port, WS, "Network.getCookies", {}, 6)
end)
ok(type(raw) == "table" and raw.result and raw.result.value == "hello",
   "request: skips unrelated events and mismatched ids")

value, err = with_server("error", function(port)
  return cdpreq.evaluate(port, WS, "1+1", 6)
end)
ok(value == nil and tostring(err):find("cdp error", 1, true) ~= nil,
   "evaluate: a protocol error is an error, not a nil value")

value, err = with_server("exception", function(port)
  return cdpreq.evaluate(port, WS, "boom()", 6)
end)
ok(value == nil and err == "js exception",
   "evaluate: thrown JS is an error, so a missing API is distinguishable")

value, err = with_server("no-upgrade", function(port)
  return cdpreq.evaluate(port, WS, "1+1", 6)
end)
ok(value == nil and tostring(err):find("handshake", 1, true) ~= nil,
   "evaluate: refused websocket upgrade is reported")

value, err = with_server("silent", function(port)
  return cdpreq.evaluate(port, WS, "1+1", 1)
end)
ok(value == nil and (err == "timeout" or err == "closed"),
   "evaluate: a silent target times out instead of hanging the loop")

-- No listener at all: must fail fast, never block the sidecar's event loop.
local started = socket.gettime()
value, err = cdpreq.evaluate(1, WS, "1+1", 1)
ok(value == nil and err ~= nil, "evaluate: dead port is reported")
ok(socket.gettime() - started < 3, "evaluate: dead port fails fast")

-- The popup blocker in CEF drops a gesture-less target=_blank click without
-- reporting failure, so the flag has to reach the protocol.
local saw
local orig_request = cdpreq.request
cdpreq.request = function(port, ws, method, params, timeout)
  saw = params
  return {result = {type = "boolean", value = true}}
end
cdpreq.evaluate(1, WS, "click()", 1, true)
ok(saw and saw.userGesture == true, "evaluate: user gesture forwarded when asked")
cdpreq.evaluate(1, WS, "1+1", 1)
ok(saw and saw.userGesture == false, "evaluate: no gesture by default")
cdpreq.request = orig_request

-- A malformed target url must not even open a socket.
value, err = cdpreq.evaluate(1, "not-a-ws-url", "1+1", 1)
ok(value == nil and err == "bad websocket url", "evaluate: malformed target refused")

io.write((fails == 0 and "all ok" or (fails .. " FAILED")) .. " (" .. checks .. " checks)\n")
os.exit(fails == 0 and 0 or 1)
