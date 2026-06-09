-- Pure RPC handler: parse a JSON request body, validate the session token,
-- dispatch against a registry of backend globals. No IO.
--
-- Millennium-bridge compatibility: Millennium's IPC sorted the JS args object's
-- keys ALPHABETICALLY and passed their VALUES POSITIONALLY to the Lua function.
-- The backend's function signatures are written for that contract (e.g.
-- StartAddViaLuaToolsFromUrl(apiName, appid, contentScriptQuery, url) expects the
-- args {apiName,appid,contentScriptQuery,url} sorted -> positional). Lumen must
-- replicate it exactly so the backend works unmodified (preserves upstream rebase).
local json = require("json")
local rpc = {}

-- args_to_positional(args) -> table of values ordered by sorted key, count
-- Returns the values of `args` ordered by their keys sorted alphabetically,
-- plus the count (so nils in the middle are preserved via table.unpack(t, 1, n)).
function rpc.args_to_positional(args)
  if type(args) ~= "table" then return { args }, 1 end
  -- Collect string keys (the JS object's keys are always strings). Ignore any
  -- array part — Millennium objects are key/value maps.
  local keys = {}
  for k in pairs(args) do
    if type(k) == "string" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  local vals = {}
  for i, k in ipairs(keys) do vals[i] = args[k] end
  return vals, #keys
end

-- dispatch(fn, args) -> ok, result   (calls fn with Millennium-style positional args)
function rpc.dispatch(fn, args)
  local vals, n = rpc.args_to_positional(args)
  return pcall(fn, table.unpack(vals, 1, n))
end

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
  local ok_call, result = rpc.dispatch(fn, req.args or {})
  if not ok_call then
    return 500, '{"error":"' .. tostring(result):gsub('"', "'") .. '"}'
  end
  -- The backend returns JSON strings already; pass through. If a fn ever
  -- returns a non-string, encode it.
  if type(result) ~= "string" then result = json.encode(result) end
  return 200, result
end

return rpc
