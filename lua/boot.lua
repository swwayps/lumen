-- boot: load the LuaTools backend behind the shims, then run the injector loop.
--
-- The LuaTools plugin backend is OPTIONAL. A `--noplugin` install ships only the
-- runtime stack (slsteam-moon + Lumen) and Lumen's OWN settings menu (the full-
-- moon button: slsteam-moon config, Game Updates / manifest pins, About), with
-- no LuaTools frontend and no plugin backend on disk. So load the backend only
-- when it's actually present; when it isn't, run in "settings-menu only" mode
-- instead of aborting the whole sidecar (an unguarded dofile of a missing
-- main.lua used to kill Lumen at boot, taking the menu down with it).
--
-- The Steam wrapper invokes this tiny mode synchronously before it starts the
-- client. It restores the verified index and stages the compiled helpers
-- outside Steam's tree. The native exec gate publishes them only after Steam's
-- updater has finished and immediately before steamwebhelper starts. This path
-- loads no plugin backend and opens no socket.
if os.getenv("LUMEN_THEME_PRELOAD_ONLY") == "1" then
  local early_themes = require("themes")
  local early_runtime = require("themeengine").build(early_themes.load_config())
  local early_preload = require("themepreload")
  -- Restore the verified file before Steam's updater sees it. Theme helpers
  -- are staged outside SteamUI; the native exec gate publishes them only after
  -- verification, immediately before steamwebhelper.
  local clean_ok, clean_err = early_preload.sync(nil)
  local stage_ok, stage_err = early_preload.stage(early_runtime)
  if not clean_ok or not stage_ok then
    io.stderr:write("[lumen] theme preflight failed: " ..
      tostring(clean_err or stage_err) .. "\n")
    os.exit(1)
  end
  -- Exit 10 is a private launcher contract: the files are ready and Steam
  -- must enable its loose SteamUI override.  Exit 0 means default/disabled,
  -- so the launcher adds no flag and Steam keeps its packed web resources.
  os.exit(early_runtime and 10 or 0)
end

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
local json = require("json")
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
local slsconfig = require("slsconfig")
local slsconfig_path = slsconfig.default_path()
local parental_unlock_enabled = false
local webview_assets
local offers_assets

-- Special Offers is an authenticated marketing popup, not a normal Store
-- webview. Keep it out of the LuaTools/menu bundle and remove only Steam's
-- parental form when the user explicitly enabled the local parental unlock.
local SPECIAL_OFFERS_UNLOCK_JS = [[
(function(){
  if(window.__lumenOffersUnlock)return;
  window.__lumenOffersUnlock=true;
  if(location.hostname!=="store.steampowered.com"||
      !/^\/marketingmessages\/list\/?$/.test(location.pathname))return;
  function unlock(){
    var menu=document.querySelector('[data-featuretarget="store-menu-v7"]');
    if(menu){
      menu.style.setProperty("display","none","important");
      menu.setAttribute("aria-hidden","true");
    }
    var root=document.getElementById("main_content");
    if(!root)return;
    var forms=root.querySelectorAll("form");
    for(var i=0;i<forms.length;i++){
      var form=forms[i], text=(form.textContent||"").replace(/\s+/g," ");
      if(text.indexOf("Family View")!==-1&&
          text.indexOf("Request Access")!==-1){
        form.style.setProperty("display","none","important");
        form.setAttribute("aria-hidden","true");
      }
    }
  }
  unlock();
  new MutationObserver(unlock).observe(document.documentElement,
    {childList:true,subtree:true});
})();
]]

local function refresh_parental_unlock(values)
  values = values or slsconfig.read(slsconfig_path)
  parental_unlock_enabled =
    values.DisableParentalRestrictions == true
  if webview_assets then
    webview_assets.anonymous_web = parental_unlock_enabled
  end
  if offers_assets then
    offers_assets.js = parental_unlock_enabled
      and { SPECIAL_OFFERS_UNLOCK_JS } or {}
  end
end

refresh_parental_unlock()
require("slsmenu").register(registry, {
  path = slsconfig_path,
  on_values = refresh_parental_unlock,
})

-- The "Game Updates" tab (manifest pinning): assemble the per-game version
-- tree from on-disk data and read/write the ManifestPins map in config.yaml.
require("manifestpins").register(registry)

-- The "About" tab: report installed-vs-latest versions of the stack components
-- (from the release tags) and open a terminal for "Update All". In no-plugin
-- mode the plugin row is dropped and Update All re-runs the installer with
-- --noplugin so an update never re-adds the plugin.
require("about").register(registry, { no_plugin = not have_plugin })

