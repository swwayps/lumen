-- Run: lua5.4 tools/test_slsmenu.lua
-- Tests the Lumen settings-menu RPC layer (GetSlsConfig / SetSlsConfig). These
-- back the "slsteam-moon" tab: GetSlsConfig returns {schema, values} for the
-- frontend to render; SetSlsConfig persists one key to config.yaml. Both return
-- JSON strings (the upstream callServerMethod convention the polyfill expects).
package.path = "lua/?.lua;" .. package.path
local slsmenu = require("slsmenu")
local json = require("json")

local function assert_eq(got, want, msg)
  if got ~= want then
    error("FAIL: " .. (msg or "") .. " (got=" .. tostring(got) ..
          " want=" .. tostring(want) .. ")")
  end
end
local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end

local function write_tmp(contents)
  local p = os.tmpname()
  local f = assert(io.open(p, "wb")); f:write(contents); f:close()
  return p
end

-- ── get() returns schema + current values as a JSON string ─────────────────
do
  local p = write_tmp("PlayNotOwnedGames: yes\nLogLevel: 1\n")
  local res = json.decode(slsmenu.get(p))
  assert_eq(res.success, true, "get success")
  assert_true(type(res.schema) == "table" and #res.schema > 0, "schema present")
  assert_eq(res.values.PlayNotOwnedGames, true, "value reflected")
  assert_eq(res.values.LogLevel, 1, "loglevel reflected")
  os.remove(p)
end

-- ── set() persists one bool key and reports success ────────────────────────
do
  local p = write_tmp("PlayNotOwnedGames: no\nLogLevel: 2\n")
  local res = json.decode(slsmenu.set(p, json.encode({ key = "PlayNotOwnedGames", value = true })))
  assert_eq(res.success, true, "set success")
  -- Re-read through get() to confirm persistence.
  local after = json.decode(slsmenu.get(p))
  assert_eq(after.values.PlayNotOwnedGames, true, "persisted")
  assert_eq(after.values.LogLevel, 2, "neighbour untouched")
  os.remove(p)
end

-- ── set() persists the int LogLevel ────────────────────────────────────────
do
  local p = write_tmp("LogLevel: 2\n")
  slsmenu.set(p, json.encode({ key = "LogLevel", value = 5 }))
  assert_eq(json.decode(slsmenu.get(p)).values.LogLevel, 5, "loglevel persisted")
  os.remove(p)
end

-- ── set() refuses an unknown key (no arbitrary writes) ─────────────────────
do
  local p = write_tmp("LogLevel: 2\n")
  local res = json.decode(slsmenu.set(p, json.encode({ key = "rm -rf", value = 1 })))
  assert_eq(res.success, false, "unknown key rejected")
  -- File is unchanged: the bogus key was not appended.
  local f = io.open(p, "rb"); local body = f:read("*a"); f:close()
  assert_true(not body:find("rm -rf", 1, true), "bogus key not written")
  os.remove(p)
end

-- ── set() with malformed JSON fails gracefully ─────────────────────────────
do
  local p = write_tmp("LogLevel: 2\n")
  local res = json.decode(slsmenu.set(p, "{not json"))
  assert_eq(res.success, false, "bad json rejected")
  os.remove(p)
end

print("test_slsmenu: ALL PASS")
