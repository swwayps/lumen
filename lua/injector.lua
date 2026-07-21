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
local b64 = require("b64")

local injector = {}

local CEF_HOST = "127.0.0.1"
local BINDING = polyfill.BINDING

-- Build the JS that asks the Steam client to verify a game's local files. It is
-- relayed into SharedJSContext (the only context exposing SteamClient) and
-- drives Steam's own steam://validate handler via SteamClient.URL.ExecuteSteamURL.
-- We deliberately avoid navigating window.location to the steam:// URL: the
-- overlay can live in the main shell window, where a location change would tear
-- down the client. `appid` is coerced to an integer so nothing user-controlled
-- is interpolated into the expression.
function injector.validate_app_expr(appid)
  local id = math.floor(tonumber(appid) or 0)
  return "(function(){try{if(window.SteamClient&&SteamClient.URL&&"
    .. "typeof SteamClient.URL.ExecuteSteamURL==='function'){"
    .. "SteamClient.URL.ExecuteSteamURL('steam://validate/" .. id .. "');return true;}"
    .. "return false;}catch(e){return false;}})()"
end

-- Same relay as validate_app_expr but drives steam://uninstall/<appid> (Steam's
-- own uninstall confirm). Used when a build is pinned for an INSTALLED game: a
-- verify can't switch the installed build (the gid delta is zero), so the game
-- has to be uninstalled and reinstalled to come down at the pinned build.
function injector.uninstall_app_expr(appid)
  local id = math.floor(tonumber(appid) or 0)
  return "(function(){try{if(window.SteamClient&&SteamClient.URL&&"
    .. "typeof SteamClient.URL.ExecuteSteamURL==='function'){"
    .. "SteamClient.URL.ExecuteSteamURL('steam://uninstall/" .. id .. "');return true;}"
    .. "return false;}catch(e){return false;}})()"
end

-- Relay steam://nav/games/details/<appid> into SharedJSContext to open a game's
-- library page (the Game Updates card click target). Same shape as
-- validate_app_expr; appid coerced to an int so nothing user-controlled is
-- interpolated.
function injector.open_library_app_expr(appid)
  local id = math.floor(tonumber(appid) or 0)
  return "(function(){try{if(window.SteamClient&&SteamClient.URL&&"
    .. "typeof SteamClient.URL.ExecuteSteamURL==='function'){"
    .. "SteamClient.URL.ExecuteSteamURL('steam://nav/games/details/" .. id .. "');return true;}"
    .. "return false;}catch(e){return false;}})()"
end

-- Open an external URL in the user's default browser via Steam's OWN handler,
-- relayed into SharedJSContext (the only context with SteamClient). This is the
-- key to the browser actually coming to the foreground: a bare xdg-open from the
-- Lumen sidecar (a background process) has no focus-activation token, so under
-- Wayland the OAuth tab opens behind Steam. Steam is the focused GUI app, so
-- routing the open through it raises the browser like any in-client external
-- link. Tries SteamClient.System.OpenInSystemBrowser (raw URL), then falls back
-- to ExecuteSteamURL('steam://openurl_external/…'). `url` is emitted as a JS
-- string literal (json.encode) so quotes/percent/ampersands can't break out.
function injector.open_external_url_expr(url)
  local lit = json.encode(tostring(url or ""))
  return "(function(){try{var u=" .. lit .. ";if(window.SteamClient){"
    .. "if(SteamClient.System&&typeof SteamClient.System.OpenInSystemBrowser==='function'){"
    .. "SteamClient.System.OpenInSystemBrowser(u);return true;}"
    .. "if(SteamClient.URL&&typeof SteamClient.URL.ExecuteSteamURL==='function'){"
    .. "SteamClient.URL.ExecuteSteamURL('steam://openurl_external/'+u);return true;}}"
    .. "return false;}catch(e){return false;}})()"
end