-- The library-page "Fixes Menu" (menu/10-fixes-menu.js): one context RPC
-- (install path + name + Proton-effective) so the menu can reuse the existing
-- LuaTools fix RPCs on a game's library page.
require("fixesmenu").register(registry)

-- The "slsteam-moon not loaded" warning (menu/13-sls-check.js): detect whether
-- SLSsteam.so is actually injected into the running Steam client, and if not,
-- offer an auto-fix that re-installs the latest slsteam-moon, repairs the
-- *steam*.desktop launchers and relaunches Steam injected. Always registered
-- (the check is a cheap /proc scan; it's meaningful in every mode).
require("slscheck").register(registry)

-- Native restart is always available, including --noplugin installs. Register
-- after collecting plugin endpoints so the safe slsteam-moon-aware helper
-- replaces any plugin-provided RestartSteam implementation.
require("steamrestart").register(registry)

-- The "Cloud Saves" tab (menu/12-cloud-tab.js): set up CloudRedirect cloud
-- saves (provider, OAuth sign-in, stats toggles) directly against the hook's
-- ~/.config/CloudRedirect file contract — no flatpak, no background process.
-- Gated on CloudRedirect actually being installed (its .so on disk): without
-- it there's nothing to configure, so we DON'T register the cloud RPCs and the
-- menu hides the tab (window.__lumenCloud=false) — zero cost for users who
-- don't use cloud saves. Single file-stat, decided once here at boot.
local have_cloudredirect = slsconfig.has_cloudredirect()
if have_cloudredirect then
  require("cloudsettings").register(registry)
end

-- Millennium-compatible client themes. Registration is cheap and exposes the
-- settings API; the engine itself is built only when themes are explicitly
-- enabled and an active theme exists.
local themes = require("themes")
themes.register(registry)
local themeengine = require("themeengine")
local themepreload = require("themepreload")

local lua_dir = os.getenv("LUMEN_LUA_DIR") or "lua"

-- The Lumen settings menu used to be one ~1.2k-line lumen_menu.js. It's now
-- split into ordered source fragments under menu/ (one concern per file) for
-- maintainability. They share a SINGLE closure (idempotency guard + private
-- state), so they must be injected as one unit: we concatenate them in order
-- into one string and inject that with a single Runtime.evaluate. The assembled
-- output is behaviourally identical to the old single file. ORDER MATTERS:
-- 01-core opens the IIFE; 11-menubar runs the bootstrap and closes it. The
-- fixes-menu fragment (10) must come BEFORE 11-menubar (the IIFE closer).
local MENU_PARTS = {
  "01-core.js", "02-i18n.js", "03-styles.js", "04-overlay-helpers.js",
  "05-config-tab.js", "06-updates-helpers.js", "07-updates-tab.js",
  "08-about-tab.js", "09-overlay.js", "10-fixes-menu.js", "12-cloud-tab.js",
  "13-sls-check.js", "14-themes-tab.js", "11-menubar.js",
}

local function read_menu_js(shell_target, browser_target, theme_key)
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
    .. "window.__lumenCloud=" .. (have_cloudredirect and "true" or "false") .. ";\n"
    .. "window.__lumenShellTarget=" .. (shell_target and "true" or "false") .. ";\n"
    .. "window.__lumenBrowserTarget=" .. (browser_target and "true" or "false") .. ";\n"
    .. "window.__lumenConfiguredTheme=" .. json.encode(theme_key or "") .. ";\n"
  return prefix .. table.concat(parts, "\n")
end

-- build_menu_assets() -> assets for the main window ("Steam"): polyfill +
-- lumen_menu.js (the full-moon button + settings overlay).
local function build_menu_assets(shell_target, theme_key)
  local js = {}
  local menu_js = read_menu_js(shell_target, false, theme_key)
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
local function build_webview_assets(theme_key)
  local base = build_assets()
  local menu_js = read_menu_js(false, true, theme_key)
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
offers_assets = {
  css = {},
  js = parental_unlock_enabled and { SPECIAL_OFFERS_UNLOCK_JS } or {},
}

local THEME_CLEANUP_JS = [[(function(){
  Array.from(document.querySelectorAll('[id^="lumen-theme-"]')).forEach(function(n){n.remove()});
  var c=document.getElementById('lumen-luatools-icon-compat');if(c)c.remove();
  var t=document.getElementById('lumen-theme-transition');if(t)t.remove();
  var ts=document.getElementById('lumen-theme-transition-style');if(ts)ts.remove();
  try{delete window.__lumenThemeApplied}catch(e){window.__lumenThemeApplied=undefined}
  try{delete window.__lumenThemePaletteSeed}catch(e){window.__lumenThemePaletteSeed=undefined}
  ['bg','panel','side','raised','text','muted','accent','border'].forEach(function(n){
    document.documentElement.style.removeProperty('--lumen-theme-'+n);
  });
})()]]

local function build_channels(theme_config, clean_previous)
  local configured = theme_config or themes.load_config()
  local theme_key = ""
  if configured and configured.enabled == true and type(configured.active) == "string" then
    theme_key = configured.active
  end
  webview_assets = build_webview_assets(theme_key)
  webview_assets.anonymous_web=parental_unlock_enabled
  local out = {
    { urls = { "store.steampowered.com/marketingmessages/list" },
      assets = offers_assets },
    { urls = { "store.steampowered.com", "steamcommunity.com" }, browser = true,
      assets = webview_assets },
    -- Steam's browser view is exposed by recent clients as a data: tracking
    -- target even while it renders Store/Community. It needs the lightweight
    -- menu bundle so the overlay can render above that composited view.
    { title_patterns = { "^data:text/html" }, browser = true,
      assets = build_menu_assets(false, theme_key) },
    -- Title can be empty for the first seconds after RestartJSContext. The
    -- stable browserType=4 flag identifies the main client shell before React
    -- assigns the "Steam" title, preventing a theme-only connection from
    -- claiming it first and leaving the Lumen access button absent.
    { titles = { ["Steam"] = true }, urls = { "browserType=4" },
      assets = build_menu_assets(true, theme_key) },
    { titles = { ["SharedJSContext"] = true }, control = true },
  }
  if clean_previous then
    out[#out+1] = { all=true, compose=true,
      assets={ polyfill=nil, css={}, js={THEME_CLEANUP_JS} } }
  end
  local runtime = themeengine.build(configured)
  local preloaded = false
  local native_preload = os.getenv("LUMEN_THEME_PRELOAD_ACTIVE") == "1"
  local preload_ok, preload_state
  if native_preload then
    preload_ok, preload_state = themepreload.stage(runtime)
    -- During an in-session theme switch the updater is long gone, so commit
    -- the new staged runtime before RestartJSContext. Initial boot is committed
    -- by the native pre-webhelper gate instead.
    if preload_ok and clean_previous then
      preload_ok, preload_state = themepreload.sync(runtime)
    end
  elseif not runtime then
    preload_ok, preload_state = themepreload.sync(nil)
    themepreload.stage(nil)
  else
    preload_ok = true
  end
  if preload_ok then
    preloaded = runtime ~= nil and native_preload
  elseif runtime then
    io.stderr:write("[lumen] WARN: theme preloader unavailable; using CDP fallback: "
      .. tostring(preload_state) .. "\n")
  end
  if runtime then
    -- On a normal native Steam install the file preloader has already armed
    -- PopupManager before library.js.  Keep the CDP path only as a read-only or
    -- unknown-layout fallback; evaluating the multi-megabyte popup hook twice
    -- stalls Steam's UI and was the remaining source of visible blinking.
    if not preloaded then
      out[#out+1] = { titles={ ["SharedJSContext"]=true }, compose=true, early=true,
        assets={polyfill=nil,css={},js={runtime.popup_guard_hook},
          deferred_js={runtime.popup_hook},login_browser_gateway=true,
          login_guard_source=runtime.popup_guard_hook,
          login_theme_source=runtime.popup_hook} }
      out[#out+1] = { titles={ ["SharedJSContext"]=true }, compose=true,
        assets={polyfill=nil,css={},js={runtime.popup_hook}} }
    end
    out[#out+1] = { all=true, compose=true, assets=runtime.assets }
  end
  return out
end
local channels = build_channels()
loop.run({
  registry = registry,
  channels = channels,
  on_steam_returned = refresh_parental_unlock,
  on_injector = function(inj)
    themes.set_apply_callback(function(cfg) inj:queue_channels(build_channels(cfg, true)) end)
  end,
  on_exit = function()
    if os.getenv("LUMEN_THEME_PRELOAD_ACTIVE") == "1" then
      themepreload.sync(nil)
    end
  end,
})
