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

-- select_targets(targets, wanted_titles, wanted_url_frags) -> array of targets.
-- Pure target matcher used by the injector. A target qualifies if it has a
-- webSocketDebuggerUrl AND (its title is in `wanted_titles`, OR its url contains
-- one of `wanted_url_frags`). Store pages change title per page, so the store /
-- community web views are matched by URL fragment, not title.
--
-- NOTE: the LuaTools frontend (luatools.js) is a WebKit/web-view script (loaded
-- by Millennium via add_browser_js into store/community only). It must NEVER be
-- selected for SharedJSContext — running it in the main client shell breaks the
-- native top menubar. So production config passes no title targets, only the
-- web-view URL fragments. See tools/test_inject.lua.
function cdp.select_targets(targets, wanted_titles, wanted_url_frags)
  local out = {}
  if type(targets) ~= "table" then return out end
  for _, t in ipairs(targets) do
    if t.webSocketDebuggerUrl then
      local match = wanted_titles and t.title and wanted_titles[t.title]
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

-- route_targets(targets, channels) -> array of { target=, assets= }.
-- Each channel is { titles = <set>, urls = <array of url fragments>, assets = }.
-- A target is routed to the FIRST channel it matches (by title or url fragment,
-- same rule as select_targets) and routed at most once. This is what keeps the
-- store web views and SharedJSContext on DIFFERENT asset bundles: the webkit
-- frontend (luatools.js) goes only to the store/community channel, while the
-- shell (SharedJSContext) gets the lumen-menu bundle — never the reverse.
function cdp.route_targets(targets, channels)
  local out = {}
  if type(targets) ~= "table" or type(channels) ~= "table" then return out end
  local seen = {}
  for _, ch in ipairs(channels) do
    local matched = cdp.select_targets(targets, ch.titles, ch.urls)
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
        out[#out + 1] = { target = t, assets = ch.assets, control = ch.control,
          browser = ch.browser }
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
