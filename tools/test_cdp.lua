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
    { urls = { "store.steampowered.com" }, assets = { js = { "x" } } },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local ctrl
  for _, r in ipairs(routed) do
    if r.target.title == "SharedJSContext" then ctrl = r end
  end
  assert_true(ctrl ~= nil and ctrl.control == true, "control flag passed through")
end

print("test_cdp: ALL PASS")