-- Look up `fn_name` in the dispatch registry and run it (Millennium-style: an
-- args object is mapped to alphabetical positional args by rpc.dispatch).
-- Returns the result as a JSON string, or a {success=false} JSON string for an
-- unknown method / a thrown error. Pure except for the registered fn it calls,
-- so the registry-dispatch path is host-testable (test_inject.lua).
function injector.dispatch_method(registry, fn_name, args)
  local fn = registry and registry[fn_name]
  if type(fn) ~= "function" then
    return '{"success":false,"error":"unknown method: ' .. tostring(fn_name) .. '"}'
  end
  local ok_call, res = rpc.dispatch(fn, args or {})
  if ok_call then
    return (type(res) == "string") and res or json.encode(res)
  end
  return '{"success":false,"error":' .. json.encode(tostring(res)) .. '}'
end

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
local function targets_are_ready(targets)
  for _, t in ipairs(targets) do
    local hay = (t.title or "") .. " " .. (t.url or "")
    for _, mark in ipairs(READY_MARKERS) do
      if hay:find(mark, 1, true) then return true end
    end
  end
  return false
end

local function send_cmd(c, session, method, params, child_session)
  local frame = wsframe.encode_text(
    session:build_command(method, params, child_session))
  -- The socket is normally non-blocking. Use a bounded full-frame write so a
  -- large fulfilled HTML document cannot be truncated silently.
  c:settimeout(5)
  local first = 1
  while first <= #frame do
    local sent, err, last = c:send(frame, first)
    local upto = sent or last
    if not upto or upto < first then
      c:settimeout(0)
      return false, err
    end
    first = upto + 1
    if err and err ~= "timeout" then
      c:settimeout(0)
      return false, err
    end
  end
  c:settimeout(0)
  return true
end

function injector.anonymous_web_url(url)
  local host, path = tostring(url or ""):match("^https://([^/%?#]+)([^?#]*)")
  if not host then return false end
  host = host:lower()
  -- Steam's Special Offers popup is a separate authenticated document. Making
  -- it anonymous reloads a briefly-correct news list into the client's
  -- "There are no news items" error page.
  if host == "store.steampowered.com"
      and (path == "/marketingmessages/list"
        or path:find("/marketingmessages/list/", 1, true) == 1) then
    return false
  end
  return host == "store.steampowered.com" or host == "steamcommunity.com"
end

