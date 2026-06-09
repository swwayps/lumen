-- Single-process event loop driving the multi-target CDP injector. The
-- frontend talks to the backend via Runtime.addBinding (handled inside the
-- injector), so there is NO loopback HTTP server / port / token anymore.
local socket = require("socket")
local injector = require("injector")
local lifecycle = require("lifecycle")
local proc = require("proc")

local loop = {}

local function log(msg)
  io.stderr:write(os.date("!%H:%M:%S ") .. "[lumen] " .. msg .. "\n")
  io.stderr:flush()
end

-- run{ registry=, build_assets=, targets=, target_urls= }
function loop.run(opts)
  local assets = opts.build_assets and opts.build_assets() or nil
  local inj = injector.new({
    targets = opts.targets,
    target_urls = opts.target_urls,
    assets = assets,
    registry = opts.registry,
  })
  -- Exit when Steam is genuinely closed (don't linger as a background process),
  -- but tolerate slow boot (wait until Steam is first seen) and the restart gap
  -- (grace window). Liveness = the main `steam` client process in /proc.
  local watcher = lifecycle.new_watcher()
  local CHECK_EVERY = 3          -- seconds between /proc liveness checks
  local next_check = 0
  while true do
    local fds = inj:fds()
    if #fds > 0 then
      socket.select(fds, nil, 1)
    else
      socket.sleep(1)   -- nothing attached yet; idle before re-discovering
    end
    inj:tick()

    local now = os.time()
    if now >= next_check then
      next_check = now + CHECK_EVERY
      if watcher:should_exit(now, proc.is_alive("steam")) then
        log("Steam closed -> Lumen exiting")
        os.exit(0)
      end
    end
  end
end

return loop
