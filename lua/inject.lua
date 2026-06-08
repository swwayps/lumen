-- Builds JS payloads for Runtime.evaluate. Pure string construction.
local inject = {}

-- Escape a Lua string for safe embedding inside a JS double-quoted literal.
function inject.js_string(s)
  return (s:gsub('[\\"\n\r\t]', {
    ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n",
    ["\r"] = "\\r", ["\t"] = "\\t",
  }))
end

-- toast_payload(msg) -> JS that shows a transient on-screen toast exactly once
-- per context (idempotent via the window.__lumenInjected sentinel). For the
-- spike this is our visible proof that injection + re-injection works.
function inject.toast_payload(msg)
  local m = inject.js_string(msg)
  return ([[
(function () {
  if (window.__lumenInjected) { return "already"; }
  window.__lumenInjected = true;
  try {
    var el = document.createElement("div");
    el.textContent = "%s";
    el.style.cssText =
      "position:fixed;top:16px;right:16px;z-index:999999;" +
      "background:#1b2838;color:#66c0f4;padding:10px 14px;" +
      "border:1px solid #66c0f4;border-radius:6px;font:14px sans-serif;" +
      "box-shadow:0 2px 8px rgba(0,0,0,.5);";
    document.body.appendChild(el);
    setTimeout(function () { el.remove(); }, 4000);
  } catch (e) {}
  return "injected";
})()]]):format(m)
end

return inject