-- Forward presentation headers only. Cookie, authorization, session and
-- compression headers must never cross into the credential-free request.
function injector.anonymous_request_headers(headers)
  local allowed = {
    ["accept"] = true,
    ["accept-language"] = true,
    ["user-agent"] = true,
  }
  local out, have_user_agent = {}, false
  for name, value in pairs(type(headers) == "table" and headers or {}) do
    local lower = tostring(name):lower()
    if allowed[lower] then
      out[#out + 1] = tostring(name) .. ": " .. tostring(value)
      if lower == "user-agent" then have_user_agent = true end
    end
  end
  if not have_user_agent then
    out[#out + 1] = "User-Agent: Valve Steam Client"
  end
  table.sort(out)
  return out
end

function injector.page_fetch_patterns(assets)
  if not assets or assets.anonymous_web ~= true then return {} end
  return {
    {
      urlPattern = "https://store.steampowered.com/*",
      resourceType = "Document",
      requestStage = "Request",
    },
    {
      urlPattern = "https://steamcommunity.com/*",
      resourceType = "Document",
      requestStage = "Request",
    },
  }
end

local function failed_document_url(url)
  url = tostring(url or "")
  return url:find("data:text/html", 1, true) == 1
    or url:find("http://error/", 1, true) == 1
end

function injector.page_recovery_url(url, entries, current_index)
  if injector.anonymous_web_url(url) then return url end
  local history = type(entries) == "table" and entries or {}
  local index = tonumber(current_index)
  if index and index >= 1 and index % 1 == 0 then
    local current = history[index + 1]
    local previous = history[index]
    if current and failed_document_url(current.url)
        and previous and injector.anonymous_web_url(previous.url) then
      return previous.url
    end
  end
  return nil
end

function injector.recovery_allows_event(recovery_only, method)
  return recovery_only ~= true or method == "Fetch.requestPaused"
end

function injector.recovery_fetch_error_needs_retry(recovery_only, recovery_url)
  return recovery_only == true or recovery_url ~= nil
end

function injector.recovery_candidate(target)
  if type(target) ~= "table" or target.type ~= "page"
      or not target.webSocketDebuggerUrl then return false end
  local url, title = tostring(target.url or ""), tostring(target.title or "")
  local failed_url = failed_document_url(url)
  local failed_title = title == "Error"
    or title:find("data:text/html", 1, true) == 1
  return failed_url and failed_title
end

function injector.route_targets_with_recovery(targets, channels)
  local routed = cdp.route_targets(targets, channels)
  local matched, recovery_assets = {}, nil
  for _, route in ipairs(routed) do
    matched[route.target.webSocketDebuggerUrl] = true
  end
  for _, channel in ipairs(channels or {}) do
    if type(channel.assets) == "table"
        and channel.assets.anonymous_web == true then
      recovery_assets = channel.assets
      break
    end
  end
  if recovery_assets then
    for _, target in ipairs(targets or {}) do
      if not matched[target.webSocketDebuggerUrl]
          and injector.recovery_candidate(target) then
        routed[#routed + 1] = {
          target = target, assets = recovery_assets, recovery = true,
        }
      end
    end
  end
  return routed
end

function injector.anonymous_response_plan(response)
  if type(response) ~= "table" or type(response.body) ~= "string" then
    return nil, "invalid response"
  end
  local status = tonumber(response.status)
  if not status or status < 100 or status > 599 then
    return nil, "invalid status"
  end
  status = math.floor(status)
  if status >= 300 and status < 400 then
    if not injector.anonymous_web_url(response.redirect_url) then
      return nil, "unsafe redirect"
    end
    return { action = "redirect", status = status, url = response.redirect_url }
  end
  if status < 200 or status >= 300 then
    return nil, "unexpected HTTP status"
  end
  if response.effective_url
      and not injector.anonymous_web_url(response.effective_url) then
    return nil, "unsafe effective URL"
  end
  local content_type = tostring(response.content_type or "")
  local media_type = content_type:lower():match("^%s*([^;]+)")
  if media_type ~= "text/html" and media_type ~= "application/xhtml+xml" then
    return nil, "non-HTML response"
  end
  return {
    action = "document",
    status = status,
    content_type = content_type,
  }
end

-- ── Per-target connection object ───────────────────────────────────────────
local Conn = {}
Conn.__index = Conn

local function conn_new(target, assets, registry, manager, recovery)
  return setmetatable({
    title = target.title,
    url = target.url or "",
    ws_url = target.webSocketDebuggerUrl,
    assets = assets,
    registry = registry,
    manager = manager,      -- the State, for control relays (view hide/show)
    recovery_only = recovery == true,
    sock = nil,
    session = nil,
    buf = "",
    injected = false,       -- has the first injection happened?
    ready_probe_id = nil,   -- cdp id of the document.readyState probe
    fetch_enable_id = nil,
    fetch_enabled = false,
    anonymous_reloaded = false,
    requests = {},
    history_probe_id = nil,
    recovery_url = nil,
    recovery_failed = false,
  }, Conn)
end

-- Ask the page for its readyState; we inject once it reports "complete".
function Conn:_probe_ready()
  self.ready_probe_id = self.session._id + 1
  send_cmd(self.sock, self.session, "Runtime.evaluate",
    { expression = "document.readyState", returnByValue = true })
end

function Conn:_enable_fetch()
  local patterns = injector.page_fetch_patterns(self.assets)
  if #patterns == 0 then return end
  self.fetch_enable_id = self.session._id + 1
  send_cmd(self.sock, self.session, "Fetch.enable", { patterns = patterns })
end

function Conn:_fail_anonymous(request_id, reason)
  send_cmd(self.sock, self.session, "Fetch.failRequest", {
    requestId = request_id,
    errorReason = reason or "Failed",
  })
end

function Conn:_start_anonymous_request(params)
  local request = params.request or {}
  if request.method ~= "GET" then
    self:_fail_anonymous(params.requestId, "BlockedByClient")
    return
  end
  local ok_http, http = pcall(require, "http")
  if not ok_http or type(http.start) ~= "function"
      or type(http.poll) ~= "function" then
    self:_fail_anonymous(params.requestId, "Failed")
    return
  end
  local ok_start, handle, start_err = pcall(http.start, request.url, {
    headers = injector.anonymous_request_headers(request.headers),
    timeout = 10,
    follow_redirects = false,
    https_only = true,
    max_bytes = 8 * 1024 * 1024,
  })
  if not ok_start or not handle then
    log("public web request failed to start: "
      .. tostring(ok_start and start_err or handle))
    self:_fail_anonymous(params.requestId, "Failed")
    return
  end
  self.requests[params.requestId] = { http = http, handle = handle }
end

function Conn:_fulfill_anonymous(request_id, response, err)
  local plan, plan_err = injector.anonymous_response_plan(response)
  if not plan then
    log("public web request failed: " .. tostring(err or plan_err))
    self:_fail_anonymous(request_id, "Failed")
    return
  end
  if plan.action == "redirect" then
    send_cmd(self.sock, self.session, "Fetch.fulfillRequest", {
      requestId = request_id,
      responseCode = plan.status,
      responseHeaders = {
        { name = "Location", value = plan.url },
        { name = "Cache-Control", value = "no-store" },
      },
      body = "",
    })
    return
  end
  send_cmd(self.sock, self.session, "Fetch.fulfillRequest", {
    requestId = request_id,
    responseCode = plan.status,
    responseHeaders = {
      { name = "Content-Type", value = plan.content_type },
      { name = "Cache-Control", value = "no-store" },
    },
    body = b64.encode(response.body),
  })
end

function Conn:_poll_anonymous()
  for request_id, pending in pairs(self.requests) do
    local ok_poll, done, response, err = pcall(
      pending.http.poll, pending.handle, 0)
    if not ok_poll then
      self.requests[request_id] = nil
      self:_fail_anonymous(request_id, "Failed")
    elseif done then
      self.requests[request_id] = nil
      self:_fulfill_anonymous(request_id, response, err)
    end
  end
end

function Conn:_activate_recovery(url)
  if not url or not self.recovery_only then return end
  self.recovery_only = false
  self.recovery_url = url
  self.url = url
  send_cmd(self.sock, self.session, "Runtime.enable")
  send_cmd(self.sock, self.session, "Runtime.addBinding", { name = BINDING })
  self:_probe_ready()
  if self.fetch_enabled and not self.anonymous_reloaded then
    self.anonymous_reloaded = true
    send_cmd(self.sock, self.session, "Page.navigate", { url = url })
  end
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
  if self.recovery_only then
    send_cmd(c, self.session, "Page.enable")
    self:_enable_fetch()
    self.history_probe_id = self.session._id + 1
    send_cmd(c, self.session, "Page.getNavigationHistory")
    log("attached recovery probe: " .. self.title)
    return true
  end
  send_cmd(c, self.session, "Runtime.enable")
  send_cmd(c, self.session, "Page.enable")
  self:_enable_fetch()
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
  elseif req.fn == "__lumenSlsWarn" then
    -- Show the "slsteam-moon not loaded" warning in the on-top context (store
    -- web view when it's composited above the shell). Triggered from the shell
    -- after the loaded-check; broadcasting picks the visible view.
    if self.manager then self.manager:broadcast_sls_warn() end
    result = '{"ok":true}'
  elseif req.fn == "__lumenSetLaunchOptions" then
    -- Relay: set a game's launch options. SteamClient lives only in
    -- SharedJSContext, not the store web view where the online-fix flow runs.
    local a = req.args or {}
    local appid = tonumber(a.appid)
    local options = a.options
    if appid and type(options) == "string" and self.manager
        and self.manager:set_launch_options(appid, options) then
      result = '{"ok":true}'
    else
      result = '{"ok":false}'
    end
  elseif req.fn == "__lumenValidateApp" then
    -- Relay: ask the Steam client to verify a game's files via its own
    -- steam://validate handler. SteamClient lives only in SharedJSContext, not
    -- the shell/web-view contexts the menu overlay runs in.
    local a = req.args or {}
    local appid = tonumber(a.appid)
    if appid and self.manager and self.manager:validate_app(appid) then
      result = '{"ok":true}'
    else
      result = '{"ok":false}'
    end
  elseif req.fn == "__lumenUninstallApp" then
    -- Relay: open Steam's own steam://uninstall/<appid> flow (its confirm
    -- dialog). For an installed pinned game, a verify won't switch the build,
    -- so the user uninstalls here, then reinstalls fresh at the pinned build.
    local a = req.args or {}
    local appid = tonumber(a.appid)
    if appid and self.manager and self.manager:uninstall_app(appid) then
      result = '{"ok":true}'
    else
      result = '{"ok":false}'
    end
  elseif req.fn == "__lumenOpenLibraryApp" then
    -- Open a game's library page (Game Updates card click). SteamClient lives
    -- only in SharedJSContext. Fire-and-forget.
    local a = req.args or {}
    local appid = tonumber(a.appid)
    if appid and self.manager and self.manager:open_library_app(appid) then
      result = '{"ok":true}'
    else
      result = '{"ok":false}'
    end
  elseif req.fn == "__lumenOpenExternalUrl" then
    -- Open an external URL (the Cloud Saves OAuth page) in the default browser
    -- via Steam's own handler so it comes to the foreground. SteamClient lives
    -- only in SharedJSContext. ok:false when no such conn exists -> the caller
    -- falls back to a backend xdg-open.
    local a = req.args or {}
    if a.url and self.manager and self.manager:open_external_url(tostring(a.url)) then
      result = '{"ok":true}'
    else
      result = '{"ok":false}'
    end
  else
    result = injector.dispatch_method(self.registry, req.fn, req.args)
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
      if (m.kind == "result" or m.kind == "error")
          and self.history_probe_id and m.id == self.history_probe_id then
        self.history_probe_id = nil
        if m.kind == "error" then
          self.recovery_failed = true
        else
          self:_activate_recovery(injector.page_recovery_url(self.url,
            m.result and m.result.entries,
            m.result and m.result.currentIndex))
        end
      elseif (m.kind == "result" or m.kind == "error")
          and self.fetch_enable_id and m.id == self.fetch_enable_id then
        self.fetch_enable_id = nil
        self.fetch_enabled = m.kind == "result"
        if m.kind == "error" and injector.recovery_fetch_error_needs_retry(
            self.recovery_only, self.recovery_url) then
          self.recovery_failed = true
        end
        local recovery_url = self.recovery_url
          or injector.page_recovery_url(self.url)
        if self.fetch_enabled and not self.anonymous_reloaded
            and recovery_url then
          self.anonymous_reloaded = true
          send_cmd(c, self.session, "Page.navigate", { url = recovery_url })
        end
      elseif m.kind == "result" and self.ready_probe_id and m.id == self.ready_probe_id then
        -- Reply to our document.readyState probe.
        self.ready_probe_id = nil
        local val = m.result and m.result.result and m.result.result.value
        if val == "complete" then
          self:_inject_once()
        end
        -- If "loading"/"interactive", wait for Page.loadEventFired below.
      elseif m.kind == "event" then
        if not injector.recovery_allows_event(self.recovery_only, m.method) then
          -- A failed document remains inert until its immediate history entry
          -- proves it came from Store/Community.
        elseif m.method == "Fetch.requestPaused" then
          local params = m.params or {}
          local url = params.request and params.request.url or ""
          if self.assets and self.assets.anonymous_web == true
              and injector.anonymous_web_url(url) then
            self:_start_anonymous_request(params)
          else
            send_cmd(c, self.session, "Fetch.continueRequest", {
              requestId = params.requestId,
            })
          end
        elseif m.method == "Runtime.bindingCalled" and m.params and m.params.name == BINDING then
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
  if self.recovery_failed then return false end
  self:_poll_anonymous()
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
    shared_ws_url = nil,
  }, State)
