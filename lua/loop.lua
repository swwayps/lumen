-- Single-process event loop driving the multi-target CDP injector. The
-- frontend talks to the backend via Runtime.addBinding (handled inside the
-- injector), so there is NO loopback HTTP server / port / token anymore.
local socket = require("socket")
local injector = require("injector")
local lifecycle = require("lifecycle")
local proc = require("proc")
local deskcover = require("deskcover")

local loop = {}

local function log(msg)
  io.stderr:write(os.date("!%H:%M:%S ") .. "[lumen] " .. msg .. "\n")
  io.stderr:flush()
end

-- run{ registry=, build_assets=, targets=, target_urls=, channels= }
-- If `channels` is given (each { titles=, urls=, assets= }) it is used directly;
-- otherwise the single targets/target_urls/assets form is used (back-compat).
function loop.run(opts)
  local inj = injector.new({
    channels = opts.channels,
    targets = opts.targets,
    target_urls = opts.target_urls,
    assets = (not opts.channels) and opts.build_assets and opts.build_assets() or nil,
    registry = opts.registry,
  })
  -- Exit when Steam is genuinely closed (don't linger as a background process),
  -- but tolerate slow boot (wait until Steam is first seen) and the restart gap
  -- (grace window). Liveness = the main `steam` client process in /proc.
  local watcher = lifecycle.new_watcher()
  local CHECK_EVERY = 3          -- seconds between /proc liveness checks
  local next_check = 0
  -- Re-assert user-owned desktop coverage when the autostart entry appears or
  -- changes (the user toggling "run on startup" mid-session). Cheap: one stat of
  -- the autostart path per tick; see deskcover.
  local dc_tick = deskcover.new_tick({ interval = CHECK_EVERY })
  while true do
    local fds = inj:fds()
    if #fds > 0 then
      socket.select(fds, nil, 1)
    else
      socket.sleep(1)   -- nothing attached yet; idle before re-discovering
    end
    local now = os.time()
    if now >= next_check then
      next_check = now + CHECK_EVERY
      if dc_tick:should_repatch(now, deskcover.stat_autostart()) then
        log("autostart entry changed/vanilla -> re-asserting desktop coverage")
        deskcover.run("--user")
      end
      local should_exit, steam_returned =
        watcher:should_exit(now, proc.is_alive("steam"))
      if steam_returned and type(opts.on_steam_returned) == "function" then
        local ok, err = pcall(opts.on_steam_returned)
        if not ok then
          log("Steam return callback failed: " .. tostring(err))
        end
      end
      if should_exit then
        deskcover.run("--user")        -- final heal before we stop
        log("Steam closed -> Lumen exiting")
        os.exit(0)
      end
    end
    inj:tick()
  end
end

return loop
