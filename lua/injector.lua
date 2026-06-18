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
local httpresp = require("httpresp")
local polyfill = require("polyfill")
local rpc = require("rpc")
local cefport = require("cefport")

local injector = {}

local CEF_HOST = "127.0.0.1"
local BINDING = polyfill.BINDING

local function log(msg)
  io.stderr:write(os.date("!%H:%M:%S ") .. "[lumen] " .. msg .. "\n")
  io.stderr:flush()
end

io.stderr:setvbuf("no")
io.stdout:setvbuf("no")

-- Which TCP port Steam's CEF endpoint is on. slsteam-moon rewrites Steam's
-- hard-coded 8080 to a free loopback port and publishes it to the contract
-- file; we read it from there, falling back to 8080 (vanilla Steam, or
-- slsteam-moon not active). Re-read each call (the file is tiny) so a port
-- rotation on a webhelper restart is picked up; we only log on change.
local g_logged_port = nil
local function cef_port()
  local p, from_file = cefport.resolve(cefport.read_contract, cefport.FALLBACK)
  if from_file and p ~= g_logged_port then
    log("CEF port (from contract file): " .. p)
    g_logged_port = p
  end
  return p
end

-- ── HTTP GET against the CEF endpoint (keep-alive aware) ───────────────────
local function http_get(path)
  local c = socket.tcp()
  c:settimeout(5)
  if not c:connect(CEF_HOST, cef_port()) then c:close(); return nil end
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
         "Host: " .. CEF_HOST .. ":" .. cef_port() .. "\r\n" ..
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

-- List ALL current CEF targets (decoded /json), or nil + reason.
local function list_all_targets()
  local body = http_get("/json")
  if not body then return nil, "no /json (CEF port " .. cef_port() .. " closed?)" end
  local ok, targets = pcall(json.decode, body)
  if not ok or type(targets) ~= "table" then return nil, "bad /json" end
  return targets
end

-- Is Steam's main UI up (past login + first paint)? SharedJSContext exists even
-- at the "Sign in" screen, so attaching to ANY target before the main shell is
-- up interferes with the client coming up (stalls boot / blanks render). We
-- treat the UI as ready once the shell menu targets exist — the Supernav /
-- Root Menu / library / store windows only appear after login + first paint.
local READY_MARKERS = {
  "Supernav", "Root Menu", "store.steampowered.com",
}
local function ui_is_ready()
  local body = http_get("/json")
  if not body then return false end
  local ok, targets = pcall(json.decode, body)
  if not ok or type(targets) ~= "table" then return false end
  for _, t in ipairs(targets) do
    local hay = (t.title or "") .. " " .. (t.url or "")
    for _, mark in ipairs(READY_MARKERS) do
      if hay:find(mark, 1, true) then return true end
    end
  end
  return false
end

local function send_cmd(c, session, method, params)
  c:send(wsframe.encode_text(session:build_command(method, params)))
end

-- ── Per-target connection object ───────────────────────────────────────────
local Conn = {}
Conn.__index = Conn

local function conn_new(target, assets, registry, manager)
  return setmetatable({
    title = target.title,
    ws_url = target.webSocketDebuggerUrl,
    assets = assets,
    registry = registry,
    manager = manager,      -- the State, for control relays (view hide/show)
    sock = nil,
    session = nil,
    buf = "",
    injected = false,       -- has the first injection happened?
    ready_probe_id = nil,   -- cdp id of the document.readyState probe
  }, Conn)
end

-- Ask the page for its readyState; we inject once it reports "complete".
function Conn:_probe_ready()
  self.ready_probe_id = self.session._id + 1
  send_cmd(self.sock, self.session, "Runtime.evaluate",
    { expression = "document.readyState", returnByValue = true })
end

function Conn:connect()
  local path = ws_path(self.ws_url)
  if not path then return false end
  local c = socket.tcp(); c:settimeout(5)
  if not c:connect(CEF_HOST, cef_port()) then return false end
  if not ws_handshake(c, path) then c:close(); return false end
  c:settimeout(0)
  self.sock = c
  self.session = cdp.new_session()
  self.buf = ""
  self.injected = false
  send_cmd(c, self.session, "Runtime.enable")
  send_cmd(c, self.session, "Page.enable")
  send_cmd(c, self.session, "Runtime.addBinding", { name = BINDING })
  -- Do NOT inject yet: injecting while the UI is still initializing blanks the
  -- Steam render (Phase 4 finding). Gate the first injection on readiness —
  -- probe document.readyState now (covers the already-loaded case) and also
  -- inject on Page.loadEventFired (covers the still-loading case).
  self:_probe_ready()
  log("attached + bound: " .. self.title)
  return true
end

-- Inject once, guarded so readyState + loadEventFired don't double-inject.
function Conn:_inject_once()
  if self.injected then return end
  self.injected = true
  self:inject()
end

function Conn:inject()
  local c, s, a = self.sock, self.session, self.assets
  if not a then return end
  if a.polyfill then
    send_cmd(c, s, "Runtime.evaluate", { expression = a.polyfill, returnByValue = true })
  end
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
end

