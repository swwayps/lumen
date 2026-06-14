-- Run: lua5.4 tools/test_slsconfig.lua
-- Pure tests for the SLSsteam config.yaml reader/writer used by the Lumen
-- settings menu (the "slsteam-moon" tab). slsconfig parses the scalar keys
-- slsteam-moon understands (see SLSsteam-fork src/config.cpp loadSettings) and
-- writes a single key back while preserving comments, ordering and unrelated
-- keys (yaml-cpp is whitespace tolerant; humans and their comments are not).
package.path = "lua/?.lua;" .. package.path
local slsconfig = require("slsconfig")

local function assert_eq(got, want, msg)
  if got ~= want then
    error("FAIL: " .. (msg or "") .. " (got=" .. tostring(got) ..
          " want=" .. tostring(want) .. ")")
  end
end
local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end

local SAMPLE = [[
#Disables Family Share license locking
DisableFamilyShareLock: yes

#Switches to whitelist instead of the default blacklist
UseWhitelist: no

PlayNotOwnedGames: yes

#Toggles notifications via notify-send
Notifications: no

FakeEmail: ""

FakeWalletBalance: 0

#Log levels: Once=0 Debug=1 Info=2 ... None=6
LogLevel: 2

ExtendedLogging: no
]]

-- ── parse() typing ─────────────────────────────────────────────────────────
do
  local v = slsconfig.parse(SAMPLE)
  assert_eq(v.DisableFamilyShareLock, true,  "yes -> true")
  assert_eq(v.UseWhitelist,           false, "no -> false")
  assert_eq(v.PlayNotOwnedGames,      true,  "yes -> true")
  assert_eq(v.Notifications,          false, "no -> false")
  assert_eq(v.FakeEmail,              "",    "empty quoted string")
  assert_eq(v.FakeWalletBalance,      0,     "int 0")
  assert_eq(v.LogLevel,               2,     "enum/int 2")
  assert_eq(v.ExtendedLogging,        false, "no -> false")
end

-- ── parse() defaults when a key is absent ──────────────────────────────────
do
  -- API defaults to true, DisableCloud to true, SafeMode to false per config.cpp.
  local v = slsconfig.parse("LogLevel: 2\n")
  assert_eq(v.API,          true,  "API default true")
  assert_eq(v.DisableCloud, true,  "DisableCloud default true")
  assert_eq(v.SafeMode,     false, "SafeMode default false")
  assert_eq(v.LogLevel,     2,     "LogLevel read")
end

-- ── parse() accepts the various YAML boolean spellings ─────────────────────
do
  local v = slsconfig.parse("DisableFamilyShareLock: true\nUseWhitelist: Off\nAPI: N\n")
  assert_eq(v.DisableFamilyShareLock, true,  "true -> true")
  assert_eq(v.UseWhitelist,           false, "Off -> false")
  assert_eq(v.API,                    false, "N -> false")
end

-- ── set_key() replaces a bool, preserving everything else ──────────────────
do
  local out = slsconfig.set_key(SAMPLE, "PlayNotOwnedGames", false)
  assert_true(out:find("PlayNotOwnedGames: no", 1, true), "bool written as no")
  assert_true(not out:find("PlayNotOwnedGames: yes", 1, true), "old value gone")
  -- Unrelated keys + comments untouched.
  assert_true(out:find("#Toggles notifications via notify%-send"), "comment kept")
  assert_true(out:find("Notifications: no", 1, true), "neighbour key kept")
  assert_true(out:find("DisableFamilyShareLock: yes", 1, true), "other key kept")
  -- Round-trips through parse.
  assert_eq(slsconfig.parse(out).PlayNotOwnedGames, false, "round-trips false")
end

-- ── set_key() preserves a trailing inline comment on the edited line ───────
do
  local txt = "SafeMode: no   # keep me\n"
  local out = slsconfig.set_key(txt, "SafeMode", true)
  assert_true(out:find("SafeMode: yes", 1, true), "value updated")
  assert_true(out:find("# keep me", 1, true), "inline comment preserved")
end

-- ── set_key() writes a quoted string ───────────────────────────────────────
do
  local out = slsconfig.set_key(SAMPLE, "FakeEmail", "a@b.com")
  assert_true(out:find('FakeEmail: "a@b.com"', 1, true), "string quoted")
  assert_eq(slsconfig.parse(out).FakeEmail, "a@b.com", "string round-trips")
end

-- ── set_key() writes an integer ─────────────────────────────────────────────
do
  local out = slsconfig.set_key(SAMPLE, "FakeWalletBalance", 4999)
  assert_true(out:find("FakeWalletBalance: 4999", 1, true), "int written")
  assert_eq(slsconfig.parse(out).FakeWalletBalance, 4999, "int round-trips")
