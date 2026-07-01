-- fixesmenu.lua — Lumen backend support for the library-page "Fixes Menu".
--
-- The menu (menu/10-fixes-menu.js) lives next to the gear button on a game's
-- library page and reuses the LuaTools fix RPCs already in the shared dispatch
-- registry (CheckForFixes, ResolveOnlineFix, ApplySpaceFix, ApplyGameFix,
-- GetApplyFixStatus, UnFixGame, OpenGameFolder, OpenExternalUrl). This module
-- adds the ONE thing those don't cover for the library context: a single
-- round-trip "context" call returning the game's install path, installed
-- state, name, and whether a Windows DLL fix can actually load.
--
-- Why "runs under Proton" instead of "is native":
--   A Windows crack / online fix is a bundle of Windows DLLs that only load
--   under Proton/Wine. slsteam-moon injects a Proton CompatToolMapping for
--   titles with no native Linux depot, so every client-side OS signal is
--   polluted (appStore overview is_available_on_current_platform == true and
--   appDetailsStore vecPlatforms includes "linux" for BOTH a native title and
--   a Windows-only title run via Proton — verified on the Zorin VM). So the
--   operationally meaningful question is "will this game run under Proton?",
--   answered from two pollution-free local signals:
--     * the user forced a Proton/compat tool       -> protoncompat (config.vdf)
--     * the installed build ships Windows *.exe     -> install-dir scan
--   Either one => the game runs under Proton => the fix can load. A native
--   Linux build with no forced tool ships ELF executables and no *.exe, so the
--   menu can warn that the fix won't take effect until Proton is forced.
--
-- The pure helpers (runs_under_proton, manifest_name) are unit-tested
-- (tools/test_fixesmenu.lua); context() is the impure entry point.

local fixesmenu = {}

-- PURE: a Windows DLL fix loads iff the game runs under Proton, i.e. it ships a
-- Windows build (*.exe present) OR the user forced a Proton/compat tool.
function fixesmenu.runs_under_proton(has_exe, forced)
  return (has_exe and true or false) or (forced and true or false)
end

-- PURE: pull the display name out of an appmanifest_<id>.acf blob.
function fixesmenu.manifest_name(acf)
  if type(acf) ~= "string" then return nil end
  local n = acf:match('"name"%s+"([^"]*)"')
  if n == nil or n == "" then return nil end
  return n
end