-- Handle a Runtime.bindingCalled: run the backend fn and resolve the page promise.
function Conn:_on_binding(payload_str)
  local ok, req = pcall(json.decode, payload_str)
  if not ok or type(req) ~= "table" then return end
  local id = req.id
  local result
  -- Control commands: open/close the Lumen overlay in EVERY injected context
  -- (main window + store/community web views). Only the currently-visible view's
  -- overlay is seen; the others are harmless no-ops behind hidden views. This
  -- renders the overlay natively in whichever view is on top, so input works and
  -- it survives minimize/restore — unlike hiding the embedded browser view.
  if req.fn == "__lumenOpen" or req.fn == "__lumenClose" then
    if self.manager then self.manager:broadcast_overlay(req.fn == "__lumenOpen") end
    result = '{"ok":true}'
  else
    local fn = self.registry and self.registry[req.fn]
    if type(fn) == "function" then
      -- Millennium-style dispatch: args object -> alphabetical positional args.
      local ok_call, res = rpc.dispatch(fn, req.args or {})
      if ok_call then
        result = (type(res) == "string") and res or json.encode(res)
      else
        result = '{"success":false,"error":' .. json.encode(tostring(res)) .. '}'
      end
    else
      result = '{"success":false,"error":"unknown method: ' .. tostring(req.fn) .. '"}'
    end
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
      if m.kind == "result" and self.ready_probe_id and m.id == self.ready_probe_id then
        -- Reply to our document.readyState probe.
        self.ready_probe_id = nil
        local val = m.result and m.result.result and m.result.result.value
        if val == "complete" then
          self:_inject_once()
        end
        -- If "loading"/"interactive", wait for Page.loadEventFired below.
      elseif m.kind == "event" then
        if m.method == "Runtime.bindingCalled" and m.params and m.params.name == BINDING then
          self:_on_binding(m.params.payload)
        elseif m.method == "Page.loadEventFired" or m.method == "Page.domContentEventFired" then
          -- Page finished loading: safe to inject now.
          self:_inject_once()
        elseif m.method == "Runtime.executionContextCreated" or
               m.method == "Page.frameNavigated" or
               m.method == "Runtime.executionContextsCleared" then
          -- Context recreated (navigation / webhelper restart). Re-bind and
          -- re-inject, but gate again on readiness so we never inject into a
          -- still-initializing context (the boot black-screen cause).
          log("recreation (" .. self.title .. "): " .. m.method .. " -> re-bind + re-inject (gated)")
          send_cmd(c, self.session, "Runtime.addBinding", { name = BINDING })
          self.injected = false
          self:_probe_ready()
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

-- new{ channels={ {titles=, urls=, assets=}, ... }, registry=, ... }
-- Back-compat: a single { targets=, target_urls=, assets= } is accepted and
-- folded into one channel.
function injector.new(opts)
  opts = opts or {}
  local channels = opts.channels
  if not channels then
    local titles = {}
    if opts.targets then
      for _, t in ipairs(opts.targets) do titles[t] = true end
    else
      titles["SharedJSContext"] = true
    end
    channels = { { titles = titles, urls = opts.target_urls, assets = opts.assets } }
  end
  return setmetatable({
    channels = channels,
    registry = opts.registry,
    conns = {},          -- ws_url -> Conn
    backoff = 1,
    next_attempt = 0,
    ui_ready = false,    -- latched once Steam's main UI is up (post-login/paint)
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
  -- Hold off ALL attaching until Steam's main UI is up. Attaching to
  -- SharedJSContext during the login/init phase stalls the client boot
  -- (Phase 4 finding). Latch once ready so later navigations aren't gated.
  if not self.ui_ready then
    if ui_is_ready() then
      self.ui_ready = true
      log("Steam UI ready -> attaching")
    else
      self.next_attempt = now + 2   -- poll readiness every 2s, no backoff
      return
    end
  end
  local targets, err = list_all_targets()
  if not targets then
    self.next_attempt = now + self.backoff
    self.backoff = math.min(self.backoff * 2, 15)
    return
  end
  self.backoff = 1
  self.next_attempt = 0
  -- Route each target to its channel's assets (store web views -> luatools.js;
  -- SharedJSContext -> lumen-menu bundle). First matching channel wins.
  local routed = cdp.route_targets(targets, self.channels)
  for _, r in ipairs(routed) do
    local t = r.target
    if not self.conns[t.webSocketDebuggerUrl] then
      local conn = conn_new(t, r.assets, self.registry, self)
      if conn:connect() then self.conns[t.webSocketDebuggerUrl] = conn end
    end
  end
end

-- Open/close the Lumen overlay in every connected context that has it. The menu
-- exposes window.__lumenOpenOverlay/__lumenCloseOverlay; contexts without it
-- (none currently) no-op via the && guard. Broadcasting avoids having to detect
-- which view is active — only the visible view's overlay is seen.
function State:broadcast_overlay(open)
  local fn = open and "__lumenOpenOverlay" or "__lumenCloseOverlay"
  local expr = "window." .. fn .. "&&window." .. fn .. "()"
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.assets then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
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
