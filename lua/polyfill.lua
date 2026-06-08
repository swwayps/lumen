-- Builds the Millennium.callServerMethod polyfill injected ahead of luatools.js.
-- Transport: CDP Runtime.addBinding. The page calls window.__lumenSend(jsonReq);
-- the Lumen injector (the CDP client) receives Runtime.bindingCalled, runs the
-- backend fn IN-PROCESS, and calls window.__lumenResolve(id, resultJson) back.
-- This is immune to the page's CSP (the store page's connect-src forbids a
-- loopback fetch), because CDP is not subject to page CSP.
local polyfill = {}

-- The binding name CDP exposes on window (must match injector's addBinding).
polyfill.BINDING = "__lumenSend"

-- build() -> JS source string. No port/token needed (binding transport).
function polyfill.build()
  return ([[
(function () {
  window.__lumenPending = window.__lumenPending || {};
  window.__lumenSeq = window.__lumenSeq || 0;
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
        window.%s(JSON.stringify({ id: id, fn: fn, args: args || {} }));
      } catch (e) {
        delete window.__lumenPending[id];
        reject(e);
      }
    });
  };
})()]]):format(polyfill.BINDING, polyfill.BINDING)
end

-- resolve_js(id, result_json_string) -> JS that settles the page-side promise.
-- Both args are encoded as JS string literals via the json shim by the caller.
function polyfill.resolve_js(id_literal, result_literal)
  return "window.__lumenResolve && window.__lumenResolve(" ..
         id_literal .. "," .. result_literal .. ")"
end

return polyfill
