-- Run: lua5.4 tools/test_inject.lua
package.path = "lua/?.lua;" .. package.path
local inject = require("inject")

local function has(s, sub, m)
  if not s:find(sub, 1, true) then error("FAIL " .. (m or "") .. ": missing " .. sub) end
end

-- 1. toast_payload wraps JS in a sentinel guard so re-eval is idempotent.
do
  local js = inject.toast_payload("Lumen attached")
  has(js, "window.__lumenInjected", "sentinel referenced")
  has(js, "Lumen attached", "message embedded")
  -- The guard must early-return if the sentinel is already set.
  has(js, "if (window.__lumenInjected)", "guard present")
  has(js, "window.__lumenInjected = true", "sets sentinel")
end

-- 2. message text is escaped so quotes/newlines can't break the JS string.
do
  local js = inject.toast_payload('he said "hi"\n')
  has(js, '\\"hi\\"', "double quotes escaped")
  if js:find('"hi"\n', 1, true) then error("FAIL: raw quotes/newline leaked") end
end

print("test_inject: ALL PASS")