end

-- Steam restarts replace the entire webhelper generation while Lumen remains
-- alive inside its grace window. Reset readiness before touching any target in
-- the new generation so cold-boot CDP domains are never enabled prematurely.
function State:observe_shared_generation(targets)
  local current
  for _, target in ipairs(targets or {}) do
    if target.title == "SharedJSContext" and target.webSocketDebuggerUrl then
      current = target.webSocketDebuggerUrl
      break
    end
  end
  if not current then return false end
  if not self.shared_ws_url then
    self.shared_ws_url = current
    return false
  end
  if self.shared_ws_url == current then return false end
  for _, conn in pairs(self.conns) do
    if conn.close then conn:close() end
  end
  self.conns = {}
  self.shared_ws_url = current
  self.ui_ready = false
  self.backoff = 1
  self.next_attempt = 0
  return true
end

-- fds() -> array of currently-open CDP sockets for select().
function State:fds()
  local out = {}
  for _, conn in pairs(self.conns) do
    if conn.sock then out[#out + 1] = conn.sock end
  end
  return out
end

-- libcurl's multi interface needs frequent cooperative polling while a public
-- document is in flight. Keep the ordinary one-second idle cadence everywhere
-- else; this becomes true only for the short lifetime of an intercepted load.
function State:needs_fast_tick()
  for _, conn in pairs(self.conns) do
    if conn.requests and next(conn.requests) ~= nil then return true end
  end
  return false
end

-- Discover wanted targets and connect to any not yet connected (backoff-gated).
function State:_discover()
  local now = os.time()
  if now < self.next_attempt then return end
  local targets, err = list_all_targets()
  if not targets then
    self.next_attempt = now + self.backoff
    self.backoff = math.min(self.backoff * 2, 15)
    return
  end
  self.backoff = 1
  self.next_attempt = 0
  if self:observe_shared_generation(targets) then
    log("new SharedJSContext generation -> waiting for Steam UI readiness")
  end
  -- Hold off ALL attaching until Steam's main UI is up. Attaching to
  -- SharedJSContext during the login/init phase stalls the client boot
  -- (Phase 4 finding). Latch once ready so later navigations aren't gated.
  if not self.ui_ready then
    if targets_are_ready(targets) then
      self.ui_ready = true
      log("Steam UI ready -> attaching")
    else
      self.next_attempt = now + 2   -- poll readiness every 2s, no backoff
      return
    end
  end
  -- Route each target to its channel's assets (store web views -> luatools.js;
  -- SharedJSContext -> lumen-menu bundle). First matching channel wins.
  local routed = injector.route_targets_with_recovery(targets, self.channels)
  for _, r in ipairs(routed) do
    local t = r.target
    if not self.conns[t.webSocketDebuggerUrl] then
      local conn = conn_new(t, r.assets, self.registry, self, r.recovery)
      if conn:connect() then self.conns[t.webSocketDebuggerUrl] = conn end
    end
  end
