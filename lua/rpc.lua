-- Pure RPC handler: parse a JSON request body, validate the session token,
-- dispatch fn(args) against a registry of backend globals. No IO.
local json = require("json")
local rpc = {}

-- handle(body, token, registry) -> http_status, response_body
function rpc.handle(body, token, registry)
  local ok_parse, req = pcall(json.decode, body)
  if not ok_parse or type(req) ~= "table" then
    return 400, '{"error":"bad request"}'
  end
  if req.token ~= token then
    return 403, '{"error":"forbidden"}'
  end
  local fn = registry[req.fn]
  if type(fn) ~= "function" then
    return 404, '{"error":"unknown method"}'
  end
  local ok_call, result = pcall(fn, req.args or {})
  if not ok_call then
    return 500, '{"error":"' .. tostring(result):gsub('"', "'") .. '"}'
  end
  -- The backend returns JSON strings already; pass through. If a fn ever
  -- returns a non-string, encode it.
  if type(result) ~= "string" then result = json.encode(result) end
  return 200, result
end

return rpc
