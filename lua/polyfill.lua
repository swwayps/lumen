-- Builds the Millennium.callServerMethod polyfill injected ahead of luatools.js.
-- Transport: CDP Runtime.addBinding. The page calls window.__lumenSend(jsonReq);
-- the Lumen injector (the CDP client) receives Runtime.bindingCalled, runs the
-- backend fn IN-PROCESS, and calls window.__lumenResolve(id, resultJson) back.
-- This is immune to the page's CSP (the store page's connect-src forbids a
-- loopback fetch), because CDP is not subject to page CSP.
--
-- SCOPE OF THE BINDING. Runtime.addBinding exposes the binding function on
-- EVERY execution context of the target, which on a Steam store page includes
-- cross-origin subframes (embedded widgets, third-party scripts). The binding
-- name is fixed and therefore guessable. So each connection carries a random
-- per-connection token: it is written into the polyfill, and the polyfill is
-- evaluated only in the page's own default context. A subframe from another
-- origin cannot read the main frame's window, so it cannot learn the token, and
-- the injector drops any request that does not carry it (parse_request).
local json = require("json")
local polyfill = {}

-- The binding name CDP exposes on window (must match injector's addBinding).
polyfill.BINDING = "__lumenSend"

-- The payload field carrying the per-connection token.
polyfill.TOKEN_FIELD = "k"

-- The global the token is published on, for injected scripts that call the
-- binding directly instead of going through callServerMethod.
polyfill.TOKEN_GLOBAL = "__lumenKey"

-- token_js(token) -> JS that publishes the connection's token.
--
-- Evaluated on EVERY connection, including channels that ship no polyfill. The
-- SharedJSContext control channel is one of those: its auto-fix launch guard
-- calls window.__lumenSend
-- directly because they never needed the promise machinery, and without the token
-- every one of their calls would now be dropped, silently breaking automatic-fix
-- cancellation before launch.
--
-- Publishing it as a global is no weaker than keeping it in the polyfill's
-- closure: any script in the same world can already call the closure.
function polyfill.token_js(token)
  return "window." .. polyfill.TOKEN_GLOBAL .. "=" ..
    json.encode(tostring(token or "")) .. ";"
end

-- build(token) -> JS source string. `token` is the per-connection value the
-- injector expects back on every call; it is emitted as a JS string literal.
function polyfill.build(token)
  local token_literal = json.encode(tostring(token or ""))
  return ([[
(function () {
  window.__lumenPending = window.__lumenPending || {};
  window.__lumenSeq = window.__lumenSeq || 0;
  var __lumenKey = %s;
  // Called by the injector (via Runtime.evaluate) to settle a pending promise.
  window.__lumenResolve = function (id, result) {
    var cb = window.__lumenPending[id];
    if (cb) { delete window.__lumenPending[id]; cb(result); }
  };
  window.Millennium = window.Millennium || {};
  window.Millennium.callServerMethod = function (plugin, fn, args) {
    return new Promise(function (resolve, reject) {
      if (typeof window.%s !== "function") {
        reject(new Error("lumen binding unavailable"));
        return;
      }
      var id = String(++window.__lumenSeq);
      window.__lumenPending[id] = resolve;
      try {
        window.%s(JSON.stringify(
          { id: id, fn: fn, args: args || {}, %s: __lumenKey }));
      } catch (e) {
        delete window.__lumenPending[id];
        reject(e);
      }
    });
  };
})()]]):format(token_literal, polyfill.BINDING, polyfill.BINDING,
    polyfill.TOKEN_FIELD)
end

-- parse_request(payload_str, expected_token) -> req table, or nil + reason.
-- Validates the wire shape AND the per-connection token before the caller is
-- allowed to dispatch anything. An absent or empty `expected_token` accepts
-- nothing: a missing token must never degrade into "no check".
function polyfill.parse_request(payload_str, expected_token)
  if type(expected_token) ~= "string" or expected_token == "" then
    return nil, "no session token"
  end
  local ok, req = pcall(json.decode, payload_str)
  if not ok or type(req) ~= "table" then return nil, "malformed payload" end
  local got = req[polyfill.TOKEN_FIELD]
  if type(got) ~= "string" or got == "" then return nil, "missing token" end
  if #got ~= #expected_token or got ~= expected_token then
    return nil, "bad token"
  end
  if type(req.fn) ~= "string" or req.fn == "" then return nil, "missing fn" end
  return req
end

-- resolve_js(id, result_json_string) -> JS that settles the page-side promise.
-- Both args are encoded as JS string literals via the json shim by the caller.
function polyfill.resolve_js(id_literal, result_literal)
  return "window.__lumenResolve && window.__lumenResolve(" ..
         id_literal .. "," .. result_literal .. ")"
end

return polyfill
