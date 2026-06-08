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
