-- Multi-target CDP injector. For each wanted CEF target (the store web view
-- where LuaTools lives, plus SharedJSContext for logic), it: handshakes the CDP
-- websocket, enables Runtime/Page, adds the __lumenSend binding, and injects the
-- polyfill + frontend assets. It dispatches Runtime.bindingCalled events against
-- the backend registry IN-PROCESS and resolves the page promise via
-- Runtime.evaluate. Re-injects idempotently on context recreation; re-attaches
-- on socket close. Cooperative (fds()/tick()) so it shares the loop with others.
local socket = require("socket")
local json = require("json")
local wsframe = require("wsframe")
local cdp = require("cdp")
local inject = require("inject")
local httpresp = require("httpresp")
local polyfill = require("polyfill")

local injector = {}

local CEF_HOST = "127.0.0.1"
local CEF_PORT = 8080
local BINDING = polyfill.BINDING

local function log(msg)
  io.stderr:write(os.date("!%H:%M:%S ") .. "[lumen] " .. msg .. "\n")
  io.stderr:flush()
end

io.stderr:setvbuf("no")
io.stdout:setvbuf("no")

-- ── HTTP GET against the CEF endpoint (keep-alive aware) ───────────────────
local function http_get(path)
  local c = socket.tcp()
  c:settimeout(5)
  if not c:connect(CEF_HOST, CEF_PORT) then c:close(); return nil end
  c:send("GET " .. path .. " HTTP/1.1\r\nHost: " .. CEF_HOST .. "\r\nAccept: */*\r\n\r\n")
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

local function ws_path(url) return (url:match("^ws://[^/]+(/.*)$")) end

local function ws_handshake(c, path)
  c:send("GET " .. path .. " HTTP/1.1\r\n" ..
         "Host: " .. CEF_HOST .. ":" .. CEF_PORT .. "\r\n" ..
         "Upgrade: websocket\r\nConnection: Upgrade\r\n" ..
         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ..
         "Sec-WebSocket-Version: 13\r\n\r\n")
  local resp = ""
  c:settimeout(5)
  while not resp:find("\r\n\r\n", 1, true) do
    local chunk, err = c:receive(1)
    if not chunk then return false, err end
    resp = resp .. chunk
  end
  return resp:find("101", 1, true) ~= nil
end

