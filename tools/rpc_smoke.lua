-- Local RPC smoke: stand up the loop with a fake registry (no real backend,
-- no Steam). Run via the binary: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/rpc_smoke.lua
package.path = "lua/?.lua;" .. package.path
local session = require("session")
local rpcserver = require("rpcserver")
local socket = require("socket")

local registry = {
  Ping = function(args) return '{"pong":"' .. (args.who or "?") .. '"}' end,
}

local path = "/tmp/lumen_rpc_smoke.json"
local srv, port, token = session.start(path)
print("PORT=" .. port)
print("TOKEN=" .. token)
srv:settimeout(5)
-- Serve exactly one request then exit (test harness sends one curl).
local client = srv:accept()
if client then rpcserver.handle_client(client, token, registry) end
print("served one request")
