-- boot: load the LuaTools backend behind the shims, then run the injector loop.
local backend = os.getenv("LUMEN_BACKEND_DIR")
assert(backend and backend ~= "", "LUMEN_BACKEND_DIR not set")
package.path = backend .. "/?.lua;" .. package.path

-- Loading main.lua defines the global RPC functions (InitApis, etc.) and returns
-- a lifecycle table { on_load, on_unload, on_frontend_loaded }. Millennium called
-- on_load after requiring the plugin; we do the same so inject_webkit_files()
-- enqueues the frontend assets and the boot-time InitApis runs.
local lifecycle = dofile(backend .. "/main.lua")
if type(lifecycle) == "table" and type(lifecycle.on_load) == "function" then
  local ok, err = pcall(lifecycle.on_load)
  if not ok then io.stderr:write("[lumen] on_load error: " .. tostring(err) .. "\n") end
end

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

-- build_assets() -> { polyfill=, css={...}, js={...} }  (binding transport; no port/token)
local function build_assets()
  local css, js = {}, {}
  for _, p in ipairs(millennium.queued_css()) do
    local c = read_asset(p); if c then css[#css + 1] = c end
  end
  for _, p in ipairs(millennium.queued_js()) do
    local j = read_asset(p); if j then js[#js + 1] = j end
  end
  return { polyfill = polyfill.build(), css = css, js = js }
end

-- The Lumen settings menu (the full-moon button + settings overlay) is a small,
-- well-behaved script injected into the main client shell (SharedJSContext) —
-- NOT luatools.js, which must never go there (see the channel split below). It
-- talks to the same backend via the same binding polyfill. Register its two
-- native RPCs (read/write slsteam-moon's config.yaml) into the dispatch table.
require("slsmenu").register(registry)

local lua_dir = os.getenv("LUMEN_LUA_DIR") or "lua"

local function read_menu_js()
  local menu_js = utils.read_file(lua_dir .. "/lumen_menu.js")
  if not menu_js then
    io.stderr:write("[lumen] WARN: lumen_menu.js not found in " .. lua_dir .. "\n")
  end
  return menu_js
end

-- build_menu_assets() -> assets for the main window ("Steam"): polyfill +
-- lumen_menu.js (the full-moon button + settings overlay).
local function build_menu_assets()
  local js = {}
  local menu_js = read_menu_js()
  if menu_js then js[#js + 1] = menu_js end
  return { polyfill = polyfill.build(), css = {}, js = js }
end

-- build_webview_assets() -> the store/community bundle: the LuaTools webkit
-- frontend PLUS lumen_menu.js. The menu script is injected here too (in addition
-- to the main window) so the settings overlay can render natively inside the web
-- view that's on top — store/community views composite ABOVE the main-window
-- DOM, so an overlay in the main window alone would be hidden behind them and
-- couldn't receive input. lumen_menu.js adds no menubar button here (there's no
-- menubar in a web view); it only exposes window.__lumenOpenOverlay so the
-- sidecar can open/close it on demand. See injector State:broadcast_overlay.
local function build_webview_assets()
  local base = build_assets()
  local menu_js = read_menu_js()
  if menu_js then base.js[#base.js + 1] = menu_js end
  return base
end

local loop = require("loop")
-- Injection channels:
--   * web views (store/community)  -> luatools.js + lumen_menu.js
--   * the main client window ("Steam")  -> lumen_menu.js (carries the menubar
--     button next to Help)
-- The native menubar (Steam/View/Friends/Games/Help) lives in the main window
-- target titled "Steam". luatools.js must NEVER reach the main window: it
-- monkey-patches history.pushState, observes document.body and runs periodic
-- DOM scans the React shell never expects, which breaks the menubar. The
-- lumen_menu.js bundle is deliberately minimal and shell-safe. The menubar
-- button broadcasts open/close to every context so the overlay renders in
-- whichever view is currently on top (see injector State:broadcast_overlay).
loop.run({
  registry = registry,
  channels = {
    { urls = { "store.steampowered.com", "steamcommunity.com" }, assets = build_webview_assets() },
    { titles = { ["Steam"] = true }, assets = build_menu_assets() },
    -- Control-only link to SharedJSContext (NO assets injected): the only context
    -- with SteamClient. Used to relay SteamClient.Apps.SetAppLaunchOptions on
    -- behalf of the store-page online-fix flow (which can't reach SteamClient).
    { titles = { ["SharedJSContext"] = true }, control = true },
  },
})
