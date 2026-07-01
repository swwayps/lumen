-- Host tests for fixesmenu.lua: the pure Proton-effective decision, appmanifest
-- name parse, the shallow *.exe scan, and the context() orchestration with
-- injected effects (no real fs, no plugin backend, no config.vdf).
-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_fixesmenu.lua
package.path = "lua/?.lua;" .. package.path

local fx = require("fixesmenu")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.write("FAIL: " .. name .. "\n") end
end

-- ── runs_under_proton ────────────────────────────────────────────────────────
check("proton: no exe, not forced -> false", fx.runs_under_proton(false, false) == false)
check("proton: windows exe -> true", fx.runs_under_proton(true, false) == true)
check("proton: forced tool -> true", fx.runs_under_proton(false, true) == true)
check("proton: both -> true", fx.runs_under_proton(true, true) == true)
check("proton: nils -> false", fx.runs_under_proton(nil, nil) == false)

-- ── manifest_name ────────────────────────────────────────────────────────────
check("name: parsed", fx.manifest_name('"appid" "322330"\n\t"name"\t"Don\'t Starve Together"\n') == "Don't Starve Together")
check("name: missing -> nil", fx.manifest_name('"appid" "1"') == nil)
check("name: empty -> nil", fx.manifest_name('"name" ""') == nil)
check("name: non-string -> nil", fx.manifest_name(nil) == nil)

