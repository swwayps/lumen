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

print("test_inject: ALL PASS")
