-- Unified single-process event loop: drives the RPC server accept + the CDP
-- injector cooperatively via socket.select, idle when nothing happens.
local socket = require("socket")
local session = require("session")
local rpcserver = require("rpcserver")
local injector = require("injector")

local loop = {}

-- run{ session_path=, registry=, inject_opts= }
function loop.run(opts)
  local srv, port, token = session.start(opts.session_path)
  srv:settimeout(0)
  io.stderr:write("[lumen] rpc on 127.0.0.1:" .. port .. "\n"); io.stderr:flush()

  local inj = injector.new(opts.inject_opts or {})

  while true do
    local fds = { srv }
    local cdp_fd = inj:fd()
    if cdp_fd then fds[#fds + 1] = cdp_fd end
    -- 1s tick so the injector can run backoff/attach even with no socket events.
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