-- ── scan_has_exe (fake fs) ────────────────────────────────────────────────────
local function fake_fs(tree)
  -- tree: { ["/dir"] = { {name=,is_directory=}, ... } }, path = dir.."/"..name
  return {
    join = function(...) local p = select(1, ...); for i = 2, select("#", ...) do p = p .. "/" .. select(i, ...) end; return p end,
    list = function(dir)
      local e = tree[dir]
      if not e then error("no such dir: " .. tostring(dir)) end
      local out = {}
      for _, it in ipairs(e) do
        out[#out + 1] = { name = it.name, path = dir .. "/" .. it.name, is_directory = it.is_directory }
      end
      return out
    end,
  }
end

local winFs = fake_fs({
  ["/games/Blasphemous 2"] = {
    { name = "Blasphemous 2.exe" }, { name = "UnityPlayer.dll" }, { name = "Data", is_directory = true },
  },
  ["/games/Blasphemous 2/Data"] = {},
})
check("scan: top-level .exe -> true", fx.scan_has_exe(winFs, "/games/Blasphemous 2") == true)

local nativeFs = fake_fs({
  ["/games/DST"] = { { name = "bin", is_directory = true }, { name = "bin64", is_directory = true }, { name = "version.txt" } },
  ["/games/DST/bin"] = { { name = "dontstarve" } },
  ["/games/DST/bin64"] = { { name = "dontstarve_steam_x64" } },
})
check("scan: native ELF, no exe -> false", fx.scan_has_exe(nativeFs, "/games/DST") == false)

local subFs = fake_fs({
  ["/games/Sub"] = { { name = "game", is_directory = true } },
  ["/games/Sub/game"] = { { name = "launcher.exe" } },
})
check("scan: .exe one level down -> true", fx.scan_has_exe(subFs, "/games/Sub") == true)
check("scan: empty path -> false", fx.scan_has_exe(winFs, "") == false)

-- ── context (all effects injected) ────────────────────────────────────────────
local function ctx(appid, opts)
  opts = opts or {}
  return fx.context(appid, {
    fs = opts.fs or winFs,
    resolve_install = opts.resolve or function() return { success = true, installPath = "/games/Blasphemous 2", libraryPath = "/lib" } end,
    read_file = opts.read or function() return '"name" "Blasphemous 2"' end,
    is_forced = opts.forced or function() return false end,
  })
end

local r1 = ctx(2114740)
check("ctx: installed", r1.isInstalled == true)
check("ctx: name from manifest", r1.gameName == "Blasphemous 2")
check("ctx: windows build -> runsUnderProton", r1.runsUnderProton == true)
check("ctx: appid coerced", r1.appid == 2114740)

local r2 = ctx(322330, { fs = nativeFs,
  resolve = function() return { success = true, installPath = "/games/DST", libraryPath = "/lib" } end,
  forced = function() return false end })
check("ctx: native + no force -> not Proton", r2.runsUnderProton == false)

local r3 = ctx(322330, { fs = nativeFs,
  resolve = function() return { success = true, installPath = "/games/DST", libraryPath = "/lib" } end,
  forced = function() return true end })
check("ctx: native + forced Proton -> Proton", r3.runsUnderProton == true)

local r4 = ctx(999, { resolve = function() return { success = false, error = "menu.error.notInstalled" } end })
check("ctx: not installed", r4.isInstalled == false and r4.success == true)

local r5 = fx.context("notanumber", {})
check("ctx: bad appid -> error", r5.success == false)

-- ── plugin prefs ──────────────────────────────────────────────────────────────
-- load defaults when no file
local function noreadDeps() return { read_file = function() return nil end, decode = function() return nil end } end
local p0 = fx.load_prefs(noreadDeps())
check("prefs: default enabled true", p0.fixes_menu_enabled == true)

-- load honours a stored false
local pf = fx.load_prefs({ read_file = function() return '{"fixes_menu_enabled":false}' end,
  decode = function(s) if s:find("false") then return { fixes_menu_enabled = false } end return { fixes_menu_enabled = true } end })
check("prefs: stored false honoured", pf.fixes_menu_enabled == false)

-- save round-trip via injected writer/encoder
local written = {}
local function saveDeps()
  return {
    read_file = function() return nil end,            -- start from defaults
    decode = function() return nil end,
    encode = function(t) return (t.fixes_menu_enabled and "T" or "F") end,
    write_file = function(_, s) written.s = s; return true end,
  }
end
local ok_save = fx.save_pref("fixes_menu_enabled", false, saveDeps())
check("prefs: save returns true", ok_save == true)
check("prefs: save wrote disabled", written.s == "F")
local ok_save2 = fx.save_pref("fixes_menu_enabled", true, saveDeps())
check("prefs: save wrote enabled", written.s == "T" and ok_save2 == true)

-- ── added_apps (canonical: SLSsteam AdditionalApps) ───────────────────────────
local CFG = table.concat({
  "PlayNotOwnedGames: no",
  "AdditionalApps:",
  "  - 284160   # BeamNG.drive",
  "  - 2050650   # added via LuaTools",
  "  # a comment line inside the block",
  "  - 1030300",
  "  - 2050650   # duplicate ignored",
  "LogLevel: 2",
  "  - 999   # NOT in the block anymore (after next key)",
}, "\n")

local pa = fx.parse_additional_apps(CFG)
table.sort(pa)
check("addl: parses block ids", pa[1] == 284160 and pa[2] == 1030300 and pa[3] == 2050650)
check("addl: dedups + stops at next key", #pa == 3)
check("addl: non-string -> empty", #fx.parse_additional_apps(nil) == 0)
check("addl: no block -> empty", #fx.parse_additional_apps("LogLevel: 2\n") == 0)

-- added_apps reads config via injected text
local aa = fx.added_apps({ config_text = CFG })
table.sort(aa)
check("added: from injected config_text", aa[1] == 284160 and #aa == 3)

-- added_apps reads config via injected path + read_file
local aa2 = fx.added_apps({ config_path = "/fake/config.yaml",
  read_file = function(p) return (p == "/fake/config.yaml") and "AdditionalApps:\n  - 42910\n" or nil end })
check("added: from injected path", aa2[1] == 42910 and #aa2 == 1)

-- missing config -> empty (not an error)
local aa3 = fx.added_apps({ config_path = "/x", read_file = function() return nil end })
check("added: missing config -> empty", type(aa3) == "table" and #aa3 == 0)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
