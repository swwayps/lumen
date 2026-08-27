package.path = "lua/?.lua;" .. package.path
local polyfill = require("polyfill")
local function has(s, sub, m) if not s:find(sub, 1, true) then error("FAIL "..(m or "")..": missing "..sub) end end
local function ok(c, m) if not c then error("FAIL: " .. (m or "")) end end
local js = polyfill.build("deadbeef")
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

-- ── per-connection token ────────────────────────────────────────────────────
-- Runtime.addBinding exposes window.__lumenSend to EVERY execution context of
-- the page, including cross-origin subframes (ads, embedded widgets). The
-- polyfill is evaluated only in the page's own default context, so the token it
-- carries is unreadable from another origin's frame. Requests without it are
-- dropped instead of dispatched.
has(js, "deadbeef", "token embedded in the injected polyfill")

-- The token is emitted as a JS string literal, so a hostile value cannot break
-- out of the expression.
do
  local weird = polyfill.build('a";alert(1);//')
  -- The double quote must arrive backslash-escaped, so the statement stays
  -- inside the string literal instead of terminating it. (Which other
  -- characters the JSON encoder escapes is encoder-specific: lua-cjson also
  -- escapes "/", the pure-Lua shim does not. Only the quote matters here.)
  ok(weird:find('var __lumenKey = "a\\";alert(1);', 1, true) ~= nil,
    "token quote is backslash-escaped inside the literal")
  -- With every backslash escape pair removed there must be no point where the
  -- literal ends and a statement begins.
  local stripped = weird:gsub("\\.", "")
  ok(not stripped:find('";alert', 1, true), "no unescaped literal break-out")
end

-- parse_request accepts a well-formed payload carrying the right token.
do
  local req, why = polyfill.parse_request(
    '{"id":"3","fn":"GetThemes","args":{"a":1},"k":"deadbeef"}', "deadbeef")
  ok(req ~= nil, "valid payload accepted (" .. tostring(why) .. ")")
  ok(req.id == "3", "id preserved")
  ok(req.fn == "GetThemes", "fn preserved")
  ok(type(req.args) == "table" and req.args.a == 1, "args preserved")
end

-- parse_request rejects a payload with a wrong, missing or empty token.
do
  local a = polyfill.parse_request('{"id":"1","fn":"UpdateAll","k":"wrong"}', "deadbeef")
  ok(a == nil, "wrong token rejected")
  local b = polyfill.parse_request('{"id":"1","fn":"UpdateAll"}', "deadbeef")
  ok(b == nil, "missing token rejected")
  local c = polyfill.parse_request('{"id":"1","fn":"UpdateAll","k":""}', "deadbeef")
  ok(c == nil, "empty token rejected")
end

-- An empty or absent expected token never turns the check into a pass-through.
do
  ok(polyfill.parse_request('{"id":"1","fn":"X","k":""}', "") == nil,
    "empty expected token accepts nothing")
  ok(polyfill.parse_request('{"id":"1","fn":"X"}', nil) == nil,
    "nil expected token accepts nothing")
end

-- parse_request rejects malformed JSON and non-string fn.
do
  ok(polyfill.parse_request("not json", "deadbeef") == nil, "malformed JSON rejected")
  ok(polyfill.parse_request('{"id":"1","fn":42,"k":"deadbeef"}', "deadbeef") == nil,
    "non-string fn rejected")
  ok(polyfill.parse_request('{"id":"1","k":"deadbeef"}', "deadbeef") == nil,
    "missing fn rejected")
end

-- The token must be compared in full: a correct prefix is not enough.
do
  ok(polyfill.parse_request('{"id":"1","fn":"X","k":"dead"}', "deadbeef") == nil,
    "token prefix rejected")
  ok(polyfill.parse_request('{"id":"1","fn":"X","k":"deadbeefff"}', "deadbeef") == nil,
    "token with extra suffix rejected")
end

print("test_polyfill: ALL PASS")
