-- cdpreq.lua — one-shot, blocking CDP request against a CEF target.
--
-- The injector's own connections are event-driven and fire-and-forget: they push
-- Runtime.evaluate and never read a command result back. The Ryuu sign-in needs
-- actual RESULTS (Network.getCookies, and the browser-view URL to restore), so
-- this module opens its own short-lived websocket, sends one command, waits for
-- the matching id and closes. CEF allows several debugger clients per target, so
-- this coexists with the injector's live connection (verified on a live client).
--
-- Blocking is deliberate and bounded (default 5s): these calls run inside an RPC
-- handler that the frontend already awaits, and the poll interval is seconds.
local socket = require("socket")
local json = require("json")
local wsframe = require("wsframe")
local cdp = require("cdp")
local httpresp = require("httpresp")

local cdpreq = {}

local HOST = "127.0.0.1"
local DEFAULT_TIMEOUT = 5

-- ws_path("ws://127.0.0.1:8080/devtools/page/AB") -> "/devtools/page/AB"
function cdpreq.ws_path(ws_url)
  return (tostring(ws_url or ""):match("^ws://[^/]+(/.*)$"))
end

local function handshake(c, path, port)
  c:send("GET " .. path .. " HTTP/1.1\r\n"
    .. "Host: " .. HOST .. ":" .. tostring(port) .. "\r\n"
    .. "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    .. "Sec-WebSocket-Version: 13\r\n\r\n")
  local resp = ""
  while not resp:find("\r\n\r\n", 1, true) do
    local chunk = c:receive(1)
    if not chunk then return false end
    resp = resp .. chunk
  end
  return resp:find("101", 1, true) ~= nil
end

-- request(port, ws_url, method, params, timeout) -> result table | nil, err
function cdpreq.request(port, ws_url, method, params, timeout)
  local path = cdpreq.ws_path(ws_url)
  if not path then return nil, "bad websocket url" end
  timeout = timeout or DEFAULT_TIMEOUT

  local c = socket.tcp()
  if not c then return nil, "no socket" end
  c:settimeout(timeout)
  if not c:connect(HOST, port) then c:close(); return nil, "connect failed" end
  if not handshake(c, path, port) then c:close(); return nil, "handshake failed" end

  local session = cdp.new_session()
  local ok_send = c:send(wsframe.encode_text(
    session:build_command(method, params or {})))
  if not ok_send then c:close(); return nil, "send failed" end
  local want = session._id

  local deadline = socket.gettime() + timeout
  local buf = ""
  while socket.gettime() < deadline do
    c:settimeout(0.2)
    local chunk, err, partial = c:receive(4096)
    local got = chunk or partial
    if got and #got > 0 then buf = buf .. got end
    while true do
      local payload, opcode, rest, complete = wsframe.decode_frame(buf)
      if not complete then break end
      buf = rest
      if opcode == 0x8 then c:close(); return nil, "closed" end
      if opcode == 0x1 then
        local ok_parse, msg = pcall(cdp.parse_message, payload)
        if ok_parse and msg.id == want then
          c:close()
          if msg.kind == "error" then
            return nil, "cdp error: " .. tostring(json.encode(msg.error))
          end
          return msg.result or {}
        end
      end
    end
    if err and err ~= "timeout" then c:close(); return nil, tostring(err) end
  end
  c:close()
  return nil, "timeout"
end

-- evaluate(port, ws_url, expr, timeout, user_gesture) -> value | nil, err
-- Runs a JS expression and unwraps Runtime.evaluate's returnByValue result. A
-- thrown expression is an error, not a nil value, so callers can tell "the API
-- is missing" from "the API said no".
--
-- user_gesture matters: CEF's popup blocker silently drops a target=_blank click
-- that has no user gesture behind it. The anchor click still reports success, so
-- without this flag the Ryuu sign-in "works" and no window ever appears.
function cdpreq.evaluate(port, ws_url, expr, timeout, user_gesture)
  local result, err = cdpreq.request(port, ws_url, "Runtime.evaluate",
    { expression = expr, returnByValue = true, awaitPromise = true,
      userGesture = user_gesture == true }, timeout)
  if not result then return nil, err end
  if result.exceptionDetails then return nil, "js exception" end
  local inner = result.result
  if type(inner) ~= "table" then return nil, "no result" end
  return inner.value
end

return cdpreq
