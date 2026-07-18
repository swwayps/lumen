package.path = "lua/?.lua;" .. package.path
-- Stub the C module before requiring the shim (host lua5.4 has no lumen_http).
local last_req
package.loaded["lumen_http"] = {
  perform = function(req)
    last_req = req
    return { status = 200, body = "OK:" .. req.method .. ":" .. req.url }
  end,
  start = function(req)
    last_req = req
    return { request = req }
  end,
  poll = function(handle)
    return true, {
      status = 200,
      body = "ASYNC:" .. handle.request.method .. ":" .. handle.request.url,
    }
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

http.get("https://store.steampowered.com/", {
  follow_redirects = false,
  https_only = true,
  max_bytes = 8 * 1024 * 1024,
})
ok(last_req.follow_redirects == false, "redirect policy reaches the C binding")
ok(last_req.https_only == true, "HTTPS-only policy reaches the C binding")
ok(last_req.max_bytes == 8 * 1024 * 1024, "response limit reaches the C binding")

local pending = http.start("https://store.steampowered.com/", {
  headers = { ["User-Agent"] = "Valve Steam Client" },
  timeout = 10,
  follow_redirects = false,
  https_only = true,
  max_bytes = 8 * 1024 * 1024,
})
ok(type(pending) == "table", "async request returns a pollable handle")
ok(last_req.method == "GET", "async request defaults to GET")
ok(last_req.follow_redirects == false, "async redirect policy reaches the C binding")
ok(last_req.https_only == true, "async HTTPS-only policy reaches the C binding")
ok(last_req.max_bytes == 8 * 1024 * 1024, "async response limit reaches the C binding")
ok(find(last_req.headers, "User-Agent: Valve Steam Client"),
  "async request normalizes headers")
local done, async_response = http.poll(pending)
ok(done == true and async_response.body:find("ASYNC:GET:", 1, true),
  "async poll returns the completed response")

print("test_http_shim: ALL PASS")
