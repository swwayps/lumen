package.path = "lua/?.lua;" .. package.path
local rpc = require("rpc")
local function ok(c, m) if not c then error("FAIL: "..(m or "")) end end

-- A fake registry of backend globals.
local registry = {
  Echo = function(args) return '{"got":"' .. (args.x or "") .. '"}' end,
  Boom = function() error("kaboom") end,
}

-- 1. Valid token + known fn -> dispatched, returns the fn's JSON string.
do
  local body = '{"token":"SECRET","fn":"Echo","args":{"x":"hi"}}'
  local status, resp = rpc.handle(body, "SECRET", registry)
  ok(status == 200, "status 200")
  ok(resp == '{"got":"hi"}', "echo body: " .. tostring(resp))
end

-- 2. Bad token -> 403, not dispatched.
do
  local status, resp = rpc.handle('{"token":"WRONG","fn":"Echo","args":{}}', "SECRET", registry)
  ok(status == 403, "bad token -> 403")
end

-- 3. Unknown fn -> 404.
do
  local status = rpc.handle('{"token":"SECRET","fn":"Nope","args":{}}', "SECRET", registry)
  ok(status == 404, "unknown fn -> 404")
end

-- 4. fn that errors -> 500, body carries an error JSON (not a crash).
do
  local status, resp = rpc.handle('{"token":"SECRET","fn":"Boom","args":{}}', "SECRET", registry)
  ok(status == 500, "error -> 500")
  ok(resp:find("error", 1, true) ~= nil, "error body")
end

-- 5. Malformed JSON body -> 400.
do
  local status = rpc.handle("not json", "SECRET", registry)
  ok(status == 400, "malformed -> 400")
end

print("test_rpc: ALL PASS")
