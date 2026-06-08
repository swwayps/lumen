package.path = "lua/?.lua;" .. package.path
local polyfill = require("polyfill")
local function has(s, sub, m) if not s:find(sub, 1, true) then error("FAIL "..(m or "")..": missing "..sub) end end

local js = polyfill.build(45123, "deadbeeftoken")
has(js, "45123", "port present")
has(js, "deadbeeftoken", "token present")
has(js, "window.Millennium", "defines Millennium")
has(js, "callServerMethod", "defines callServerMethod")
has(js, "fetch(", "uses fetch")
has(js, "/rpc", "targets /rpc")
has(js, "127.0.0.1", "loopback host")
-- Must resolve to the raw text (string), not pre-parsed JSON.
has(js, ".text()", "resolves response text")
-- Always (re)assigns so a restarted Lumen refreshes port/token; keeps latest on window.
has(js, "window.__lumenRpc", "stores latest rpc port/token on window")
has(js, "window.Millennium = window.Millennium", "guards existing Millennium namespace")
print("test_polyfill: ALL PASS")
