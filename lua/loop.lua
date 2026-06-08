-- Unified single-process event loop: drives the RPC server accept + the CDP
-- injector cooperatively via socket.select, idle when nothing happens.
local socket = require("socket")
local session = require("session")
local rpcserver = require("rpcserver")
local injector = require("injector")

local loop = {}

-- run{ session_path=, registry=, build_assets=, targets= }
function loop.run(opts)
  local srv, port, token = session.start(opts.session_path)
  srv:settimeout(0)
  io.stderr:write("[lumen] rpc on 127.0.0.1:" .. port .. " (debug/non-CDP only)\n")
  io.stderr:flush()

  local assets = opts.build_assets and opts.build_assets() or nil
  local inj = injector.new({
    targets = opts.targets,
    target_urls = opts.target_urls,
    assets = assets,
    registry = opts.registry,
  })

  while true do
    local fds = { srv }
    for _, s in ipairs(inj:fds()) do fds[#fds + 1] = s end
    -- 1s tick so the injector can discover/attach even with no socket events.
    local readable = socket.select(fds, nil, 1)
    for _, s in ipairs(readable) do
      if s == srv then
        local client = srv:accept()
        if client then
          local ok, err = pcall(rpcserver.handle_client, client, token, opts.registry)
          if not ok then
            io.stderr:write("[lumen] rpc handler error: " .. tostring(err) .. "\n")
            io.stderr:flush()
            pcall(function() client:close() end)
          end
        end
      end
    end
    inj:tick()
  end
end

return loop
