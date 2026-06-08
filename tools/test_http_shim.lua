package.path = "lua/?.lua;" .. package.path
-- Stub the C module before requiring the shim (host lua5.4 has no lumen_http).
package.loaded["lumen_http"] = {
  perform = function(req) return { status = 200, body = "OK:" .. req.method .. ":" .. req.url } end,
}
local http = require("http")
local function ok(c, m) if not c then error("FAIL: "..(m or "")) end end

local r = http.get("http://x/y")
ok(r.status == 200 and r.body == "OK:GET:http://x/y", "get maps method+url")
local h = http.head("http://x/z")
ok(h.body == "OK:HEAD:http://x/z", "head maps HEAD")
local p = http.post("http://x/p", "payload", { timeout = 5 })
ok(p.body == "OK:POST:http://x/p", "post maps POST")
print("test_http_shim: ALL PASS")
