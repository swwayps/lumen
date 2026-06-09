package.path = "lua/?.lua;" .. package.path
local rpc = require("rpc")
local function ok(c, m) if not c then error("FAIL: " .. (m or "")) end end

-- args_to_positional: keys sorted alphabetically, values positional (Millennium).
do
  local vals, n = rpc.args_to_positional({ url = "U", apiName = "A", appid = 5, contentScriptQuery = "" })
  -- sorted keys: apiName, appid, contentScriptQuery, url
  ok(n == 4, "count 4")
  ok(vals[1] == "A", "1=apiName")
  ok(vals[2] == 5, "2=appid")
  ok(vals[3] == "", "3=contentScriptQuery")
  ok(vals[4] == "U", "4=url")
end

-- Registry whose fns expect positional args (like the real backend).
local registry = {
  -- ToggleApi(params, contentScriptQuery): sorted {apiName, contentScriptQuery}
  ToggleApi = function(params, csq) return '{"name":"' .. tostring(params) .. '","csq":"' .. tostring(csq) .. '"}' end,
  -- StartAddFromUrl(apiName, appid, contentScriptQuery, url)
  StartAddFromUrl = function(apiName, appid, csq, url)
    return '{"apiName":"' .. tostring(apiName) .. '","appid":' .. tostring(appid) .. ',"url":"' .. tostring(url) .. '"}'
  end,
  Boom = function() error("kaboom") end,
}

-- 1. Multi-arg positional dispatch (the bug that broke StartAddViaLuaToolsFromUrl).
do
  local body = '{"token":"S","fn":"StartAddFromUrl","args":{"apiName":"SkyAPI","appid":391540,"contentScriptQuery":"","url":"http://x"}}'
  local status, resp = rpc.handle(body, "S", registry)
  ok(status == 200, "status 200")
  ok(resp == '{"apiName":"SkyAPI","appid":391540,"url":"http://x"}', "positional args mapped: " .. tostring(resp))
end

-- 2. ToggleApi: first positional value is apiName.
do
  local status, resp = rpc.handle('{"token":"S","fn":"ToggleApi","args":{"apiName":"X","contentScriptQuery":""}}', "S", registry)
  ok(status == 200, "toggle 200")
  ok(resp == '{"name":"X","csq":""}', "toggle positional: " .. tostring(resp))
end

-- 3. Bad token -> 403.
ok(select(1, rpc.handle('{"token":"W","fn":"ToggleApi","args":{}}', "S", registry)) == 403, "bad token 403")
-- 4. Unknown fn -> 404.
ok(select(1, rpc.handle('{"token":"S","fn":"Nope","args":{}}', "S", registry)) == 404, "unknown 404")
-- 5. Erroring fn -> 500.
ok(select(1, rpc.handle('{"token":"S","fn":"Boom","args":{}}', "S", registry)) == 500, "error 500")
-- 6. Malformed -> 400.
ok(select(1, rpc.handle("not json", "S", registry)) == 400, "malformed 400")

print("test_rpc: ALL PASS")
