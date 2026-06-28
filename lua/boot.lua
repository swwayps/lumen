-- boot: load the LuaTools backend behind the shims, then run the injector loop.
--
-- The LuaTools plugin backend is OPTIONAL. A `--noplugin` install ships only the
-- runtime stack (slsteam-moon + Lumen) and Lumen's OWN settings menu (the full-
-- moon button: slsteam-moon config, Game Updates / manifest pins, About), with
-- no LuaTools frontend and no plugin backend on disk. So load the backend only
-- when it's actually present; when it isn't, run in "settings-menu only" mode
-- instead of aborting the whole sidecar (an unguarded dofile of a missing
-- main.lua used to kill Lumen at boot, taking the menu down with it).
local backend = os.getenv("LUMEN_BACKEND_DIR") or ""
local have_plugin = false
local lifecycle

if backend ~= "" then
  package.path = backend .. "/?.lua;" .. package.path
  local main_lua = backend .. "/main.lua"
  local probe = io.open(main_lua, "r")
  if probe then
    probe:close()
    -- Loading main.lua defines the global RPC functions (InitApis, etc.) and
    -- returns a lifecycle table { on_load, on_unload, on_frontend_loaded }.
    local ok, result = pcall(dofile, main_lua)
    if ok then
      have_plugin = true
      lifecycle = result
    else
      io.stderr:write("[lumen] plugin backend failed to load; settings-menu only: "
        .. tostring(result) .. "\n")
    end
  end
end

if not have_plugin then
  io.stderr:write("[lumen] no LuaTools plugin backend present; running settings-menu only\n")
end

-- Millennium called on_load after requiring the plugin; we do the same so
-- inject_webkit_files() enqueues the frontend assets and the boot-time InitApis
-- runs. Only meaningful when the plugin backend is present.
if have_plugin and type(lifecycle) == "table" and type(lifecycle.on_load) == "function" then
  local ok, err = pcall(lifecycle.on_load)
  if not ok then io.stderr:write("[lumen] on_load error: " .. tostring(err) .. "\n") end
end

-- Dispatch registry: the plugin endpoints the frontend calls via
-- callServerMethod. Only populated when the plugin backend loaded; in no-plugin
-- mode the registry holds just Lumen's native menu RPCs (registered below).
local registry = {}
if have_plugin then
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
  "StartAddViaLuaToolsSmart",
  "GetGameUpdates","SetGamePin","SetDlcPin","ClearGamePin","ClearDlcPin",
  "DeleteManifest","ClearManifests",
}

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

-- The "Game Updates" tab (manifest pinning): assemble the per-game version
-- tree from on-disk data and read/write the ManifestPins map in config.yaml.
require("manifestpins").register(registry)

-- The "About" tab: report installed-vs-latest versions of the stack components
-- (from the release tags) and open a terminal for "Update All". In no-plugin
-- mode the plugin row is dropped and Update All re-runs the installer with
-- --noplugin so an update never re-adds the plugin.
require("about").register(registry, { no_plugin = not have_plugin })

local lua_dir = os.getenv("LUMEN_LUA_DIR") or "lua"

-- The Lumen settings menu used to be one ~1.2k-line lumen_menu.js. It's now
-- split into ordered source fragments under menu/ (one concern per file) for
-- maintainability. They share a SINGLE closure (idempotency guard + private
-- state), so they must be injected as one unit: we concatenate them in order
-- into one string and inject that with a single Runtime.evaluate. The assembled
-- output is behaviourally identical to the old single file. ORDER MATTERS:
-- 01-core opens the IIFE; 09-menubar runs the bootstrap and closes it.
local MENU_PARTS = {
  "01-core.js", "02-i18n.js", "03-styles.js", "04-overlay-helpers.js",
  "05-config-tab.js", "06-updates-helpers.js", "07-updates-tab.js",
  "08-about-tab.js", "09-overlay.js", "10-menubar.js",
}

local function read_menu_js()
  local parts = {}
  for _, name in ipairs(MENU_PARTS) do
    local chunk = utils.read_file(lua_dir .. "/menu/" .. name)
    if not chunk then
      io.stderr:write("[lumen] WARN: menu fragment not found: menu/" .. name .. "\n")
      return nil
    end
    parts[#parts + 1] = chunk
  end
  -- Tell the menu whether the LuaTools plugin is present. The fragments read
  -- window.__lumenNoPlugin to drop plugin-only UI (the About-tab plugin row and
  -- the Game Updates source-import path) in a --noplugin install. Set as a
  -- separate statement BEFORE the menu IIFE so it's in scope when the IIFE runs.
  local prefix = "window.__lumenNoPlugin=" .. (have_plugin and "false" or "true") .. ";\n"
  return prefix .. table.concat(parts, "\n")
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
-- One initial desktop-coverage pass per injected session (user-owned entries):
-- heals anything Steam/the DE reverted since the last session, before the tick
-- loop takes over the autostart watch. Best-effort.
pcall(function() require("deskcover").run("--user") end)
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