end

-- ── set_key() appends a missing key rather than corrupting the file ────────
do
  local txt = "LogLevel: 2\n"
  local out = slsconfig.set_key(txt, "API", false)
  assert_true(out:find("LogLevel: 2", 1, true), "existing key kept")
  assert_true(out:find("API: no", 1, true), "missing key appended")
  assert_eq(slsconfig.parse(out).API, false, "appended key round-trips")
end

-- ── set_key() does not match a key that is a prefix of another ─────────────
do
  -- "API" must not accidentally edit "FakeAppIds"/other; and editing one key
  -- must touch exactly one line.
  local txt = "Notifications: yes\nNotifyInit: yes\n"
  local out = slsconfig.set_key(txt, "Notifications", false)
  assert_true(out:find("Notifications: no", 1, true), "target edited")
  assert_true(out:find("NotifyInit: yes", 1, true), "prefix-sibling untouched")
end

-- ── default_path() resolves under HOME ──────────────────────────────────────
do
  local saved = os.getenv("HOME")
  -- We can't setenv from plain Lua portably; just assert it ends correctly when
  -- HOME is present (the CI/host always has HOME).
  if saved and saved ~= "" then
    assert_eq(slsconfig.default_path(), saved .. "/.config/SLSsteam/config.yaml",
      "default_path under HOME")
  end
end

-- ── read() + write_key() round-trip against a real temp file ───────────────
do
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "wb"))
  f:write("PlayNotOwnedGames: no\nLogLevel: 2\n")
  f:close()

  local v = slsconfig.read(tmp)
  assert_eq(v.PlayNotOwnedGames, false, "read sees no")
  assert_eq(v.LogLevel, 2, "read sees 2")

  local ok, err = slsconfig.write_key(tmp, "PlayNotOwnedGames", true)
  assert_true(ok, "write_key ok: " .. tostring(err))
  assert_eq(slsconfig.read(tmp).PlayNotOwnedGames, true, "persisted true")
  assert_eq(slsconfig.read(tmp).LogLevel, 2, "neighbour persisted")

  os.remove(tmp)
end

-- ── read() of a missing file yields defaults, not an error ─────────────────
do
  local v = slsconfig.read("/nonexistent/path/zzz/config.yaml")
  assert_eq(v.API, true, "missing file -> defaults")
end

-- ── write_key() REFUSES to clobber an empty/unreadable config ──────────────
-- Regression: a racy/empty read previously made set_key "append" the key to an
-- empty string, replacing a 111-line config with a 2-line file (data loss).
-- write_key must refuse rather than destroy the file.
do
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "wb")); f:write(""); f:close()  -- empty file
  local ok, err = slsconfig.write_key(tmp, "ExtendedLogging", true)
  assert_true(not ok, "write_key refuses empty config")
  local rf = io.open(tmp, "rb"); local body = rf:read("*a"); rf:close()
  assert_eq(body, "", "empty file left untouched (not turned into 2 lines)")
  os.remove(tmp)
end

-- ── write_key() REFUSES to append a key to a non-config (too few known keys) ─
do
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "wb")); f:write("garbage line\n"); f:close()
  local ok = slsconfig.write_key(tmp, "ExtendedLogging", true)
  assert_true(not ok, "write_key refuses to append to a non-config blob")
  local rf = io.open(tmp, "rb"); local body = rf:read("*a"); rf:close()
  assert_true(not body:find("ExtendedLogging"), "nothing appended to garbage")
  os.remove(tmp)
end

-- ── write_key() still EDITS an existing key in a valid config ───────────────
do
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "wb"))
  -- a config with several known keys present
  f:write("DisableFamilyShareLock: yes\nUseWhitelist: no\nPlayNotOwnedGames: no\nLogLevel: 2\n")
  f:close()
  local ok = slsconfig.write_key(tmp, "PlayNotOwnedGames", true)
  assert_true(ok, "edit allowed on a valid config")
  assert_eq(slsconfig.read(tmp).PlayNotOwnedGames, true, "edit persisted")
  os.remove(tmp)
end

-- ── write_key() leaves no temp file behind ─────────────────────────────────
do
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "wb"))
  f:write("DisableFamilyShareLock: yes\nUseWhitelist: no\nLogLevel: 2\n")
  f:close()
  slsconfig.write_key(tmp, "LogLevel", 5)
  -- The old fixed temp name must not survive (would race other writers).
  assert_true(io.open(tmp .. ".tmp.lumen", "rb") == nil, "no fixed temp left behind")
  os.remove(tmp)
end

print("test_slsconfig: ALL PASS")