end

-- Open/close the Lumen overlay in every connected context that has it. The menu
-- exposes window.__lumenOpenOverlay/__lumenCloseOverlay; contexts without it
-- (none currently) no-op via the && guard. Broadcasting avoids having to detect
-- which view is active — only the visible view's overlay is seen.
-- Relay a SteamClient.Apps.SetAppLaunchOptions call into SharedJSContext (the
-- only context with SteamClient). Fire-and-forget: returns true if we have a
-- SharedJSContext control conn to run it on. `options` is JSON-encoded into a JS
-- string literal so quotes/percent signs survive.
function State:set_launch_options(appid, options)
  -- Set the (already-merged) launch options. The merge with the user's existing
  -- options is done in the plugin backend (it reads the reliable source,
  -- localconfig.vdf, and uses fix_overlays.merge_launch_options); here we just
  -- write. SteamClient lives only in SharedJSContext. Fire-and-forget.
  local expr = "(function(){try{if(window.SteamClient&&SteamClient.Apps&&"
    .. "typeof SteamClient.Apps.SetAppLaunchOptions==='function'){"
    .. "SteamClient.Apps.SetAppLaunchOptions(" .. tostring(tonumber(appid) or 0)
    .. "," .. json.encode(options) .. ");return true;}return false;}catch(e){return false;}})()"
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      return true
    end
  end
  return false
