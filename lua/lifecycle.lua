-- Pure lifecycle watcher: decides when the Lumen sidecar should exit.
--
-- Lumen is launched by the Steam wrapper and should not outlive Steam. But it
-- must tolerate two cases where Steam is (temporarily) absent:
--   * BOOT  — Steam can take a long time to first appear on slow machines, so we
--             wait INDEFINITELY until Steam is seen alive the first time.
--   * RESTART — the "Restart Steam" button kills Steam and relaunches it; the
--             process is gone for ~15-20s. We only exit once Steam has stayed
--             continuously gone for a generous grace window AFTER having been
--             seen alive at least once.
--
-- No IO here (liveness is probed elsewhere and fed in) so this is unit-testable.
local lifecycle = {}

local Watcher = {}
Watcher.__index = Watcher

-- new_watcher{ grace = <seconds> }  (grace defaults to 45s, > worst-case restart)
function lifecycle.new_watcher(opts)
  opts = opts or {}
  return setmetatable({
    grace = opts.grace or 45,
    seen = false,       -- has Steam been observed alive at least once?
    gone_since = nil,   -- timestamp Steam was first observed gone (after seen)
  }, Watcher)
end

-- should_exit(now, steam_alive) -> should_exit, steam_returned.
-- steam_returned is true for exactly one tick after an observed alive -> gone
-- -> alive transition. The initial appearance during boot is not a return.
function Watcher:should_exit(now, steam_alive)
  if steam_alive then
    local returned = self.seen and self.gone_since ~= nil
    self.seen = true
    self.gone_since = nil
    return false, returned
  end
  -- Steam not alive.
  if not self.seen then
    return false            -- still booting; wait indefinitely.
  end
  if not self.gone_since then
    self.gone_since = now   -- start the grace timer.
    return false
  end
  return (now - self.gone_since) >= self.grace
end

return lifecycle
