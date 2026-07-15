-- Run: lua5.4 tools/test_cdp.lua
package.path = "lua/?.lua;" .. package.path
local cdp = require("cdp")
local json = require("json")

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

-- Browser-view identity must survive routing so the injector can probe initial
-- document visibility natively after a context reload (the first JS event can
-- race Runtime.addBinding and be lost).
do
  local routed = cdp.route_targets(SAMPLE, {
    {urls={"store.steampowered.com"}, browser=true, assets={js={"menu"}}},
  })
  assert_true(#routed == 1 and routed[1].browser == true,
    "browser identity is preserved for native visibility probing")
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

-- Flattened browser-target sessions carry `sessionId` at the top level. Lumen
-- uses those sessions to pause each newly-created Steam renderer, install the
-- theme hook/provider, and only then let it run.
do
  local s = cdp.new_session()
  local command = json.decode(s:build_command("Fetch.enable", {patterns={}}, "SESSION-1"))
  assert_true(command.sessionId == "SESSION-1",
    "commands can target a flattened child session")
  local event = cdp.parse_message('{"method":"Fetch.requestPaused","sessionId":"SESSION-1","params":{"requestId":"r"}}')
  assert_true(event.session_id == "SESSION-1",
    "flattened events preserve their child session identity")
  local result = cdp.parse_message('{"id":7,"sessionId":"SESSION-1","result":{}}')
  assert_true(result.session_id == "SESSION-1",
    "flattened command results preserve their child session identity")
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
    { urls = { "store.steampowered.com" }, assets = { js = { "x" } } },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local ctrl
  for _, r in ipairs(routed) do
    if r.target.title == "SharedJSContext" then ctrl = r end
  end
  assert_true(ctrl ~= nil and ctrl.control == true, "control flag passed through")
end

-- 6. composing theme assets reach every target without mutating/duplicating
-- the base channel assets across repeated discovery passes.
do
  local base = { js = { "menu" }, css = {} }
  local channels = {
    { urls = { "store.steampowered.com" }, assets = base },
    { titles = { ["SharedJSContext"] = true }, control = true },
    { all = true, compose = true, assets = {
      js = { "theme" }, deferred_js = { "compiled-popup-theme" }, css = {}
    } },
  }
  local first = cdp.route_targets(SAMPLE, channels)
  local second = cdp.route_targets(SAMPLE, channels)
  assert_true(#base.js == 1, "base assets are not mutated")
  for _, routed in ipairs({first, second}) do
    for _, r in ipairs(routed) do
      assert_true(#r.assets.js == (r.target.title == "Steam Store" and 2 or 1),
        "theme composed exactly once")
      assert_true(#r.assets.deferred_js == 1
          and r.assets.deferred_js[1] == "compiled-popup-theme",
        "deferred theme assets survive composing without entering the immediate bundle")
    end
  end
end

-- 7. Recent Steam data: browser targets can be routed by title pattern even
-- when /json exposes no store/community URL.
do
  local targets = {{title="data:text/html,&lt;body&gt;", url="data:text/html,%3Cbody%3E",
    webSocketDebuggerUrl="ws://localhost/devtools/page/data"}}
  local routed = cdp.route_targets(targets, {{title_patterns={"^data:text/html"},assets={js={"menu"}}}})
  assert_true(#routed == 1 and routed[1].assets.js[1] == "menu", "data browser routed")
end

-- 8. Main shell is routable before its title becomes "Steam" after a context
-- restart, using the stable browserType=4 URL flag.
do
  local targets = {{title="",url="about:blank?createflags=274&browserType=4&w=1280",
    webSocketDebuggerUrl="ws://localhost/devtools/page/shell"}}
  local routed = cdp.route_targets(targets, {{titles={Steam=true},urls={"browserType=4"},assets={js={"menu"}}}})
  assert_true(#routed == 1, "untitled main shell routed")
end

print("test_cdp: ALL PASS")
