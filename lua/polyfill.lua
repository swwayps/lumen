-- Builds the Millennium.callServerMethod polyfill injected ahead of luatools.js.
-- It maps callServerMethod(plugin, fn, args) -> fetch to the loopback RPC host,
-- resolving to the JSON string the frontend expects (it does its own JSON.parse).
local polyfill = {}

-- build(port, token) -> JS source string
function polyfill.build(port, token)
  return ([[
(function () {
  window.Millennium = window.Millennium || {};
  if (!window.Millennium.callServerMethod) {
    window.Millennium.callServerMethod = function (plugin, fn, args) {
      return fetch("http://127.0.0.1:%d/rpc", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: "%s", fn: fn, args: args || {} })
      }).then(function (r) { return r.text(); });
    };
  }
})()]]):format(port, token)
end

return polyfill
