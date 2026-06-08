-- One-shot: inject polyfill + public/luatools.js + steamdb-webkit.css into a
-- named CEF target (default the store web view). Spike/test helper.
--   LUMEN_BACKEND_DIR=... LUMEN_INJECT_TARGET="Welcome to Steam" ./lumen --inject-store
local socket = require("socket")
local json = require("json")
local wsframe = require("wsframe")
local cdp = require("cdp")
local httpresp = require("httpresp")
local polyfill = require("polyfill")
local utils = require("utils")

local HOST, PORT = "127.0.0.1", 8080
local WANT = os.getenv("LUMEN_INJECT_TARGET") or "Welcome to Steam"

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
local target
for _, t in ipairs(json.decode(body)) do
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

-- Read session (port+token) for the polyfill.
local home = os.getenv("HOME") or "."
local sess = json.decode(utils.read_file(home .. "/.local/share/Lumen/session.json"))
local backend = os.getenv("LUMEN_BACKEND_DIR")
local plugin_dir = backend:gsub("/backend$", "")
local css = utils.read_file(plugin_dir .. "/public/steamdb-webkit.css")
local js  = utils.read_file(plugin_dir .. "/public/luatools.js")

local session = cdp.new_session()
local function eval(expr)
  c:send(wsframe.encode_text(session:build_command("Runtime.evaluate",
    { expression = expr, returnByValue = true })))
  socket.sleep(0.15)
end

eval(polyfill.build(sess.port, sess.token))
if css then
  eval("(function(){if(document.getElementById('lumen-css'))return;var s=document.createElement('style');s.id='lumen-css';s.textContent=" ..
       json.encode(css) .. ";(document.head||document.documentElement).appendChild(s);})()")
end
if js then eval(js) end
print("injected into [" .. WANT .. "]: polyfill + css=" .. tostring(css ~= nil) ..
      " + js=" .. tostring(js ~= nil))
socket.sleep(0.3)
c:close()