end

-- Relay a steam://validate/<appid> into SharedJSContext (the only context with
-- SteamClient) to verify a game's local files. Fire-and-forget: returns true if
-- we have a SharedJSContext control conn to run it on.
function State:validate_app(appid)
  local expr = injector.validate_app_expr(appid)
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      return true
    end
  end
  return false
end

-- Relay a steam://uninstall/<appid> into SharedJSContext to open Steam's own
-- uninstall flow. Fire-and-forget: returns true if we have a SharedJSContext
-- control conn to run it on.
function State:uninstall_app(appid)
  local expr = injector.uninstall_app_expr(appid)
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      return true
    end
  end
  return false
end
-- Relay steam://nav/games/details/<appid> into SharedJSContext to open a game's
-- library page. Fire-and-forget: returns true if a SharedJSContext conn exists.
function State:open_library_app(appid)
  local expr = injector.open_library_app_expr(appid)
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      return true
    end
  end
  return false
end
-- Relay an external-URL open into SharedJSContext so Steam raises the browser
-- (see open_external_url_expr). Fire-and-forget: true if a SharedJSContext conn
-- exists to run it on.
function State:open_external_url(url)
  local expr = injector.open_external_url_expr(url)
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      return true
    end
  end
  return false
end
--   * a store/community web view is the CURRENT page -> render in that web view
--     ONLY (it composites above the shell, so the shell's own overlay would be
--     hidden behind it / misaligned -> the "split" bug);
--   * otherwise (library/home and other shell pages) the content lives in the
--     shell window itself -> render there.
-- "Current" is decided from a fresh /json target list, NOT from self.conns: a
-- web view conn can linger briefly after you navigate away (its socket isn't
-- detected closed yet), and targeting that stale conn would render into a dead
-- view. Close always goes to every context so nothing is left open behind.
-- Evaluate `expr` in whichever context is currently ON TOP: the active store/
-- community web view if one is the current page (it composites above the shell,
-- so a shell-only render would sit hidden behind it), else the shell window.
-- "Current" is decided from a fresh /json target list, NOT from self.conns (a
-- web-view conn can linger briefly after navigating away). Shared by the
-- overlay open and the slsteam-moon warning so both surface where the user can
-- see them.
function State:_fire_on_top(expr)
  local function fire(conn)
    if conn and conn.sock then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
    end
  end

  local live_webview_ws = {}
  local targets = list_all_targets()
  if targets then
    for _, t in ipairs(targets) do
      local u = t.url or ""
      if u:find("store.steampowered.com", 1, true) or u:find("steamcommunity.com", 1, true) then
        live_webview_ws[t.webSocketDebuggerUrl] = true
      end
    end
  end

  local fired = false
  for _, conn in pairs(self.conns) do
    if conn.sock and live_webview_ws[conn.ws_url] then fire(conn); fired = true end
  end
  if not fired then
    -- No active web view: the content is in the shell window itself.
    for _, conn in pairs(self.conns) do
      if conn.sock and conn.title == "Steam" then fire(conn) end
    end
  end
end

function State:broadcast_overlay(open)
  if not open then
    -- Close goes to EVERY context so nothing is left open behind a hidden view.
    local expr = "window.__lumenCloseOverlay&&window.__lumenCloseOverlay()"
    for _, conn in pairs(self.conns) do
      if conn and conn.sock then
        send_cmd(conn.sock, conn.session, "Runtime.evaluate",
          { expression = expr, returnByValue = true })
      end
    end
    return
  end
  self:_fire_on_top("window.__lumenOpenOverlay&&window.__lumenOpenOverlay()")
end

-- Show the "slsteam-moon not loaded" warning in whichever view is on top, so it
-- renders in front of the store/community web view when one is composited above
-- the shell (otherwise it would be hidden behind it — the store-in-front bug).
function State:broadcast_sls_warn()
  self:_fire_on_top("window.__lumenShowSlsWarn&&window.__lumenShowSlsWarn()")
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