-- Shallow scan for a Windows executable: the install root + its immediate
-- subdirectories, stopping at the first *.exe. Cheap (a couple of dir reads),
-- and a Windows game's primary .exe is almost always at the top level or one
-- folder down (verified: "Blasphemous 2/Blasphemous 2.exe"). `fs` is the shim.
function fixesmenu.scan_has_exe(fs, dir)
  if not dir or dir == "" then return false end
  local ok, entries = pcall(fs.list, dir)
  if not ok or type(entries) ~= "table" then return false end
  local subdirs = {}
  for _, e in ipairs(entries) do
    local name = (e.name or "")
    if name:lower():match("%.exe$") then return true end
    if e.is_directory then subdirs[#subdirs + 1] = e.path end
  end
  for _, sub in ipairs(subdirs) do
    local ok2, se = pcall(fs.list, sub)
    if ok2 and type(se) == "table" then
      for _, e in ipairs(se) do
        if (e.name or ""):lower():match("%.exe$") then return true end
      end
    end
  end
  return false
end

-- context(appid, deps) -> table for the LumenFixesContext RPC. `deps` is
-- injectable for tests; in production everything is resolved from the plugin
-- backend modules already on package.path (boot.lua prepends backend/?.lua).
--   {
--     success, appid,
--     isInstalled, installPath,
--     gameName,            -- from the appmanifest (nil/"" if unknown)
--     runsUnderProton,     -- bool: a Windows DLL fix can load
--   }
function fixesmenu.context(appid, deps)
  appid = math.tointeger(tonumber(appid))
  if not appid then return { success = false, error = "invalid appid" } end
  deps = deps or {}

  local fs_mod = deps.fs or require("fs")
  local read_file = deps.read_file or function(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
  end

  -- Install path + library path (reuse the plugin's resolver unless injected).
  local resolve = deps.resolve_install
  if not resolve then
    local ok, su = pcall(require, "steam_utils")
    if ok and su and su.get_game_install_path_response then
      resolve = function(id) return su.get_game_install_path_response(id) end
    end
  end
  local info = resolve and resolve(appid) or nil

  local res = {
    success = true,
    appid = appid,
    isInstalled = false,
    installPath = "",
    gameName = "",
    runsUnderProton = false,
  }

  if type(info) == "table" and info.success and info.installPath and info.installPath ~= "" then
    res.isInstalled = true
    res.installPath = info.installPath
    -- Name from the appmanifest (libraryPath/steamapps/appmanifest_<id>.acf).
    if info.libraryPath and info.libraryPath ~= "" then
      local acf_path = fs_mod.join(info.libraryPath, "steamapps", "appmanifest_" .. tostring(appid) .. ".acf")
      local acf = read_file(acf_path)
      local name = fixesmenu.manifest_name(acf)
      if name then res.gameName = name end
    end
    -- Proton-effective: Windows build present OR a forced compat tool.
    local has_exe = fixesmenu.scan_has_exe(fs_mod, info.installPath)
    local forced = false
    local is_forced = deps.is_forced
    if not is_forced then
      local ok, pc = pcall(require, "protoncompat")
      if ok and pc and pc.is_forced then
        is_forced = function(id) return pc.is_forced(nil, id) end
      end
    end
    if is_forced then
      local ok2, f = pcall(is_forced, appid)
      forced = ok2 and f or false
    end
    res.runsUnderProton = fixesmenu.runs_under_proton(has_exe, forced)
  end

  return res
end

-- ── added apps (canonical: SLSsteam AdditionalApps) ─────────────────────────
-- The Fixes Menu is only meaningful for games slsteam-moon manages. The
-- CANONICAL registry of those is the AdditionalApps list in the SLSsteam
-- config.yaml (every added game is registered there — LuaTools, "Load .lua",
-- and manual adds alike). The stplug-in <appid>.lua files are only the subset
-- that carries depot keys, so we key off AdditionalApps instead. The frontend
-- fetches this set once (cached) and only anchors the entry for appids in it.

-- PURE: extract appids from the AdditionalApps block of a config.yaml body.
-- Handles the block-list form (the only form slsteam-moon's editor writes):
--   AdditionalApps:
--     - 284160   # comment
-- The block ends at the next top-level key (a non-indented, non-comment line).
function fixesmenu.parse_additional_apps(text)
  local out, seen = {}, {}
  if type(text) ~= "string" or text == "" then return out end
  local in_block = false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^AdditionalApps%s*:") then
      in_block = true
    elseif in_block then
      if line:match("^%S") and not line:match("^%s*#") then
        in_block = false                       -- next top-level key ends the block
      else
        local id = line:match("^%s*%-%s*(%d+)")
        local num = id and math.tointeger(tonumber(id))
        if num and not seen[num] then seen[num] = true; out[#out + 1] = num end
      end
    end
  end
  return out
end

-- added_apps(deps) -> list of managed appids from AdditionalApps. deps
-- injectable for tests (config_text or config_path + read_file).
function fixesmenu.added_apps(deps)
  deps = deps or {}
  local text = deps.config_text
  if text == nil then
    local config_path = deps.config_path
    if not config_path then
      local ok, mp = pcall(require, "manifestpins")
      if ok and mp and mp.default_ctx then
        local c = mp.default_ctx(); config_path = c and c.config_path
      end
    end
    if config_path then
      local read_file = deps.read_file or function(p)
        local f = io.open(p, "rb"); if not f then return nil end
        local d = f:read("*a"); f:close(); return d
      end
      text = read_file(config_path)
    end
  end
  return fixesmenu.parse_additional_apps(text or "")
end

-- ── plugin prefs (Lumen-level, not slsteam-moon config) ─────────────────────
-- A tiny JSON store at ~/.local/share/Lumen/plugin_prefs.json for plugin UI
-- toggles. Currently: fixes_menu_enabled (show the library-page Fixes Menu).

local function prefs_path()
  return (os.getenv("HOME") or "") .. "/.local/share/Lumen/plugin_prefs.json"
end

local function default_prefs()
  return { fixes_menu_enabled = true }
end

-- load_prefs(deps) -> prefs table (defaults merged). deps injectable for tests.
function fixesmenu.load_prefs(deps)
  deps = deps or {}
  local read_file = deps.read_file or function(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
  end
  local decode = deps.decode
  if not decode then
    local ok, json = pcall(require, "json")
    if ok and json and json.decode then
      decode = function(s) local o, r = pcall(json.decode, s); return o and r or nil end
    end
  end
  local prefs = default_prefs()
  local raw = read_file(deps.path or prefs_path())
  if raw and raw ~= "" and decode then
    local t = decode(raw)
    if type(t) == "table" and type(t.fixes_menu_enabled) == "boolean" then
      prefs.fixes_menu_enabled = t.fixes_menu_enabled
    end
  end
  return prefs
end

-- save_pref(key, value, deps) -> bool. Read-modify-write the prefs JSON.
function fixesmenu.save_pref(key, value, deps)
  deps = deps or {}
  local prefs = fixesmenu.load_prefs(deps)
  if key == "fixes_menu_enabled" then
    prefs.fixes_menu_enabled = (value and true or false)
  end
  local encode = deps.encode
  if not encode then
    local ok, json = pcall(require, "json")
    if ok and json and json.encode then encode = json.encode end
  end
  if not encode then return false, prefs end
  local writer = deps.write_file or function(p, s)
    local f = io.open(p, "wb"); if not f then return false end
    f:write(s); f:close(); return true
  end
  return writer(deps.path or prefs_path(), encode(prefs)) and true or false, prefs
end

-- register(registry): install LumenFixesContext, wrapping the table-returning
-- core in JSON encoding (the dispatch contract). The dispatch maps the JS args
-- object to alphabetical positional args, so {appid} arrives as the first arg;
-- tolerate the table form too.
function fixesmenu.register(registry)
  local json = require("json")
  registry.LumenFixesContext = function(appid)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(fixesmenu.context, appid)
    if not ok then return json.encode({ success = false, error = tostring(res) }) end
    return json.encode(res)
  end
  -- The set of managed appids (SLSsteam AdditionalApps — the canonical registry
  -- of added games); the frontend only shows the Fixes Menu for these.
  registry.LumenAddedApps = function()
    local ok, apps = pcall(fixesmenu.added_apps)
    if not ok then return json.encode({ success = false, error = tostring(apps) }) end
    return json.encode({ success = true, appids = apps })
  end
  -- Plugin prefs (Fixes Menu enable toggle in the Lumen settings "Plugin" row).
  registry.LumenGetPluginPrefs = function()
    local ok, prefs = pcall(fixesmenu.load_prefs)
    if not ok then return json.encode({ success = false, error = tostring(prefs) }) end
    return json.encode({ success = true, prefs = prefs })
  end
  registry.LumenSetPluginPref = function(key, value)
    -- alphabetical positional: {key, value} -> (key, value); tolerate table.
    if type(key) == "table" then value = key.value; key = key.key end
    local ok, saved = pcall(fixesmenu.save_pref, tostring(key), value)
    return json.encode({ success = (ok and saved) and true or false })
  end
  return registry
end

return fixesmenu
