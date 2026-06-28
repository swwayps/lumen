-- deskcover: decide when to re-patch the autostart entry on Lumen's existing
-- 3s tick, and shell out to ensure-desktop-coverage.sh. Pure decision logic is
-- split from IO so it is unit-testable.
local deskcover = {}

local Tick = {}
Tick.__index = Tick

-- new_tick{ interval = <secs> } — interval rate-limits the stat-driven repatch.
function deskcover.new_tick(opts)
  opts = opts or {}
  return setmetatable({ interval = opts.interval or 3, last_check = -1, last_mtime = nil }, Tick)
end

-- should_repatch(now, st) -> boolean.
-- st = { exists=bool, mtime=number, patched=bool }. Fires when the autostart
-- file exists, is NOT patched, and (first sight OR mtime changed), at most once
-- per interval.
function Tick:should_repatch(now, st)
  if self.last_check >= 0 and (now - self.last_check) < self.interval then return false end
  self.last_check = now
  if not st.exists then self.last_mtime = nil; return false end
  local changed = (self.last_mtime == nil) or (st.mtime ~= self.last_mtime)
  self.last_mtime = st.mtime
  if st.patched then return false end
  return changed
end

return deskcover
