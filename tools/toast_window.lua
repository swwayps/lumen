-- One-shot visible toast into a chosen CEF window (default "Steam").
--   LUMEN_LUA_DIR=lua LUMEN_TOAST_TITLE="Steam" LUMEN_TOAST_MSG="..." ./lumen --toast
local socket = require("socket")
local json = require("json")
local wsframe = require("wsframe")
local cdp = require("cdp")
local inject = require("inject")
local httpresp = require("httpresp")

local HOST, PORT = "127.0.0.1", 8080
local WANT = os.getenv("LUMEN_TOAST_TITLE") or "Steam"
local MSG = os.getenv("LUMEN_TOAST_MSG") or "Lumen spike OK"

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
-- Build a self-contained payload: reset sentinel, inject a 15s toast, and
-- report back whether the toast div is actually in the DOM (proof of render).
local m = inject.js_string(MSG)
local expr = ([[
(function () {
  window.__lumenInjected = false;
  var prev = document.getElementById("lumen-spike-toast");
  if (prev) prev.remove();
  var el = document.createElement("div");
  el.id = "lumen-spike-toast";
  el.textContent = "%s";
  el.style.cssText =
    "position:fixed;top:16px;right:16px;z-index:999999;" +
    "background:#1b2838;color:#66c0f4;padding:10px 14px;" +
    "border:1px solid #66c0f4;border-radius:6px;font:14px sans-serif;" +
    "box-shadow:0 2px 8px rgba(0,0,0,.5);";
  document.body.appendChild(el);
  setTimeout(function () { el.remove(); }, 15000);
  return JSON.stringify({ inDom: !!document.getElementById("lumen-spike-toast"),
                          bodyW: document.body.clientWidth });
})()]]):format(m)

local toast_id_cmd = session:build_command("Runtime.evaluate",
  { expression = expr, returnByValue = true })
local toast_id = session._id  -- id of the toast command we just built
c:send(wsframe.encode_text(toast_id_cmd))

c:settimeout(0.2)
local buf = ""
for _ = 1, 50 do
  local chunk, err, partial = c:receive(4096)
  local got = chunk or partial or ""
  if #got > 0 then buf = buf .. got end
  while true do
    local p, opcode, rest, complete = wsframe.decode_frame(buf)
    if not complete then break end
    buf = rest
    if opcode == 0x1 then
      local msg = cdp.parse_message(p)
      if msg.kind == "result" and msg.id == toast_id and msg.result and msg.result.result then
        print("TOAST RESULT: " .. tostring(msg.result.result.value))
        c:close(); os.exit(0)
      end
    end
  end
  if err and err ~= "timeout" then break end
  socket.sleep(0.1)
end
print("TOAST: no result")
c:close()
