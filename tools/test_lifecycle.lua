-- Run: lua5.4 tools/test_lifecycle.lua
-- Lumen is a sidecar launched by the Steam wrapper. It must exit when Steam is
-- genuinely CLOSED (so it doesn't linger as a background process), but must NOT
-- exit during:
--   (a) a slow BOOT — Steam may take well over 30s to first appear on slow PCs,
--       so we wait INDEFINITELY for Steam to be seen the first time;
--   (b) a RESTART — the "Restart Steam" button kills Steam and relaunches it; the
--       process is absent for ~15-20s, so a generous grace window must elapse
--       with Steam continuously gone before we exit.
package.path = "lua/?.lua;" .. package.path
local lifecycle = require("lifecycle")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end

local GRACE = 45

-- 1. Before Steam is ever seen, never exit no matter how long (slow boot).
do
  local w = lifecycle.new_watcher({ grace = GRACE })
  assert_true(w:should_exit(0,    false) == false, "t=0 not seen -> wait")
  assert_true(w:should_exit(120,  false) == false, "t=120 still booting -> wait")
  assert_true(w:should_exit(9999, false) == false, "t=9999 still booting -> wait")
end

-- 2. Once Steam is seen, then closed, exit only after the grace window.
do
  local w = lifecycle.new_watcher({ grace = GRACE })
  assert_true(w:should_exit(10, true)  == false, "seen alive -> keep")
  assert_true(w:should_exit(20, false) == false, "just gone -> within grace")
  assert_true(w:should_exit(20 + GRACE - 1, false) == false, "still within grace -> keep")
  assert_true(w:should_exit(20 + GRACE,     false) == true,  "grace elapsed gone -> EXIT")
end

-- 3. A restart (gone briefly then back) must NOT exit, and resets the timer.
do
  local w = lifecycle.new_watcher({ grace = GRACE })
  assert_true(w:should_exit(10, true)  == false, "alive")
  assert_true(w:should_exit(15, false) == false, "restart: gone")
  assert_true(w:should_exit(25, false) == false, "restart: still gone, within grace")
  assert_true(w:should_exit(30, true)  == false, "restart: back -> keep")
  -- After coming back, a later close must wait a FRESH full grace window.
  assert_true(w:should_exit(40, false) == false, "gone again -> new grace starts")
  assert_true(w:should_exit(40 + GRACE - 1, false) == false, "within fresh grace -> keep")
  assert_true(w:should_exit(40 + GRACE,     false) == true,  "fresh grace elapsed -> EXIT")
end

-- 4. Default grace is generous (>= 30s) to cover slow restarts.
do
  local w = lifecycle.new_watcher()
  assert_true(w.grace >= 30, "default grace covers slow restart gaps")
end

print("test_lifecycle: ALL PASS")
