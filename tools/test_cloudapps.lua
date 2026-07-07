-- Run: lua5.4 tools/test_cloudapps.lua
-- The Cloud Saves tab's games list. Sources LOCAL apps from the CloudRedirect
-- storage dir (~/.config/CloudRedirect/storage/<account>/<appid>/), counting
-- save files/bytes and ignoring CloudRedirect's own metadata files. Apps are
-- returned PER ACCOUNT (a game can have a folder under more than one Steam
-- account); the frontend shows an account filter when there are 2+ accounts.
-- Account persona names are resolved from Steam's loginusers.vdf.
package.path = "lua/?.lua;" .. package.path
local cs = require("cloudsettings")
local json = require("json")

local function ok(c, m) if not c then error("FAIL: " .. (m or "")) end end
local function eq(g, w, m)
  if g ~= w then error("FAIL: " .. (m or "") .. " (got=" .. tostring(g) ..
    " want=" .. tostring(w) .. ")") end
end

-- ── parse_loginusers: SteamID64 -> accountid (32-bit) -> PersonaName ────────
do
  local vdf = [[
"users"
{
  "76561198012345678"
  {
    "AccountName"  "swayacct"
    "PersonaName"  "sway"
    "MostRecent"   "1"
  }
  "76561197960287930"
  {
    "AccountName"  "other"
    "PersonaName"  "Other Guy"
  }
}
]]
  local names = cs.parse_loginusers(vdf)
  -- accountid = steamid64 - 76561197960265728
  eq(names[76561198012345678 - 76561197960265728], "sway", "persona resolved for account 1")
  eq(names[76561197960287930 - 76561197960265728], "Other Guy", "persona resolved for account 2")
end

-- ── list_apps: per-account entries + accounts list ─────────────────────────
local root = os.tmpname(); os.remove(root)
local function mk(path) assert(os.execute("mkdir -p '" .. path .. "'")) end
local function put(path, bytes)
  local f = assert(io.open(path, "wb")); f:write(string.rep("x", bytes)); f:close()
end
mk(root)
-- account A (1052518393), app 220200: 2 save files (150 B) + metadata (ignored)
mk(root .. "/1052518393/220200/saves/default")
put(root .. "/1052518393/220200/saves/default/persistent.sfs", 100)
put(root .. "/1052518393/220200/saves/default/persistent.loadmeta", 50)
put(root .. "/1052518393/220200/file_tokens.cloudredirect", 999)
put(root .. "/1052518393/220200/cn.cloudredirect", 3)
-- account A, app 2057760: only metadata (0 real save files)
mk(root .. "/1052518393/2057760")
put(root .. "/1052518393/2057760/root_token.cloudredirect", 40)
-- app id "0" (account scope) must be skipped
mk(root .. "/1052518393/0")
put(root .. "/1052518393/0/stats.json", 10)
-- account B (720044628): the SAME app 220200 (1 file) + a unique app 650000
mk(root .. "/720044628/220200")
put(root .. "/720044628/220200/save.dat", 7)
mk(root .. "/720044628/650000")
put(root .. "/720044628/650000/save.dat", 7)

-- Pass an explicit account-names map so the accounts list is deterministic
-- (doesn't read the host's real loginusers.vdf).
local res = json.decode(cs.list_apps(root, {}))
eq(res.success, true, "list_apps success")

-- Per-account entries: NOT merged. 220200 appears once per account.
local by = {}
for _, a in ipairs(res.apps) do by[a.appid .. "@" .. a.account] = a end
ok(by["220200@1052518393"], "220200 present for account A")
eq(by["220200@1052518393"].files, 2, "220200@A: 2 files")
eq(by["220200@1052518393"].size, 150, "220200@A: 150 bytes")
ok(by["220200@720044628"], "220200 present for account B (separate entry)")
eq(by["220200@720044628"].files, 1, "220200@B: 1 file")
ok(by["2057760@1052518393"], "2057760 present (0 files)")
ok(by["650000@720044628"], "650000 present for account B")
ok(not by["0@1052518393"], "account-scope app id 0 skipped")

-- accounts list: both accounts, sorted by total save DATA desc. Account A holds
-- 150 B (real saves), account B holds 14 B, so A is the default (first).
ok(type(res.accounts) == "table" and #res.accounts == 2, "two accounts listed")
eq(res.accounts[1].id, 1052518393, "primary account (most save data) first")
eq(res.accounts[1].size, 150, "account A total bytes")
eq(res.accounts[2].id, 720044628, "second account")
eq(res.accounts[2].size, 14, "account B total bytes (7+7)")

-- Accounts known to Steam (loginusers.vdf) but with NO local saves are still
-- offered as candidates, so a fully-remote account's cloud saves are reachable.
do
  local names = { [999999] = "ghostacct" } -- an account with no local storage
  local r2 = json.decode(cs.list_apps(root, names))
  local seen = {}
  for _, a in ipairs(r2.accounts) do seen[a.id] = a end
  ok(seen[999999], "loginusers-only account is offered as a candidate")
  eq(seen[999999].files, 0, "candidate account has 0 local files")
  eq(seen[999999].name, "ghostacct", "candidate account carries its persona name")
  -- data-bearing accounts still sort ahead of the empty candidate
  eq(r2.accounts[1].id, 1052518393, "account with the most data stays default")
  eq(r2.accounts[#r2.accounts].id, 999999, "empty candidate sorts last")
end

-- a missing storage root yields empty apps, not an error (accounts may still
-- include loginusers candidates)
local empty = json.decode(cs.list_apps(root .. "/nope", {}))
eq(empty.success, true, "missing root still succeeds")
eq(#empty.apps, 0, "missing root -> no apps")
eq(#empty.accounts, 0, "missing root + no loginusers -> no accounts")

-- The frontend does `allApps = r.apps || []` then `allApps.filter(...)`. An
-- empty apps/accounts list MUST serialize as a JSON array `[]`, not an object
-- `{}` — under cjson an empty Lua table encodes as `{}` by default, which makes
-- the JS `.filter`/`.length`/default-account logic break ("allApps.filter is
-- not a function") on a clean machine with no local saves. Assert the raw
-- STRING (round-tripping through json.decode hides this).
do
  local raw = cs.list_apps(root .. "/nope", {})
  ok(raw:find('"apps"%s*:%s*%[%]'), "empty apps serializes as [] not {} (got: " .. raw .. ")")
  ok(raw:find('"accounts"%s*:%s*%[%]'), "empty accounts serializes as [] not {} (got: " .. raw .. ")")
end

os.execute("rm -rf '" .. root .. "'")
print("test_cloudapps: ALL PASS")
