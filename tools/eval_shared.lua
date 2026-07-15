-- Evaluate a JS expression in SharedJSContext and print the result. Spike/debug
-- helper. Usage: LUMEN_LUA_DIR=lua ./lumen --eval "<js expression>"
local socket = require("socket")
local json = require("json")
local wsframe = require("wsframe")
local cdp = require("cdp")
local httpresp = require("httpresp")

local HOST = "127.0.0.1"
local PORT = tonumber(os.getenv("LUMEN_CEF_PORT")) or 8080
local EXPR = os.getenv("LUMEN_EVAL_EXPR") or "1+1"
local WANT = os.getenv("LUMEN_EVAL_TARGET") or "SharedJSContext"

local function http_get(path)
  local c = socket.tcp(); c:settimeout(5)
  if not c:connect(HOST, PORT) then return nil end
  c:send("GET " .. path .. " HTTP/1.1\r\nHost: " .. HOST .. "\r\nAccept: */*\r\n\r\n")
  local buf, hb, body = "", nil, nil
  while true do
    local chunk, err, partial = c:receive(256)
    local got = chunk or partial
    if got and #got > 0 then buf = buf .. got end
    hb, body = httpresp.headers_complete(buf)
    if hb then break end
    if err and err ~= "timeout" then c:close(); return nil end
    if (not got or #got == 0) and err == "timeout" then c:close(); return nil end
  end
  local clen = httpresp.content_length(hb)
  if clen then
    while #body < clen do
      local chunk, err, partial = c:receive(clen - #body)
      local got = chunk or partial
      if got and #got > 0 then body = body .. got end
      if err and err ~= "timeout" then break end
      if (not got or #got == 0) and err == "timeout" then break end
    end
  end
  c:close(); return body
end

local body = assert(http_get("/json"), "no /json")
local targets = json.decode(body)
local target
for _, t in ipairs(targets) do
  if t.title == WANT and t.webSocketDebuggerUrl then target = t; break end
end
assert(target, "target not found: " .. WANT)
local path = target.webSocketDebuggerUrl:match("^ws://[^/]+(/.*)$")
local c = socket.tcp(); c:settimeout(5)
assert(c:connect(HOST, PORT))
c:send("GET " .. path .. " HTTP/1.1\r\nHost: " .. HOST .. ":" .. PORT ..
       "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ..
       "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
local resp = ""
while not resp:find("\r\n\r\n", 1, true) do resp = resp .. (c:receive(1) or "") end
assert(resp:find("101", 1, true), "ws upgrade failed")

local session = cdp.new_session()
if os.getenv("LUMEN_EVAL_RESUME") == "1" then
  c:send(wsframe.encode_text(session:build_command(
    "Runtime.runIfWaitingForDebugger", {})))
end
-- awaitPromise so promise-returning expressions resolve to their value.
local id_cmd = session:build_command("Runtime.evaluate",
  { expression = EXPR, returnByValue = true, awaitPromise = true })
local want_id = session._id
c:send(wsframe.encode_text(id_cmd))

c:settimeout(0.2)
local buf = ""
for _ = 1, 75 do
  local chunk, err, partial = c:receive(4096)
  local got = chunk or partial or ""
  if #got > 0 then buf = buf .. got end
  while true do
    local payload, opcode, rest, complete = wsframe.decode_frame(buf)
    if not complete then break end
    buf = rest
    if opcode == 0x1 then
      local m = cdp.parse_message(payload)
      if m.kind == "result" and m.id == want_id then
        local r = m.result and m.result.result
        if r and r.value ~= nil then print("EVAL: " .. tostring(r.value))
        elseif m.result and m.result.exceptionDetails then
          print("EVAL EXCEPTION: " .. json.encode(m.result.exceptionDetails))
        else print("EVAL: " .. json.encode(m.result or {})) end
        c:close(); os.exit(0)
      end
    end
  end
  if err and err ~= "timeout" then break end
  socket.sleep(0.1)
end
print("EVAL: no result")
c:close()
