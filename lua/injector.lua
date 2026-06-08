-- Impure injector loop. Connects to Steam's CEF endpoint, attaches to
-- SharedJSContext, injects the spike toast, and re-injects on context
-- recreation. Depends on LuaSocket (bundled in the shipped binary).
local socket = require("socket")
local json = require("json")
local wsframe = require("wsframe")
local cdp = require("cdp")
local inject = require("inject")

local injector = {}

local CEF_HOST = "127.0.0.1"
local CEF_PORT = 8080

local function log(msg)
  io.stderr:write(os.date("!%H:%M:%S ") .. "[lumen] " .. msg .. "\n")
  io.stderr:flush()
end

-- Minimal blocking HTTP GET over a fresh TCP socket. Returns body string or nil.
local function http_get(path)
  local c = socket.tcp()
  c:settimeout(5)
  if not c:connect(CEF_HOST, CEF_PORT) then c:close(); return nil end
  c:send("GET " .. path .. " HTTP/1.1\r\nHost: " .. CEF_HOST ..
         "\r\nConnection: close\r\n\r\n")
  local chunks = {}
  while true do
    local data, err, partial = c:receive("*a")
    if data then chunks[#chunks + 1] = data end
    if partial and #partial > 0 then chunks[#chunks + 1] = partial end
    if err == "closed" or data then break end
    if err and err ~= "timeout" then break end
  end
  c:close()
  local raw = table.concat(chunks)
  local body = raw:match("\r\n\r\n(.*)$")
  return body
end

-- Parse ws://host:port/path -> path
local function ws_path(url) return (url:match("^ws://[^/]+(/.*)$")) end

-- Perform the RFC6455 client handshake on an open TCP socket.
local function ws_handshake(c, path)
  -- A fixed key is acceptable for a loopback CEF endpoint that doesn't validate
  -- the Sec-WebSocket-Accept response strictly; CEF accepts the upgrade.
  local key = "dGhlIHNhbXBsZSBub25jZQ=="
  c:send("GET " .. path .. " HTTP/1.1\r\n" ..
         "Host: " .. CEF_HOST .. ":" .. CEF_PORT .. "\r\n" ..
         "Upgrade: websocket\r\nConnection: Upgrade\r\n" ..
         "Sec-WebSocket-Key: " .. key .. "\r\n" ..
         "Sec-WebSocket-Version: 13\r\n\r\n")
  -- Read until end of handshake headers.
  local resp = ""
  c:settimeout(5)
  while not resp:find("\r\n\r\n", 1, true) do
    local chunk, err = c:receive(1)
    if not chunk then return false, err end
    resp = resp .. chunk
  end
  return resp:find("101", 1, true) ~= nil
end

-- Connect to SharedJSContext and return an open, handshaken socket + cdp session.
local function attach()
  local body = http_get("/json")
  if not body then return nil, "no /json (port 8080 closed?)" end
  local ok, targets = pcall(json.decode, body)
  if not ok or type(targets) ~= "table" then return nil, "bad /json" end
  local target = cdp.find_shared_js_context(targets)
  if not target then return nil, "SharedJSContext not present yet" end
  local path = ws_path(target.webSocketDebuggerUrl)
  if not path then return nil, "bad ws url" end
  local c = socket.tcp()
  c:settimeout(5)
  if not c:connect(CEF_HOST, CEF_PORT) then return nil, "ws connect failed" end
  local upgraded = ws_handshake(c, path)
  if not upgraded then c:close(); return nil, "ws upgrade failed" end
  c:settimeout(0.2)  -- non-blocking-ish reads for the event loop
  return c, cdp.new_session()
end

-- Send a CDP command (text frame).
local function send_cmd(c, session, method, params)
  c:send(wsframe.encode_text(session:build_command(method, params)))
end

-- Inject the toast payload. Idempotent thanks to the sentinel inside the JS.
local function do_inject(c, session, msg)
  send_cmd(c, session, "Runtime.evaluate",
    { expression = inject.toast_payload(msg), returnByValue = true })
  log("inject sent")
end

-- Main loop: attach with backoff, enable domains, inject once, then watch for
-- context recreation events and re-inject. Reconnect if the socket drops.
function injector.run(opts)
  opts = opts or {}
  local msg = opts.message or "Lumen attached"
  local backoff = 1
  while true do
    local c, session = attach()
    if not c then
      log("attach: " .. tostring(session) .. " (retry in " .. backoff .. "s)")
      socket.sleep(backoff)
      backoff = math.min(backoff * 2, 15)
    else
      backoff = 1
      log("attached to SharedJSContext")
      send_cmd(c, session, "Runtime.enable")
      send_cmd(c, session, "Page.enable")
      do_inject(c, session, msg)
      -- Read loop: parse frames, re-inject on recreation events.
      local buf = ""
      local alive = true
      while alive do
        local data, err, partial = c:receive("*a")
        local got = data or partial
        if got and #got > 0 then buf = buf .. got end
        if err == "closed" then alive = false; break end
        -- Drain complete frames.
        while true do
          local payload, opcode, rest, complete = wsframe.decode_frame(buf)
          if not complete then break end
          buf = rest
          if opcode == 0x8 then alive = false; break       -- close
          elseif opcode == 0x1 then
            local m = cdp.parse_message(payload)
            if m.kind == "event" and
               (m.method == "Runtime.executionContextCreated" or
                m.method == "Page.frameNavigated" or
                m.method == "Runtime.executionContextsCleared") then
              log("recreation event: " .. m.method .. " -> re-inject")
              -- The sentinel lives on the (new) window, so re-eval is safe.
              do_inject(c, session, msg)
            end
          end
        end
        if alive and (not got or #got == 0) then socket.sleep(0.2) end
      end
      c:close()
      log("socket closed; will re-attach")
    end
    -- If port 8080 has gone for good (Steam closed), attach() will keep
    -- failing; the wrapper/parent decides lifetime. For the spike we loop.
  end
end

return injector
