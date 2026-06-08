-- Builds the Millennium.callServerMethod polyfill injected ahead of luatools.js.
-- It maps callServerMethod(plugin, fn, args) -> fetch to the loopback RPC host,
-- resolving to the JSON string the frontend expects (it does its own JSON.parse).
local polyfill = {}

-- build(port, token) -> JS source string
-- NOTE: always (re)assigns callServerMethod so a restarted Lumen (new port/token)
-- refreshes the binding. SharedJSContext persists across Lumen restarts, so a
-- guard like `if (!callServerMethod)` would pin a stale port. We instead keep the
-- LATEST port/token on window and have the function read them at call time.
function polyfill.build(port, token)
  return ([[
(function () {
  window.Millennium = window.Millennium || {};
  window.__lumenRpc = { port: %d, token: "%s" };
  window.Millennium.callServerMethod = function (plugin, fn, args) {
    var rpc = window.__lumenRpc;
    return fetch("http://127.0.0.1:" + rpc.port + "/rpc", {
      method: "POST",
      body: JSON.stringify({ token: rpc.token, fn: fn, args: args || {} })
    }).then(function (r) { return r.text(); });
  };
})()]]):format(port, token)
end

return polyfill
