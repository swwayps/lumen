package.path = "lua/?.lua;" .. package.path
local polyfill = require("polyfill")
local function has(s, sub, m) if not s:find(sub, 1, true) then error("FAIL "..(m or "")..": missing "..sub) end end

local js = polyfill.build(45123, "deadbeeftoken")
has(js, "127.0.0.1:45123", "port interpolated")
has(js, "deadbeeftoken", "token interpolated")
has(js, "window.Millennium", "defines Millennium")
has(js, "callServerMethod", "defines callServerMethod")
has(js, "fetch(", "uses fetch")
has(js, "/rpc", "targets /rpc")
-- Must resolve to the raw text (string), not pre-parsed JSON.
has(js, ".text()", "resolves response text")
-- Idempotent define (don't clobber if already present).
has(js, "window.Millennium = window.Millennium", "guards existing Millennium")
print("test_polyfill: ALL PASS")
