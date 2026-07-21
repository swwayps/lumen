-- Single-process event loop driving the multi-target CDP injector. The
-- frontend talks to the backend via Runtime.addBinding (handled inside the
-- injector), so there is NO loopback HTTP server / port / token anymore.
local socket = require("socket")
local injector = require("injector")
local lifecycle = require("lifecycle")
local proc = require("proc")
local webhelperwatch = require("webhelperwatch")
local deskcover = require("deskcover")

local loop = {}

local function log(msg)
  io.stderr:write(os.date("!%H:%M:%S ") .. "[lumen] " .. msg .. "\n")
  io.stderr:flush()
end

-- run{ registry=, build_assets=, targets=, target_origins=, channels= }
-- If `channels` is given (each { titles=, origins=, assets= }) it is used
-- directly; otherwise the single targets/target_origins/assets form is used
-- (back-compat).
function loop.run(opts)
  local inj = injector.new({
    channels = opts.channels,
    targets = opts.targets,
    target_origins = opts.target_origins,
    assets = (not opts.channels) and opts.build_assets and opts.build_assets() or nil,
    registry = opts.registry,
    on_ui_ready = opts.on_ui_ready,
  })
  -- Let the caller wire injector-dependent callbacks (e.g. the theme apply
  -- callback that queues a channel rebuild + RestartJSContext on a live change).
  if type(opts.on_injector) == "function" then opts.on_injector(inj) end
  -- Exit when Steam is genuinely closed (don't linger as a background process),
  -- but tolerate slow boot (wait until Steam is first seen) and the restart gap
  -- (grace window). Liveness = the main `steam` client process in /proc.
  local watcher = lifecycle.new_watcher()
  local webhelper_watcher = webhelperwatch.new()
  local CHECK_EVERY = 3          -- seconds between /proc liveness checks
  local next_check = 0
  -- Re-assert user-owned desktop coverage when the autostart entry appears or
  -- changes (the user toggling "run on startup" mid-session). Cheap: one stat of
  -- the autostart path per tick; see deskcover.
  local dc_tick = deskcover.new_tick({ interval = CHECK_EVERY })
  -- The once-per-session coverage heal used to run at Lumen boot — i.e. in the
  -- most CPU-contended second of Steam's launch, concurrently with the wrapper's
  -- own guardian kick (measured: 2.9-3.9 s of shell CPU per pass on a 4-vCPU
  -- box). Nothing needs it that early: the wrapper already kicks the guardian at
  -- launch, the guardian .path/.timer units watch the sources, and the autostart
  -- watch below catches mid-session drift. So it now runs once, well after boot.
  local dc_initial = deskcover.new_initial({ delay = 45 })
  while true do
    local fds = inj:fds()
    -- Pre-attach this is the discovery cadence, not a flat second: sleeping a
    -- whole second between /json probes would itself decide how late the moon
    -- button appears (see injector.DISCOVER_INTERVAL).
    local wait_timeout = inj:poll_timeout()
    if #fds > 0 then
      socket.select(fds, nil, wait_timeout)
    else
      socket.sleep(wait_timeout) -- nothing attached yet; idle before re-discovering
    end
    local now = os.time()
    if now >= next_check then
      next_check = now + CHECK_EVERY
      if dc_initial:due(now) then
        log("deferred once-per-session desktop-coverage pass")
        deskcover.run("--user")
      end
      if dc_tick:should_repatch(now, deskcover.stat_autostart()) then
        log("autostart entry changed/vanilla -> re-asserting desktop coverage")
        deskcover.run("--user")
      end
      local steam_alive = proc.is_alive("steam")
      local should_exit, steam_returned =
        watcher:should_exit(now, steam_alive)
      if steam_returned then
        webhelper_watcher:reset_session()
      end
      if webhelper_watcher:observe(
          proc.is_alive("steamwebhelper"), steam_alive) then
        log("WARN: " .. webhelper_watcher:warning_message())
      end
      if steam_returned and type(opts.on_steam_returned) == "function" then
        local ok, err = pcall(opts.on_steam_returned)
        if not ok then
          log("Steam return callback failed: " .. tostring(err))
        end
      end
      if should_exit then
        deskcover.run("--user")        -- final heal before we stop
        if type(opts.on_exit) == "function" then pcall(opts.on_exit) end
        log("Steam closed -> Lumen exiting")
        os.exit(0)
      end
    end
    inj:tick()
    if type(opts.on_tick) == "function" then
      local ok, err = pcall(opts.on_tick, inj, socket.gettime())
      if not ok then log("tick callback failed: " .. tostring(err)) end
    end
  end
end

return loop
