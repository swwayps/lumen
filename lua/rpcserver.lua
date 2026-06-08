-- Impure loopback HTTP/1.1 server for POST /rpc. One request/response per
-- accepted connection (Connection: close). Delegates parsing+dispatch to rpc.lua.
local rpc = require("rpc")
local httpresp = require("httpresp")
local rpcserver = {}

local REASON = {
  [200] = "OK", [400] = "Bad Request", [403] = "Forbidden",
  [404] = "Not Found", [500] = "Internal Server Error",
}

-- handle_client(client, token, registry): read one HTTP request, dispatch, reply.
function rpcserver.handle_client(client, token, registry)
  client:settimeout(2)
  local buf, header_block, body = "", nil, nil
  while true do
    local chunk, err, partial = client:receive(512)
    local got = chunk or partial
    if got and #got > 0 then buf = buf .. got end
    header_block, body = httpresp.headers_complete(buf)
    if header_block then break end
    if err and err ~= "timeout" then client:close(); return end
    if (not got or #got == 0) and err == "timeout" then break end
  end
  if not header_block then client:close(); return end
  local clen = httpresp.content_length(header_block) or 0
  while #body < clen do
    local chunk, err, partial = client:receive(clen - #body)
    local got = chunk or partial
    if got and #got > 0 then body = body .. got end
    if err and err ~= "timeout" then break end
    if (not got or #got == 0) and err == "timeout" then break end
  end
  local status, resp = rpc.handle(body, token, registry)
  local reason = REASON[status] or "OK"
  client:send("HTTP/1.1 " .. status .. " " .. reason .. "\r\n" ..
              "Content-Type: application/json\r\n" ..
              "Access-Control-Allow-Origin: *\r\n" ..
              "Content-Length: " .. #resp .. "\r\n" ..
              "Connection: close\r\n\r\n" .. resp)
  client:close()
end

return rpcserver
