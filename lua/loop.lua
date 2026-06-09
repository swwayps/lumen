-- Single-process event loop driving the multi-target CDP injector. The
-- frontend talks to the backend via Runtime.addBinding (handled inside the
-- injector), so there is NO loopback HTTP server / port / token anymore.
local socket = require("socket")
local injector = require("injector")

local loop = {}

-- run{ registry=, build_assets=, targets=, target_urls= }
function loop.run(opts)
  local assets = opts.build_assets and opts.build_assets() or nil
  local inj = injector.new({
    targets = opts.targets,
    target_urls = opts.target_urls,
    assets = assets,
    registry = opts.registry,
  })
  while true do
    local fds = inj:fds()
    if #fds > 0 then
      socket.select(fds, nil, 1)
    else
      socket.sleep(1)   -- nothing attached yet; idle before re-discovering
    end
    inj:tick()
  end
end

return loop
