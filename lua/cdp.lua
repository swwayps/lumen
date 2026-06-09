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
