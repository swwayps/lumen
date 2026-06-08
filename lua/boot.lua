-- boot: load the LuaTools backend behind the shims, then run the unified loop.
local backend = os.getenv("LUMEN_BACKEND_DIR")
assert(backend and backend ~= "", "LUMEN_BACKEND_DIR not set")
package.path = backend .. "/?.lua;" .. package.path

-- Ensure Lumen's state dir exists (for session.json).
local home = os.getenv("HOME") or "."
local state_dir = home .. "/.local/share/Lumen"
os.execute("mkdir -p '" .. state_dir .. "'")

-- Loading main.lua defines the global RPC functions (InitApis, etc.) and, via
-- on_load/inject_webkit_files, enqueues the frontend assets in the millennium shim.
dofile(backend .. "/main.lua")

-- Dispatch registry: the 35 endpoints the frontend calls via callServerMethod.
local ALLOWLIST = {
  "AddCustomApi","ApplyGameFix","ApplySettingsChanges","CancelAddViaLuaTools",
  "CancelApplyFix","CheckApisForApp","CheckForFixes","CheckForUpdatesNow",
  "DeleteLuaToolsForApp","DismissLoadedApps","FetchFreeApisNow",
  "GetAddViaLuaToolsStatus","GetAllApis","GetApiList","GetApplyFixStatus",
  "GetGameInstallPath","GetGamesDatabase","GetIconDataUrl","GetInitApisMessage",
  "GetInstalledFixes","GetInstalledLuaScripts","GetMorrenusStats",
  "GetSettingsConfig","GetThemes","GetTranslations","GetUnfixStatus",
  "HasLuaToolsForApp","OpenExternalUrl","OpenGameFolder","ReadLoadedApps",
  "RemoveApi","RenameApi","ReorderApis","RestartSteam","ToggleApi","UnFixGame",
  "StartAddViaLuaTools",
}

local registry = {}
local present = {}
for _, name in ipairs(ALLOWLIST) do
  if type(_G[name]) == "function" then
    registry[name] = _G[name]; present[name] = true
  else
    io.stderr:write("[lumen] WARN: allowlisted endpoint missing: " .. name .. "\n")
  end
end
-- Safety net: expose any other PascalCase global function, logged.
for k, v in pairs(_G) do
  if type(v) == "function" and k:match("^%u") and not present[k] then
    registry[k] = v
    io.stderr:write("[lumen] note: extra endpoint exposed (not in allowlist): " .. k .. "\n")
  end
end

-- Frontend assets: the millennium shim queued relative paths (e.g.
-- "webkit/luatools.js") during inject_webkit_files; the files live in the
-- plugin's public/ dir (sibling of backend/). Read them for injection.
local millennium = require("millennium")
local utils = require("utils")
local polyfill = require("polyfill")
local plugin_dir = backend:gsub("/backend$", "")

local function read_asset(rel)
  local base = rel:gsub("^webkit/", "")
  return utils.read_file(plugin_dir .. "/public/" .. base)
end

-- build_assets(port, token) -> { polyfill=, css={...}, js={...} }
local function build_assets(port, token)
  local css, js = {}, {}
  for _, p in ipairs(millennium.queued_css()) do
    local c = read_asset(p); if c then css[#css + 1] = c end
  end
  for _, p in ipairs(millennium.queued_js()) do
    local j = read_asset(p); if j then js[#js + 1] = j end
  end
  return { polyfill = polyfill.build(port, token), css = css, js = js }
end

local loop = require("loop")
loop.run({
  session_path = state_dir .. "/session.json",
  registry = registry,
  build_assets = build_assets,
})
