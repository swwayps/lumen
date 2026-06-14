package.path = "lua/?.lua;" .. package.path
-- Stub the C module before requiring the shim (host lua5.4 has no lumen_http).
local last_req
package.loaded["lumen_http"] = {
  perform = function(req)
    last_req = req
    return { status = 200, body = "OK:" .. req.method .. ":" .. req.url }
  end,
}
local http = require("http")
local function ok(c, m) if not c then error("FAIL: "..(m or "")) end end

local r = http.get("http://x/y")
ok(r.status == 200 and r.body == "OK:GET:http://x/y", "get maps method+url")
local h = http.head("http://x/z")
ok(h.body == "OK:HEAD:http://x/z", "head maps HEAD")
local p = http.post("http://x/p", "payload", { timeout = 5 })
ok(p.body == "OK:POST:http://x/p", "post maps POST")

-- Header normalization: the C binding (curl_slist) only understands an ARRAY of
-- "Key: Value" strings. The LuaTools backend passes a key->value MAP
-- (e.g. { ["User-Agent"] = "..." }), so the shim must translate it; otherwise
-- the header is dropped and UA-gated APIs (TwentyTwo Cloud) reject with 401.
local function find(arr, want)
  if type(arr) ~= "table" then return false end
  for _, v in ipairs(arr) do if v == want then return true end end
  return false
end

http.get("http://x/m", { headers = { ["User-Agent"] = "UA/1" } })
ok(type(last_req.headers) == "table", "map headers -> table")
ok(find(last_req.headers, "User-Agent: UA/1"), "map header normalized to 'Key: Value'")

http.get("http://x/a", { headers = { "X-Custom: 1", "Accept: application/json" } })
ok(find(last_req.headers, "X-Custom: 1") and find(last_req.headers, "Accept: application/json"),
  "array headers pass through unchanged")

http.get("http://x/n")
ok(last_req.headers == nil, "no headers stays nil")

print("test_http_shim: ALL PASS")
