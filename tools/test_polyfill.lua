package.path = "lua/?.lua;" .. package.path
local polyfill = require("polyfill")
local function has(s, sub, m) if not s:find(sub, 1, true) then error("FAIL "..(m or "")..": missing "..sub) end end

local js = polyfill.build()
has(js, "window.Millennium", "defines Millennium")
has(js, "callServerMethod", "defines callServerMethod")
has(js, "new Promise", "returns a Promise")
has(js, "__lumenSend", "calls the CDP binding")
has(js, "__lumenResolve", "exposes resolver for the injector")
has(js, "__lumenPending", "parks pending resolvers")
-- Must NOT use fetch (CSP-blocked on the store origin).
if js:find("fetch(", 1, true) then error("FAIL: polyfill still uses fetch") end

-- resolve_js wraps the resolver call.
local r = polyfill.resolve_js('"7"', '"{}"')
has(r, "__lumenResolve", "resolve_js calls resolver")
has(r, '"7"', "resolve_js carries id")
print("test_polyfill: ALL PASS")
