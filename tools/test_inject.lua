-- Run: lua5.4 tools/test_inject.lua
-- Regression: the LuaTools webkit frontend must be injected ONLY into web-view
-- targets (store/community), NEVER into SharedJSContext (the main Steam client
-- shell). Injecting the webkit script into SharedJSContext breaks the native
-- top menubar (Steam/View/Friends/Games/Help), because that script monkey-
-- patches history.pushState, attaches a document.body MutationObserver, and
-- runs periodic DOM scans that the React shell never expects. Millennium only
-- ever loaded luatools.js into WebKit (web view) contexts via add_browser_js.
package.path = "lua/?.lua;" .. package.path
local cdp = require("cdp")
local injector = require("injector")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end

local SAMPLE = {
  { title = "Steam",           url = "about:blank",                          webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/A" },
  { title = "SharedJSContext", url = "https://steamloopback.host/index.html", webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/B" },
  { title = "Welcome to Steam",url = "https://store.steampowered.com/",      webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/C" },
  { title = "Community",       url = "https://steamcommunity.com/app/440",   webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/D" },
  { title = "Friends",         url = "https://steamcommunity.com/chat",      webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/E" },
}

-- select_targets(targetsList, wantedTitles, wantedUrlFragments) is the pure
-- matcher the injector uses to decide which CEF targets receive the assets.
assert_true(type(cdp.select_targets) == "function",
  "cdp exposes select_targets for testing")

-- 1. With the production config (no title targets, URL-matched web views), the
--    matcher must pick the store/community web views and EXCLUDE SharedJSContext.
do
  local picked = cdp.select_targets(SAMPLE, {}, { "store.steampowered.com", "steamcommunity.com" })
  local byurl = {}
  for _, t in ipairs(picked) do byurl[t.webSocketDebuggerUrl] = true end
  assert_true(byurl["ws://localhost:8080/devtools/page/C"], "store web view selected")
  assert_true(byurl["ws://localhost:8080/devtools/page/D"], "community app view selected")
  for _, t in ipairs(picked) do
    assert_true(t.title ~= "SharedJSContext",
      "SharedJSContext must NOT be selected for frontend injection")
  end
end

-- 2. A target without a webSocketDebuggerUrl is never selectable.
do
  local list = {
    { title = "store", url = "https://store.steampowered.com/", },  -- no ws url
  }
  local picked = cdp.select_targets(list, {}, { "store.steampowered.com" })
  assert_true(#picked == 0, "targets without a ws url are skipped")
end

-- 3. Title matching still works for explicit title targets (kept for generality).
do
  local picked = cdp.select_targets(SAMPLE, { ["Friends"] = true }, nil)
  assert_true(#picked == 1 and picked[1].title == "Friends", "explicit title match works")
end

-- 4. route_targets(): assigns each matched target the assets of the FIRST
--    channel it matches, so the store web views get luatools.js while
--    SharedJSContext gets a DIFFERENT (lumen-menu) bundle — and never the
--    reverse. This is what lets the menu live in the shell without ever
--    putting the invasive webkit script there.
do
  assert_true(type(cdp.route_targets) == "function", "cdp exposes route_targets")
  local LUATOOLS = { js = { "luatools" } }
  local MENU = { js = { "lumenmenu" } }
  local channels = {
    { urls = { "store.steampowered.com", "steamcommunity.com" }, assets = LUATOOLS },
    { titles = { ["SharedJSContext"] = true }, assets = MENU },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local by = {}
  for _, r in ipairs(routed) do by[r.target.webSocketDebuggerUrl] = r.assets end
  -- store + community web views -> luatools bundle
  assert_true(by["ws://localhost:8080/devtools/page/C"] == LUATOOLS, "store gets luatools assets")
  assert_true(by["ws://localhost:8080/devtools/page/D"] == LUATOOLS, "community gets luatools assets")
  -- SharedJSContext -> menu bundle, NEVER luatools
  assert_true(by["ws://localhost:8080/devtools/page/B"] == MENU, "SharedJSContext gets menu assets")
  -- the bare "Steam" (about:blank) target matches nothing -> not routed
  assert_true(by["ws://localhost:8080/devtools/page/A"] == nil, "unmatched target not routed")
end

-- 5. route_targets(): a target matching two channels takes the FIRST channel's
--    assets (deterministic precedence), and is routed only once.
do
  local A = { id = "a" }
  local B = { id = "b" }
  local channels = {
    { titles = { ["SharedJSContext"] = true }, assets = A },
    { titles = { ["SharedJSContext"] = true }, assets = B },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local count, picked = 0, nil
  for _, r in ipairs(routed) do
    if r.target.title == "SharedJSContext" then count = count + 1; picked = r.assets end
  end
  assert_true(count == 1, "matched target routed exactly once")
  assert_true(picked == A, "first channel wins")
end

-- 6. route_targets passes through a channel's `control` flag so the manager can
--    tell which connection is the SharedJSContext control link (no assets).
do
  local channels = {
    { titles = { ["SharedJSContext"] = true }, control = true },
    { urls = { "store.steampowered.com" }, assets = { js = { "x" } } },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local ctrl
  for _, r in ipairs(routed) do
    if r.target.title == "SharedJSContext" then ctrl = r end
  end
  assert_true(ctrl ~= nil and ctrl.control == true, "control flag passed through")
end

-- 7. validate_app_expr(): builds the JS that asks the Steam client to verify a
--    game's files. It must be relayed into SharedJSContext (the only context
--    with SteamClient), so we drive Steam's own steam://validate handler via
--    SteamClient.URL.ExecuteSteamURL rather than navigating window.location
--    (which would blow away the shell when the overlay is in the main window).
do
  assert_true(type(injector.validate_app_expr) == "function",
    "injector exposes validate_app_expr for testing")
  local expr = injector.validate_app_expr(250900)
  assert_true(expr:find("steam://validate/250900", 1, true) ~= nil,
    "expr targets steam://validate/<appid>")
  assert_true(expr:find("ExecuteSteamURL", 1, true) ~= nil,
    "expr drives the Steam URL handler via SteamClient")
  assert_true(expr:find("try", 1, true) ~= nil and expr:find("catch", 1, true) ~= nil,
    "expr is wrapped in try/catch so a missing API can't throw")
  -- appid is coerced to an integer: nothing user-controlled is interpolated.
  -- A malformed value can't parse as a number, so it falls back to 0 (safe) and
  -- the injected JS never makes it into the expression.
  local inj = injector.validate_app_expr("250900'); alert(1); //")
  assert_true(inj:find("alert", 1, true) == nil, "injected JS is not interpolated")
  assert_true(inj:find("steam://validate/0", 1, true) ~= nil,
    "a malformed appid coerces to 0, not the attacker tail")
  local zero = injector.validate_app_expr("not a number")
  assert_true(zero:find("steam://validate/0", 1, true) ~= nil,
    "a non-numeric appid coerces to 0")
end

-- 8. dispatch_method(): the binding handler's registry lookup. A regression
--    here (dropping the registry lookup) makes EVERY backend RPC come back as
--    "unknown method", which is exactly what broke the menu once.
do
  assert_true(type(injector.dispatch_method) == "function",
    "injector exposes dispatch_method for testing")
  local registry = {
    GetSlsConfig = function() return '{"success":true,"values":{}}' end,
    Echo = function(a) return { got = a } end,
  }
  local r = injector.dispatch_method(registry, "GetSlsConfig", {})
  assert_true(r:find('"success":true', 1, true) ~= nil,
    "a registered method is dispatched and its result returned")
  local u = injector.dispatch_method(registry, "GetGameUpdates", {})
  assert_true(u:find("unknown method: GetGameUpdates", 1, true) ~= nil,
    "an unregistered method returns a clear unknown-method error")
  local n = injector.dispatch_method(nil, "Anything", {})
  assert_true(n:find("unknown method", 1, true) ~= nil,
    "a nil registry doesn't throw, just reports unknown")
end

print("test_inject: ALL PASS")
