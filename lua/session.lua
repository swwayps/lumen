-- session: pick an ephemeral loopback port + random token, persist to
-- session.json (chmod 600) so the injected polyfill (Phase 3) can read them.
local socket = require("socket")
local json = require("json")
local session = {}

local function random_token()
  -- 32 hex chars from /dev/urandom (fallback to math.random seeded by time).
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(16); f:close()
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
  math.randomseed(os.time())
  local t = {}
  for i = 1, 32 do t[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(t)
end

-- start(path) -> server_sock, port, token  (binds 127.0.0.1:0 -> ephemeral port)
function session.start(path)
  local srv = assert(socket.bind("127.0.0.1", 0))
  local _, port = srv:getsockname()
  local token = random_token()
  local f = assert(io.open(path, "w"))
  f:write(json.encode({ port = tonumber(port), token = token }))
  f:close()
  os.execute("chmod 600 '" .. path .. "'")
  return srv, tonumber(port), token
end

return session
