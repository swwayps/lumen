-- Run: lua5.4 tools/test_json.lua
-- The json shim's pure-Lua fallback (used on hosts without cjson) MUST fail
-- cleanly on malformed input — never hang. A truncated object like "{not json"
-- previously sent parse_string reading past EOF forever (OOM). decode must
-- raise (so callers' pcall can catch it), matching cjson's behaviour.
package.path = "lua/?.lua;" .. package.path
local json = require("json")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end

-- ── well-formed round-trips still work ─────────────────────────────────────
do
  local v = json.decode('{"a":1,"b":[true,false,null],"c":"x"}')
  assert_true(v.a == 1, "number")
  assert_true(v.b[1] == true and v.b[2] == false, "array bools")
  assert_true(v.c == "x", "string")
end

-- ── malformed inputs raise instead of hanging ──────────────────────────────
local BAD = {
  "{not json",          -- key not a quoted string, no close
  '{"a":',              -- value missing
  '"unterminated',      -- string never closes
  "[1,2",               -- array never closes
  '{"a":1',             -- object never closes
}
for _, s in ipairs(BAD) do
  local ok = pcall(json.decode, s)
  assert_true(not ok, "decode must raise on malformed input: " .. s)
end

print("test_json: ALL PASS")
