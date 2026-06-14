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

print("test_inject: ALL PASS")
