-- Run: lua5.4 tools/test_cdp.lua
package.path = "lua/?.lua;" .. package.path
local cdp = require("cdp")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end

-- Shared target fixture for the routing test: one shell target (matched by
-- title) and one store web view (matched by URL fragment).
local SAMPLE = {
  { title = "SharedJSContext", webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/B" },
  { title = "Steam Store", url = "https://store.steampowered.com/app/1",
    webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/D" },
}

-- 1. find_shared_js_context picks the target whose title is SharedJSContext.
do
  local targets = {
    { title = "Steam", webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/A" },
    { title = "SharedJSContext", webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/B" },
    { title = "Friends", webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/C" },
  }
  local t = cdp.find_shared_js_context(targets)
  assert_true(t ~= nil, "found a target")
  assert_true(t.webSocketDebuggerUrl:match("/page/B$") ~= nil, "picked SharedJSContext")
end

-- 2. returns nil when there's no SharedJSContext yet (boot race).
do
  local t = cdp.find_shared_js_context({ { title = "Steam" } })
  assert_true(t == nil, "nil when absent")
end

-- 3. build_command produces an id'd CDP command and increments ids.
do
  local s = cdp.new_session()
  local c1 = s:build_command("Runtime.enable")
  local c2 = s:build_command("Runtime.evaluate", { expression = "1+1" })
  assert_true(c1:match('"id":1') ~= nil, "first id is 1")
  assert_true(c1:match('"method":"Runtime%.enable"') ~= nil, "method present")
  assert_true(c2:match('"id":2') ~= nil, "id increments")
  assert_true(c2:match('"expression":"1%+1"') ~= nil, "params present")
end

-- 4. parse_message classifies results vs events.
do
  local r = cdp.parse_message('{"id":1,"result":{"ok":true}}')
  assert_true(r.kind == "result" and r.id == 1, "classifies result")
  local e = cdp.parse_message('{"method":"Runtime.executionContextCreated","params":{}}')
  assert_true(e.kind == "event" and e.method == "Runtime.executionContextCreated", "classifies event")
end

-- 5. route_targets passes through a channel's `control` flag (generic; used to
--    tag special-purpose connections).
do
  local channels = {
    { titles = { ["SharedJSContext"] = true }, control = true },
    { origins = { { host = "store.steampowered.com" } }, assets = { js = { "x" } } },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local ctrl
  for _, r in ipairs(routed) do
    if r.target.title == "SharedJSContext" then ctrl = r end
  end
  assert_true(ctrl ~= nil and ctrl.control == true, "control flag passed through")
end

-- ── origin matching (exact host, https only) ────────────────────────────────
-- Channels used to be matched with a plain substring search over the target
-- URL, so any navigable page whose URL merely CONTAINED "store.steampowered.com"
-- (e.g. https://attacker.example/?ref=store.steampowered.com) was handed the
-- privileged CDP binding. Matching is now host-exact and https-only.

-- 6. parse_origin splits an https URL into a lowercased host and a path.
do
  local host, path = cdp.parse_origin("https://Store.SteamPowered.com/app/1?x=2#y")
  assert_true(host == "store.steampowered.com", "host lowercased")
  assert_true(path == "/app/1", "path without query/fragment")
  local h2, p2 = cdp.parse_origin("https://steamcommunity.com")
  assert_true(h2 == "steamcommunity.com" and p2 == "/", "empty path becomes /")
end

-- 7. parse_origin rejects non-https, userinfo and malformed input.
do
  assert_true(cdp.parse_origin("http://store.steampowered.com/") == nil, "rejects http")
  assert_true(cdp.parse_origin("ws://store.steampowered.com/") == nil, "rejects ws")
  assert_true(cdp.parse_origin("https://store.steampowered.com@evil.example/") == nil,
    "rejects userinfo")
  assert_true(cdp.parse_origin("data:text/html,<b>") == nil, "rejects data URL")
  assert_true(cdp.parse_origin(nil) == nil, "rejects nil")
end

-- 8. origin_matches requires an exact host, not a substring.
do
  local origins = { { host = "store.steampowered.com" }, { host = "steamcommunity.com" } }
  assert_true(cdp.origin_matches("https://store.steampowered.com/app/1", origins),
    "exact host matches")
  assert_true(not cdp.origin_matches("https://attacker.example/?ref=store.steampowered.com",
    origins), "query-string lookalike rejected")
  assert_true(not cdp.origin_matches("https://store.steampowered.com.evil.example/", origins),
    "suffix lookalike rejected")
  assert_true(not cdp.origin_matches("https://evilstore.steampowered.com/", origins),
    "prefixed host rejected")
  assert_true(not cdp.origin_matches("http://store.steampowered.com/", origins),
    "http rejected even on the right host")
end

-- 9. origin_matches honours an optional path_prefix on segment boundaries.
do
  local offers = { { host = "store.steampowered.com",
                     path_prefix = "/marketingmessages/list" } }
  assert_true(cdp.origin_matches("https://store.steampowered.com/marketingmessages/list",
    offers), "exact path matches")
  assert_true(cdp.origin_matches("https://store.steampowered.com/marketingmessages/list/",
    offers), "trailing slash matches")
  assert_true(not cdp.origin_matches("https://store.steampowered.com/marketingmessages/listing",
    offers), "sibling path with shared prefix rejected")
  assert_true(not cdp.origin_matches("https://store.steampowered.com/app/1", offers),
    "unrelated path rejected")
end

-- 10. select_targets / route_targets take origin specs, and a lookalike URL is
--     routed to no channel at all.
do
  local targets = {
    { title = "Steam Store", url = "https://store.steampowered.com/app/1",
      webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/D" },
    { title = "Evil", url = "https://attacker.example/?ref=store.steampowered.com",
      webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/E" },
  }
  local channels = {
    { origins = { { host = "store.steampowered.com" } }, assets = { js = { "x" } } },
  }
  local routed = cdp.route_targets(targets, channels)
  assert_true(#routed == 1, "only the genuine store target routed")
  assert_true(routed[1].target.webSocketDebuggerUrl:match("/page/D$") ~= nil,
    "routed target is the store page")
end

-- 11. route_targets carries a channel's `remote` flag so the caller can apply a
--     reduced registry to contexts that host remote content.
do
  local channels = {
    { origins = { { host = "store.steampowered.com" } }, remote = true, assets = {} },
    { titles = { ["SharedJSContext"] = true }, assets = {} },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local store, shell
  for _, r in ipairs(routed) do
    if r.target.title == "Steam Store" then store = r end
    if r.target.title == "SharedJSContext" then shell = r end
  end
  assert_true(store ~= nil and store.remote == true, "remote flag set on web view")
  assert_true(shell ~= nil and shell.remote ~= true, "shell channel is not remote")
end

print("test_cdp: ALL PASS")
