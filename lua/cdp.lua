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

-- select_targets(targets, wanted_titles, wanted_origins, wanted_url_frags)
--   -> array of targets.
-- Pure target matcher used by the injector. A target qualifies if it has a
-- webSocketDebuggerUrl AND (its title is in `wanted_titles`, OR its url matches
-- one of `wanted_origins` (exact-host, secure), OR its url contains one of
-- `wanted_url_frags` (substring)). Store pages change title per page, so the
-- store / community web views are matched by origin/url fragment, not title.
-- Both matchers coexist: production Lumen channels use secure `origins`; theme
-- channels use lightweight `urls` fragments. A channel supplies at most one.
--
-- NOTE: the LuaTools frontend (luatools.js) is a WebKit/web-view script (loaded
-- by Millennium via add_browser_js into store/community only). It must NEVER be
-- selected for SharedJSContext — running it in the main client shell breaks the
-- native top menubar. So production config passes no title targets, only the
-- web-view origins. See tools/test_inject.lua.
function cdp.select_targets(targets, wanted_titles, wanted_origins, wanted_url_frags)
  local out = {}
  if type(targets) ~= "table" then return out end
  for _, t in ipairs(targets) do
    if t.webSocketDebuggerUrl then
      local match = wanted_titles and t.title and wanted_titles[t.title]
      if not match and wanted_origins then
        match = cdp.origin_matches(t.url, wanted_origins)
      end
      if not match and t.url and wanted_url_frags then
        for _, frag in ipairs(wanted_url_frags) do
          if t.url:find(frag, 1, true) then match = true; break end
        end
      end
      if match then out[#out + 1] = t end
    end
  end
  return out
end

local function title_pattern_match(title, patterns)
  if type(title) ~= "string" or type(patterns) ~= "table" then return false end
  for _, pattern in ipairs(patterns) do
    local ok, matched = pcall(string.match, title, pattern)
    if ok and matched then return true end
  end
  return false
end

-- route_targets(targets, channels)
--   -> array of { target=, assets=, control=, remote=, browser= }.
-- Each channel is { titles = <set>, origins = <array of origin specs>,
-- urls = <array of url fragments>, title_patterns = <array of lua patterns>,
-- assets = }. A target is routed to the FIRST channel it matches and routed at
-- most once. This is what keeps the store web views and SharedJSContext on
-- DIFFERENT asset bundles: the webkit frontend (luatools.js) goes only to the
-- store/community channel, while the shell (SharedJSContext) gets the lumen-menu
-- bundle — never the reverse.
--
-- `remote` marks a channel whose documents are fetched from the network rather
-- than served by the client itself. It is carried through for the caller's
-- benefit and is NOT yet consumed: store and community pages still receive the
-- full backend registry. Splitting the registry per channel is an outstanding
-- item from the 2026-08 audit (H1 recommendation 4) — it needs the LuaTools
-- frontend and the Lumen settings menu to stop sharing one binding, because the
-- menu is deliberately injected into the web view so its overlay can render above
-- it. Do not read this flag as evidence that the split exists.
function cdp.route_targets(targets, channels)
  local out = {}
  if type(targets) ~= "table" or type(channels) ~= "table" then return out end
  local seen = {}
  for _, ch in ipairs(channels) do
    local matched = cdp.select_targets(targets, ch.titles, ch.origins, ch.urls)
    if ch.title_patterns then
      for _, t in ipairs(targets) do
        if t.webSocketDebuggerUrl and title_pattern_match(t.title, ch.title_patterns) then
          matched[#matched+1] = t
        end
      end
    end
    for _, t in ipairs(matched) do
      if not seen[t.webSocketDebuggerUrl] then
        seen[t.webSocketDebuggerUrl] = true
        out[#out + 1] = {
          target = t, assets = ch.assets,
          control = ch.control, remote = ch.remote, browser = ch.browser,
        }
      end
    end
  end
  -- Optional composing channels add assets to every matching target instead of
  -- replacing the existing menu/webview channel. Themes use this so their
  -- layer reaches all Steam surfaces while the normal Lumen bundles keep their
  -- strict first-match routing. No composing channel exists when themes are
  -- disabled, leaving the old path byte-for-byte equivalent.
  for _, ch in ipairs(channels) do
    if ch.compose then
      for _, t in ipairs(targets) do
        if t.webSocketDebuggerUrl then
          local match = ch.all or (ch.titles and t.title and ch.titles[t.title])
            or title_pattern_match(t.title, ch.title_patterns)
          if not match and t.url and ch.urls then
            for _, frag in ipairs(ch.urls) do
              if t.url:find(frag, 1, true) then match = true; break end
            end
          end
          if match then
            local routed
            for _, r in ipairs(out) do
              if r.target.webSocketDebuggerUrl == t.webSocketDebuggerUrl then routed = r; break end
            end
            if not routed then
              routed = { target=t, assets={ css={}, js={} }, control=ch.control,
                browser=ch.browser }
              out[#out+1] = routed
            end
            if not routed._composed then
              local base = routed.assets or {}
              local copied = { polyfill=base.polyfill, css={}, js={}, deferred_js={},
                virtual_provider=base.virtual_provider }
              for _, css in ipairs(base.css or {}) do copied.css[#copied.css+1] = css end
              for _, js in ipairs(base.js or {}) do copied.js[#copied.js+1] = js end
              for _, js in ipairs(base.deferred_js or {}) do
                copied.deferred_js[#copied.deferred_js+1] = js
              end
              routed.assets = copied
              routed._composed = true
            end
            routed.assets.css = routed.assets.css or {}
            routed.assets.js = routed.assets.js or {}
            for _, css in ipairs((ch.assets and ch.assets.css) or {}) do routed.assets.css[#routed.assets.css+1] = css end
            for _, js in ipairs((ch.assets and ch.assets.js) or {}) do routed.assets.js[#routed.assets.js+1] = js end
            routed.assets.deferred_js = routed.assets.deferred_js or {}
            for _, js in ipairs((ch.assets and ch.assets.deferred_js) or {}) do
              routed.assets.deferred_js[#routed.assets.deferred_js+1] = js
            end
            if ch.assets and ch.assets.virtual_provider then
              routed.assets.virtual_provider = ch.assets.virtual_provider
            end
          end
        end
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
function cdp._session:build_command(method, params, session_id)
  self._id = self._id + 1
  local command = { id = self._id, method = method, params = params or {} }
  if session_id then command.sessionId = session_id end
  return json.encode(command)
end

-- parse_message(text) -> { kind="result", id=N, result=... }
--                      | { kind="error",  id=N, error=... }
--                      | { kind="event",  method=..., params=... }
function cdp.parse_message(text)
  local m = json.decode(text)
  if m.id ~= nil then
    if m.error then return { kind = "error", id = m.id, error = m.error,
      session_id=m.sessionId } end
    return { kind = "result", id = m.id, result = m.result,
      session_id=m.sessionId }
  end
  return { kind = "event", method = m.method, params = m.params,
    session_id=m.sessionId }
end

return cdp
