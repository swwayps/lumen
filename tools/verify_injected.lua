-- Spike verification helper (run on the VM via the lumen binary):
--   LUMEN_LUA_DIR=lua ./lumen --verify
-- Opens its own CDP session to SharedJSContext and reads window.__lumenInjected,
-- proving (independently of the visual toast) that the injector set the sentinel.
local socket = require("socket")
local json = require("json")
local wsframe = require("wsframe")
local cdp = require("cdp")
local httpresp = require("httpresp")

local HOST, PORT = "127.0.0.1", 8080

local function http_get(path)
  local c = socket.tcp(); c:settimeout(5)
  if not c:connect(HOST, PORT) then return nil end
  c:send("GET " .. path .. " HTTP/1.1\r\nHost: " .. HOST .. "\r\nAccept: */*\r\n\r\n")
  local buf, header_block, body = "", nil, nil
  while true do
    local chunk, err, partial = c:receive(256)
    local got = chunk or partial
    if got and #got > 0 then buf = buf .. got end
    header_block, body = httpresp.headers_complete(buf)
    if header_block then break end
    if err and err ~= "timeout" then c:close(); return nil end
    if (not got or #got == 0) and err == "timeout" then c:close(); return nil end
  end
  local clen = httpresp.content_length(header_block)
  if clen then
    while #body < clen do
      local chunk, err, partial = c:receive(clen - #body)
      local got = chunk or partial
      if got and #got > 0 then body = body .. got end
      if err and err ~= "timeout" then break end
      if (not got or #got == 0) and err == "timeout" then break end
    end
  end
  c:close()
  return body
end

local body = http_get("/json")
assert(body, "no /json")
local target = cdp.find_shared_js_context(json.decode(body))
assert(target, "no SharedJSContext")
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
c:send(wsframe.encode_text(session:build_command("Runtime.evaluate",
  { expression = "JSON.stringify({sentinel: !!window.__lumenInjected})", returnByValue = true })))

c:settimeout(0.2)
local buf = ""
for _ = 1, 50 do
  local chunk, err, partial = c:receive(4096)
  local got = chunk or partial or ""
  if #got > 0 then buf = buf .. got end
  while true do
    local payload, opcode, rest, complete = wsframe.decode_frame(buf)
    if not complete then break end
    buf = rest
    if opcode == 0x1 then
      local m = cdp.parse_message(payload)
      if m.kind == "result" and m.result and m.result.result then
        print("VERIFY RESULT: " .. tostring(m.result.result.value))
        c:close(); os.exit(0)
      end
    end
  end
  if err and err ~= "timeout" then break end
  socket.sleep(0.1)
end
print("VERIFY: no result received")
c:close()