-- List targets, returning all that match `wanted` (set of titles) OR whose URL
-- contains one of `wanted_url` substrings (store pages change title per page, so
-- match the store by URL). Returns the target list.
local function list_wanted_targets(wanted, wanted_url)
  local body = http_get("/json")
  if not body then return nil, "no /json (port 8080 closed?)" end
  local ok, targets = pcall(json.decode, body)
  if not ok or type(targets) ~= "table" then return nil, "bad /json" end
  local out = {}
  for _, t in ipairs(targets) do
    if t.webSocketDebuggerUrl then
      local match = t.title and wanted[t.title]
      if not match and t.url and wanted_url then
        for _, frag in ipairs(wanted_url) do
          if t.url:find(frag, 1, true) then match = true; break end
        end
      end
      if match then out[#out + 1] = t end
    end
  end
  return out
end

local function send_cmd(c, session, method, params)
  c:send(wsframe.encode_text(session:build_command(method, params)))
end

-- ── Per-target connection object ───────────────────────────────────────────
local Conn = {}
Conn.__index = Conn

local function conn_new(target, assets, registry)
  return setmetatable({
    title = target.title,
    ws_url = target.webSocketDebuggerUrl,
    assets = assets,
    registry = registry,
    sock = nil,
    session = nil,
    buf = "",
  }, Conn)
end

function Conn:connect()
  local path = ws_path(self.ws_url)
  if not path then return false end
  local c = socket.tcp(); c:settimeout(5)
  if not c:connect(CEF_HOST, CEF_PORT) then return false end
  if not ws_handshake(c, path) then c:close(); return false end
  c:settimeout(0)
  self.sock = c
  self.session = cdp.new_session()
  self.buf = ""
  send_cmd(c, self.session, "Runtime.enable")
  send_cmd(c, self.session, "Page.enable")
  send_cmd(c, self.session, "Runtime.addBinding", { name = BINDING })
  self:inject()
  log("attached + bound: " .. self.title)
  return true
end

function Conn:inject()
  local c, s, a = self.sock, self.session, self.assets
  if a and a.polyfill then
    send_cmd(c, s, "Runtime.evaluate", { expression = a.polyfill, returnByValue = true })
  end
  if a then
    for i, css in ipairs(a.css or {}) do
      local id = "lumen-css-" .. i
      local w = "(function(){if(document.getElementById(" .. json.encode(id) ..
        "))return;var s=document.createElement('style');s.id=" .. json.encode(id) ..
        ";s.textContent=" .. json.encode(css) ..
        ";(document.head||document.documentElement).appendChild(s);})()"
      send_cmd(c, s, "Runtime.evaluate", { expression = w, returnByValue = true })
    end
    for _, js in ipairs(a.js or {}) do
      send_cmd(c, s, "Runtime.evaluate", { expression = js, returnByValue = true })
    end
  else
    send_cmd(c, s, "Runtime.evaluate",
      { expression = inject.toast_payload("Lumen attached"), returnByValue = true })
  end
end

-- Handle a Runtime.bindingCalled: run the backend fn and resolve the page promise.
function Conn:_on_binding(payload_str)
  local ok, req = pcall(json.decode, payload_str)
  if not ok or type(req) ~= "table" then return end
  local id = req.id
  local result
  local fn = self.registry and self.registry[req.fn]
  if type(fn) == "function" then
    local ok_call, res = pcall(fn, req.args or {})
    if ok_call then
      result = (type(res) == "string") and res or json.encode(res)
    else
      result = '{"success":false,"error":' .. json.encode(tostring(res)) .. '}'
    end
  else
    result = '{"success":false,"error":"unknown method: ' .. tostring(req.fn) .. '"}'
  end
  -- Resolve the page-side promise. id + result passed as JS string literals.
  local expr = polyfill.resolve_js(json.encode(tostring(id)), json.encode(result))
  send_cmd(self.sock, self.session, "Runtime.evaluate", { expression = expr })
end

-- Drain available frames; handle bindingCalled + re-inject on recreation.
-- Returns false if the socket closed (caller drops the conn).
function Conn:drain()
  local c = self.sock
  local data, err, partial = c:receive("*a")
  local got = data or partial
  if got and #got > 0 then self.buf = self.buf .. got end
  if err == "closed" then return false end
  while true do
    local frame, opcode, rest, complete = wsframe.decode_frame(self.buf)
    if not complete then break end
    self.buf = rest
    if opcode == 0x8 then return false
    elseif opcode == 0x1 then
      local m = cdp.parse_message(frame)
      if m.kind == "event" then
        if m.method == "Runtime.bindingCalled" and m.params and m.params.name == BINDING then
          self:_on_binding(m.params.payload)
        elseif m.method == "Runtime.executionContextCreated" or
               m.method == "Page.frameNavigated" or
               m.method == "Runtime.executionContextsCleared" then
          log("recreation (" .. self.title .. "): " .. m.method .. " -> re-bind+inject")
          send_cmd(c, self.session, "Runtime.addBinding", { name = BINDING })
          self:inject()
        end
      end
    end
  end
  return true
end

function Conn:close()
  if self.sock then pcall(function() self.sock:close() end) end
  self.sock = nil
end

-- ── Multi-target manager (cooperative new/fds/tick) ────────────────────────
local State = {}
State.__index = State

-- new{ targets={set of titles}, assets=, registry=, message= }
function injector.new(opts)
  opts = opts or {}
  local wanted = {}
  if opts.targets then
    for _, t in ipairs(opts.targets) do wanted[t] = true end
  else
    wanted["SharedJSContext"] = true
  end
  return setmetatable({
    wanted = wanted,
    wanted_url = opts.target_urls,
    assets = opts.assets,
    registry = opts.registry,
    conns = {},          -- ws_url -> Conn
    backoff = 1,
    next_attempt = 0,
  }, State)
end

-- fds() -> array of currently-open CDP sockets for select().
function State:fds()
  local out = {}
  for _, conn in pairs(self.conns) do
    if conn.sock then out[#out + 1] = conn.sock end
  end
  return out
end

-- Discover wanted targets and connect to any not yet connected (backoff-gated).
function State:_discover()
  local now = os.time()
  if now < self.next_attempt then return end
  local targets, err = list_wanted_targets(self.wanted, self.wanted_url)
  if not targets then
    self.next_attempt = now + self.backoff
    self.backoff = math.min(self.backoff * 2, 15)
    return
  end
  self.backoff = 1
  self.next_attempt = 0
  local seen = {}
  for _, t in ipairs(targets) do
    seen[t.webSocketDebuggerUrl] = true
    if not self.conns[t.webSocketDebuggerUrl] then
      local conn = conn_new(t, self.assets, self.registry)
      if conn:connect() then self.conns[t.webSocketDebuggerUrl] = conn end
    end
  end
end

-- tick(): connect to new targets, drain existing ones, drop closed ones.
function State:tick()
  self:_discover()
  for url, conn in pairs(self.conns) do
    if conn.sock then
      local alive = conn:drain()
      if not alive then
        log("closed: " .. conn.title .. " (will re-attach)")
        conn:close()
        self.conns[url] = nil
      end
    end
  end
end

return injector
