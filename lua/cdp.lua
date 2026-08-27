-- Pure CDP helpers: select the SharedJSContext target, build commands with
-- incrementing ids, and classify incoming messages. No IO.
local json = require("json")
local cdp = {}

-- find_shared_js_context(targets) -> target table or nil
function cdp.find_shared_js_context(targets)
  for _, t in ipairs(targets) do
    if t.title == "SharedJSContext" and t.webSocketDebuggerUrl then
      return t
    end
  end
  return nil
end

-- parse_origin(url) -> host, path   (nil when the URL is not usable)
-- Only `https://` URLs are accepted, the host is lowercased, and the path is
-- returned without query or fragment ("/" when empty). A URL carrying userinfo
-- ("https://store.steampowered.com@evil.example/") is rejected outright: the
-- authority a human reads there is not the authority the browser connects to.
function cdp.parse_origin(url)
  local host, path = tostring(url or ""):match("^https://([^/%?#]+)([^?#]*)")
  if not host then return nil end
  if host:find("@", 1, true) then return nil end
  if path == "" then path = "/" end
  return host:lower(), path
end

-- origin_matches(url, origins) -> boolean
-- `origins` is an array of { host = <exact host>, path_prefix = <optional> }.
-- The host must match EXACTLY (never as a substring: a channel for
-- store.steampowered.com must not accept store.steampowered.com.evil.example
-- nor https://attacker.example/?ref=store.steampowered.com). `path_prefix`,
-- when present, matches on segment boundaries only, so "/marketingmessages/list"
-- does not also match "/marketingmessages/listing".
function cdp.origin_matches(url, origins)
  if type(origins) ~= "table" then return false end
  local host, path = cdp.parse_origin(url)
  if not host then return false end
  for _, spec in ipairs(origins) do
    if type(spec) == "table" and spec.host
        and host == tostring(spec.host):lower() then
      local prefix = spec.path_prefix
      if prefix == nil or prefix == "" or prefix == "/" then return true end
      prefix = tostring(prefix)
      if path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" then
        return true
      end
    end
  end
  return false
end

-- select_targets(targets, wanted_titles, wanted_origins) -> array of targets.
-- Pure target matcher used by the injector. A target qualifies if it has a
-- webSocketDebuggerUrl AND (its title is in `wanted_titles`, OR its url matches
-- one of `wanted_origins`). Store pages change title per page, so the store /
-- community web views are matched by origin, not title.
--
-- NOTE: the LuaTools frontend (luatools.js) is a WebKit/web-view script (loaded
-- by Millennium via add_browser_js into store/community only). It must NEVER be
-- selected for SharedJSContext — running it in the main client shell breaks the
-- native top menubar. So production config passes no title targets, only the
-- web-view origins. See tools/test_inject.lua.
function cdp.select_targets(targets, wanted_titles, wanted_origins)
  local out = {}
  if type(targets) ~= "table" then return out end
  for _, t in ipairs(targets) do
    if t.webSocketDebuggerUrl then
      local match = wanted_titles and t.title and wanted_titles[t.title]
      if not match and wanted_origins then
        match = cdp.origin_matches(t.url, wanted_origins)
      end
      if match then out[#out + 1] = t end
    end
  end
  return out
end

-- route_targets(targets, channels) -> array of { target=, assets=, control=, remote= }.
-- Each channel is { titles = <set>, origins = <array of origin specs>, assets = }.
-- A target is routed to the FIRST channel it matches (by title or origin, same
-- rule as select_targets) and routed at most once. This is what keeps the store
-- web views and SharedJSContext on DIFFERENT asset bundles: the webkit frontend
-- (luatools.js) goes only to the store/community channel, while the shell
-- (SharedJSContext) gets the lumen-menu bundle — never the reverse.
--
-- `remote` marks a channel whose documents are fetched from the network rather
-- than served by the client itself. The injector uses it to hand those contexts
-- a reduced RPC registry: script running in a Valve web page is not the same
-- trust level as script the client itself shipped.
function cdp.route_targets(targets, channels)
  local out = {}
  if type(targets) ~= "table" or type(channels) ~= "table" then return out end
  local seen = {}
  for _, ch in ipairs(channels) do
    local matched = cdp.select_targets(targets, ch.titles, ch.origins)
    for _, t in ipairs(matched) do
      if not seen[t.webSocketDebuggerUrl] then
        seen[t.webSocketDebuggerUrl] = true
        out[#out + 1] = {
          target = t, assets = ch.assets,
          control = ch.control, remote = ch.remote,
        }
      end
    end
  end
  return out
end

-- A session tracks the monotonically increasing CDP command id.
function cdp.new_session()
  return setmetatable({ _id = 0 }, { __index = cdp._session })
end

cdp._session = {}
function cdp._session:build_command(method, params)
  self._id = self._id + 1
  return json.encode({ id = self._id, method = method, params = params or {} })
end

-- parse_message(text) -> { kind="result", id=N, result=... }
--                      | { kind="error",  id=N, error=... }
--                      | { kind="event",  method=..., params=... }
function cdp.parse_message(text)
  local m = json.decode(text)
  if m.id ~= nil then
    if m.error then return { kind = "error", id = m.id, error = m.error } end
    return { kind = "result", id = m.id, result = m.result }
  end
  return { kind = "event", method = m.method, params = m.params }
end

return cdp
