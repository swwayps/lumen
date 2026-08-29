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
local cdpreq = require("cdpreq")
local nonce = require("nonce")
local peerauth = require("peerauth")
local steamoauth = require("steamoauth")
local luatoolslogin = require("luatoolslogin")

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
local g_logged_stale = false
local function cef_port()
  local p, from_file, reason = cefport.resolve(cefport.read_contract, cefport.FALLBACK)
  if from_file then
    g_logged_stale = false
    if p ~= g_logged_port then
      log("CEF port (from contract file): " .. p)
      g_logged_port = p
    end
  elseif reason == "stale" then
    -- The contract belongs to a Steam client that is gone: its port is either
    -- dead or, worse, has since been handed to some unrelated process. Wait for
    -- this session's client to publish instead of polling it (and fall back to
    -- 8080 meanwhile, which is right for a vanilla Steam launch).
    if not g_logged_stale then
      g_logged_stale = true
      log("CEF port contract is from a previous Steam session -> ignoring it (using " .. p .. ")")
    end
  end
  return p
end

-- The CEF endpoint is an unauthenticated loopback service, and the port is
-- either published in a contract file or the well-known 8080. Before speaking
-- CDP we make the kernel tell us who owns the listening socket and require it to
-- be the Steam client: otherwise any unprivileged local process could bind the
-- port first, serve a fake target list and a fake WebSocket, and drive the
-- backend registry through forged Runtime.bindingCalled events.
--
-- A "no listener" verdict is the ordinary state while Steam boots, so it is not
-- logged; a listener that is NOT Steam is logged once per change.
local g_peer_cache = peerauth.new_cache()
local g_logged_peer_reason = nil
local function verified_cef_port()
  local port = cef_port()
  local trusted, reason = peerauth.verify_cached(g_peer_cache, port)
  if trusted then
    g_logged_peer_reason = nil
    return port
  end
  if reason ~= g_logged_peer_reason then
    g_logged_peer_reason = reason
    if reason ~= "no listener" then
      log("refusing to attach on port " .. tostring(port)
        .. ": listening socket is not the Steam client (" .. tostring(reason) .. ")")
    end
  end
  return nil
end

-- ── HTTP GET against the CEF endpoint (keep-alive aware) ───────────────────
local function http_get(path)
  local port = verified_cef_port()
  if not port then return nil end
  local c = socket.tcp()
  c:settimeout(5)
  if not c:connect(CEF_HOST, port) then
    c:close()
    peerauth.invalidate(g_peer_cache)
    return nil
  end
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

-- Open the CDP WebSocket. The key is random per connection and the response's
-- Sec-WebSocket-Accept must be its RFC 6455 digest: the old code sent a constant
-- key and accepted any response containing the substring "101" anywhere, so a
-- peer could pass by replaying a canned reply it never computed.
local function ws_handshake(c, path, port)
  local key = wsframe.new_key()
  c:send("GET " .. path .. " HTTP/1.1\r\n" ..
         "Host: " .. CEF_HOST .. ":" .. tostring(port) .. "\r\n" ..
         "Upgrade: websocket\r\nConnection: Upgrade\r\n" ..
         "Sec-WebSocket-Key: " .. key .. "\r\n" ..
         "Sec-WebSocket-Version: 13\r\n\r\n")
  local resp = ""
  c:settimeout(5)
  while not resp:find("\r\n\r\n", 1, true) do
    local chunk, err = c:receive(1)
    if not chunk then return false, err end
    resp = resp .. chunk
    if #resp > 8192 then return false, "handshake response too large" end
  end
  if not wsframe.handshake_ok(resp, key) then
    return false, "handshake not accepted"
  end
  return true
end

-- List ALL current CEF targets (decoded /json), or nil + reason.
local function list_all_targets()
  local body = http_get("/json")
  -- Report the peer verdict, not "closed": a refusal (the listener is not Steam)
  -- and an absent listener are different problems and used to look identical.
  if not body then
    local _, reason = peerauth.verify_cached(g_peer_cache, cef_port())
    return nil, "no /json on CEF port " .. cef_port() .. " (" .. tostring(reason) .. ")"
  end
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
  "Steam Big Picture Mode", "QuickAccess_", "MainMenu_",
}
function injector.targets_ui_ready(targets)
  for _, target in ipairs(targets or {}) do
    local hay = (target.title or "") .. " " .. (target.url or "")
    for _, mark in ipairs(READY_MARKERS) do
      if hay:find(mark, 1, true) then return true end
    end
  end
  return false
end

local function ui_is_ready()
  local body = http_get("/json")
  if not body then return false end
  local ok, targets = pcall(json.decode, body)
  if not ok or type(targets) ~= "table" then return false end
  return injector.targets_ui_ready(targets)
end

-- Gamepad UI is a Steam-client property, not a distribution property. Match
-- the shell markers used by Steam itself so SteamOS, Bazzite, ChimeraOS and
-- ordinary Big Picture sessions all take the same path.
function injector.targets_have_gamepad_ui(targets)
  for _, target in ipairs(targets or {}) do
    local title = tostring(target.title or ""):lower()
    local url = tostring(target.url or ""):lower()
    if title == "steam big picture mode" or
       url:find("in_gamepadui=true", 1, true) or
       url:find("in_gamescope=true", 1, true) then
      return true
    end
  end
  return false
end

-- The two top-level shells which can host Lumen's visible menu and guard UI.
-- Keep this title check shared by injection relays so Gamepad UI cannot receive
-- the low-level interception without its corresponding modal surface.
function injector.is_menu_shell_title(title)
  return title == "Steam" or title == "Steam Big Picture Mode"
end

function injector.gamepad_toast_expr(event)
  return "(function(){try{return typeof window.__lumenGamepadToast==='function'" ..
    "&&window.__lumenGamepadToast(" .. json.encode(event or {}) ..
    ");}catch(e){console.warn('[Lumen] gamepad toast failed',e);return false;}})()"
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

function injector.recovery_navigation_needs_reroute(recovery_only, frame)
  if recovery_only ~= true or type(frame) ~= "table" or frame.parentId then
    return false
  end
  local url = tostring(frame.url or "")
  return url ~= "" and not failed_document_url(url)
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
    -- Per-connection binding token. The polyfill carries it; every
    -- Runtime.bindingCalled payload must repeat it or it is dropped. A fresh
    -- value per connection means a token learned once is useless after a
    -- reconnect or a webhelper restart.
    token = nonce.hex(16),
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
  local port = verified_cef_port()
  if not port then return false end
  local c = socket.tcp(); c:settimeout(5)
  if not c:connect(CEF_HOST, port) then
    -- The peer we vouched for is gone (or was never reachable). Drop the cached
    -- verdict so the next attempt re-checks who owns the port instead of riding
    -- the remaining TTL.
    peerauth.invalidate(g_peer_cache)
    return false
  end
  if not ws_handshake(c, path, port) then
    peerauth.invalidate(g_peer_cache)
    c:close()
    return false
  end
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
  -- Publish the connection token FIRST and unconditionally. Scripts that talk to
  -- the binding directly (the SharedJSContext guards) have no polyfill closure to
  -- read it from, and without it every call they make is dropped.
  send_cmd(c, s, "Runtime.evaluate",
    { expression = polyfill.token_js(self.token), returnByValue = true })
  if a.polyfill then
    -- Built here, not in boot: it embeds THIS connection's binding token.
    send_cmd(c, s, "Runtime.evaluate",
      { expression = polyfill.build(self.token), returnByValue = true })
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
-- The payload must carry this connection's binding token. Runtime.addBinding
-- publishes window.__lumenSend to every execution context of the target,
-- subframes included, while the polyfill (and therefore the token) is evaluated
-- only in the page's own default context. Anything that calls the binding
-- without the token did not come from the code we injected: drop it silently.
function Conn:_on_binding(payload_str)
  local req, why = polyfill.parse_request(payload_str, self.token)
  if not req then
    log("binding call rejected (" .. tostring(why) .. "): " .. tostring(self.title))
    return
  end
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
  elseif req.fn == "__lumenAutoFixLaunchWait" then
    local appid = tonumber((req.args or {}).appid)
    if appid and self.manager then
      self.manager:broadcast_auto_fix_modal(appid, true)
    end
    result = '{"ok":true}'
  elseif req.fn == "__lumenAutoFixLaunchTimeout" then
    local appid = tonumber((req.args or {}).appid)
    if appid and self.manager then
      self.manager:broadcast_auto_fix_timeout(appid)
    end
    result = '{"ok":true}'
  elseif req.fn == "__lumenAutoFixLaunchFailed" then
    local appid = tonumber((req.args or {}).appid)
    if appid and self.manager then
      self.manager:broadcast_auto_fix_failed(appid)
    end
    result = '{"ok":true}'
  elseif req.fn == "__lumenReleaseAutoFixLaunch" then
    local appid = tonumber((req.args or {}).appid)
    result = (appid and self.manager
        and self.manager:release_auto_fix_launch(appid))
      and '{"ok":true}' or '{"ok":false}'
  elseif req.fn == "__lumenCancelAutoFixLaunch" then
    local appid = tonumber((req.args or {}).appid)
    result = (appid and self.manager
        and self.manager:cancel_auto_fix_launch(appid))
      and '{"ok":true}' or '{"ok":false}'
  elseif req.fn == "__lumenInstallBlocked" then
    local appid = tonumber((req.args or {}).appid)
    if appid and self.manager then
      self.manager:broadcast_install_readiness_blocked(appid)
    end
    result = '{"ok":true}'
  elseif req.fn == "__lumenInstallAnyway" then
    local appid = tonumber((req.args or {}).appid)
    result = (appid and self.manager and self.manager:install_anyway(appid))
      and '{"ok":true}' or '{"ok":false}'
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
  elseif req.fn == "__lumenLuaToolsLoginOpen" then
    local a = req.args or {}
    local ok_open, reason = false, "no_shell"
    if self.manager then
      ok_open, reason = self.manager:lua_tools_login_open(tostring(a.url or ""))
    end
    result = ok_open and '{"ok":true}'
      or ('{"ok":false,"reason":' .. json.encode(tostring(reason or "invalid_url")) .. '}')
  elseif req.fn == "__lumenLuaToolsLoginClose" then
    local closed = 0
    if self.manager then closed = self.manager:lua_tools_login_close() or 0 end
    result = '{"ok":true,"closed":' .. tostring(closed) .. '}'
  elseif req.fn == "__lumenClearDiscordSession" then
    local cookies, origins = 0, 0
    if self.manager then cookies, origins = self.manager:clear_discord_session() end
    result = '{"ok":true,"cookies":' .. tostring(cookies or 0)
      .. ',"origins":' .. tostring(origins or 0) .. '}'
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
        if m.method == "Page.frameNavigated"
            and injector.recovery_navigation_needs_reroute(
              self.recovery_only, m.params and m.params.frame) then
          -- Steam may reuse the failed data: target for the real Store page.
          -- Close this probe so discovery can route the final URL to the right
          -- assets (ordinary Store, Special Offers, or no channel at all).
          self.recovery_failed = true
        elseif not injector.recovery_allows_event(self.recovery_only, m.method) then
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

-- ── discovery cadence ──────────────────────────────────────────────────────
-- Before the first successful attach, a failed /json is the NORMAL state: Steam
-- has not opened its CEF endpoint yet (or the contract still names the previous
-- session's port). Backing off on those expected failures used to blind the
-- sidecar for up to 8 s at a time (measured: 1 -> 2 -> 4 -> 8 s while Steam was
-- already painting), so pre-attach discovery runs at a fixed cadence instead.
-- The doubling backoff is kept for POST-injection reconnects, where repeated
-- failures really do mean "nothing to talk to".
injector.DISCOVER_INTERVAL = 0.3
injector.RECONNECT_BACKOFF_MAX = 15

-- next_retry_delay(attached_once, backoff) -> seconds to wait after a failed or
-- not-yet-ready probe. Pure.
function injector.next_retry_delay(attached_once, backoff)
  if not attached_once then return injector.DISCOVER_INTERVAL end
  return math.max(injector.DISCOVER_INTERVAL, tonumber(backoff) or 1)
end

-- grow_backoff(attached_once, backoff) -> the backoff to use for the NEXT
-- failure. Pure; stays at 1 until the first attach has happened.
function injector.grow_backoff(attached_once, backoff)
  if not attached_once then return 1 end
  return math.min((tonumber(backoff) or 1) * 2, injector.RECONNECT_BACKOFF_MAX)
end

-- ── Multi-target manager (cooperative new/fds/tick) ────────────────────────
local State = {}
State.__index = State

-- new{ channels={ {titles=, origins=, assets=, remote=}, ... }, registry=, ... }
-- Back-compat: a single { targets=, target_origins=, assets= } is accepted and
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
    channels = { { titles = titles, origins = opts.target_origins,
                   assets = opts.assets } }
  end
  return setmetatable({
    channels = channels,
    registry = opts.registry,
    conns = {},          -- ws_url -> Conn
    backoff = 1,
    next_attempt = 0,
    ui_ready = false,    -- latched once Steam's main UI is up (post-login/paint)
    attached_once = false, -- has any target ever been attached? (gates backoff)
    last_port = nil,     -- CEF port the current backoff was armed against
    shared_ws_url = nil,
    gamepad_ui = false,  -- refreshed from Steam's current CEF target markers
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
  self.gamepad_ui = false
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

-- How long the loop may block before calling tick() again. A pending browser
-- request needs the fast cadence; before the first attach we want the discovery
-- cadence (otherwise a one-second sleep, not the discovery interval, is what
-- decides how quickly the moon button appears); afterwards the idle second is
-- enough because attached sockets wake select() themselves.
function State:poll_timeout()
  if self:needs_fast_tick() then return 0.01 end
  if not self.attached_once then return injector.DISCOVER_INTERVAL end
  return 1
end

-- Discover wanted targets and connect to any not yet connected (backoff-gated).
function State:_discover()
  -- Sub-second clock: os.time() has one-second granularity, which cannot express
  -- the pre-attach discovery cadence.
  local now = socket.gettime()
  -- Read the contract every tick (it is a few bytes) so this session's port is
  -- picked up the moment the client publishes it. A backoff armed against the
  -- OLD endpoint must not delay the first attempt against the new one.
  local port = cef_port()
  if port ~= self.last_port then
    if self.last_port ~= nil then
      log("CEF port changed " .. tostring(self.last_port) .. " -> " .. tostring(port)
        .. " -> retrying discovery immediately")
    end
    self.last_port = port
    self.backoff = 1
    self.next_attempt = 0
  end
  if now < self.next_attempt then return end
  local targets, err = list_all_targets()
  if not targets then
    self.next_attempt = now + injector.next_retry_delay(self.attached_once, self.backoff)
    self.backoff = injector.grow_backoff(self.attached_once, self.backoff)
    return
  end
  self.backoff = 1
  self.next_attempt = 0
  self.gamepad_ui = injector.targets_have_gamepad_ui(targets)
  if self:observe_shared_generation(targets) then
    log("new SharedJSContext generation -> waiting for Steam UI readiness")
  end
  -- Hold off ALL attaching until Steam's main UI is up. Attaching to
  -- SharedJSContext during the login/init phase stalls the client boot
  -- (Phase 4 finding). Latch once ready so later navigations aren't gated.
  if not self.ui_ready then
    if injector.targets_ui_ready(targets) then
      self.ui_ready = true
      log("Steam UI ready -> attaching")
    else
      -- Readiness is polled, never backed off: the gate itself is unchanged (it
      -- is what prevents the black-screen boot), only how often we look.
      self.next_attempt = now + injector.DISCOVER_INTERVAL
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
      if conn:connect() then
        self.conns[t.webSocketDebuggerUrl] = conn
        -- First attach reached: from here on, repeated failures are genuine
        -- reconnect failures and may back off.
        self.attached_once = true
      end
    end
  end
end

function State:is_gamepad_ui()
  return self.gamepad_ui == true
end

-- Relay a validated queue event to the SharedJSContext toast bridge. The
-- caller checks is_gamepad_ui() first; Desktop Mode continues to use
-- notify-send and never receives a duplicate Steam toast.
function State:show_gamepad_toast(event)
  if not self:is_gamepad_ui() then return false end
  local expr = injector.gamepad_toast_expr(event)
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      return true
    end
  end
  return false
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

-- A queued automatic fix must not race Steam's post-install action or a Play
-- click. This query runs only while a ready job exists and is bounded tightly;
-- the normal no-job loop never opens an extra CDP connection.
function State:is_app_busy(appid)
  appid = tonumber(appid)
  if not appid or appid <= 0 then return false end
  local shared = self:_shared_ws()
  if not shared then return false end
  local expr = "(async function(){try{if(!window.SteamClient||!SteamClient.Apps||"
    .. "typeof SteamClient.Apps.GetActiveGameActions!=='function')return false;"
    .. "var actions=await SteamClient.Apps.GetActiveGameActions();"
    .. "if(!Array.isArray(actions))return false;var want='" .. tostring(math.floor(appid)) .. "';"
    .. "return actions.some(function(a){if(!a)return false;var raw=a.gameid!=null?a.gameid:"
    .. "(a.gameID!=null?a.gameID:a.appid);var text=String(raw==null?'':raw);"
    .. "if(text===want)return true;try{return String(BigInt(text)&0xffffffn)===want;}"
    .. "catch(_){return false;}});}catch(_){return false;}})()"
  local port = verified_cef_port()
  if not port then return false end
  return cdpreq.evaluate(port, shared, expr, 0.75) == true
end

-- Keep the SharedJS RunGame guard synchronized with only the AppIDs whose
-- automatic work is actively blocking. SteamClient.Apps.RunGame exists in
-- SharedJSContext (not the visible shell). When an AppID stops blocking, its
-- exact deferred native call resumes once the work completes. The JS guard
-- cancels every deferred call before an uninstall and also cancels attempts
-- that reach their timeout, so a saved Play cannot cross either boundary.
function State:update_auto_fix_guard(jobs)
  jobs = type(jobs) == "table" and jobs or {}
  local expr = "window.__lumenUpdateAutoFixGuard&&window.__lumenUpdateAutoFixGuard("
    .. json.encode(jobs) .. ")"
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      return true
    end
  end
  return false
end

-- Keep the synchronous SharedJS install guard supplied with a short-lived map.
-- The map is prepared off-click by the sidecar; the wrapper itself performs no
-- disk, RPC or network work. Missing/stale state therefore fails open.
function State:update_install_readiness_guard(apps)
  apps = type(apps) == "table" and apps or {}
  local expr = "window.__lumenUpdateInstallReadinessGuard&&"
    .. "window.__lumenUpdateInstallReadinessGuard(" .. json.encode(apps) .. ")"
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      return true
    end
  end
  return false
end

-- The compact progress UI lives in the Lumen menu bundle (desktop shell plus
-- Store/Community overlay copies). SharedJS owns the launch guard but has no
-- visible UI, so avoid sending it the once-per-second progress repaint.
function State:update_auto_fix_ui(jobs)
  jobs = type(jobs) == "table" and jobs or {}
  local expr = "window.__lumenUpdateAutoFixUI&&window.__lumenUpdateAutoFixUI({jobs:"
    .. json.encode(jobs) .. "})"
  local sent = false
  for _, conn in pairs(self.conns) do
    local url = tostring(conn.url or "")
    local menu_context = injector.is_menu_shell_title(conn.title)
      or url:find("store.steampowered.com", 1, true)
      or url:find("steamcommunity.com", 1, true)
    if conn.sock and menu_context then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      sent = true
    end
  end
  return sent
end

local function auto_fix_guard_action(self, function_name, appid)
  appid = tonumber(appid)
  if not appid or appid <= 0 then return false end
  local expr = "window." .. function_name .. "&&window." .. function_name
    .. "(" .. tostring(math.floor(appid)) .. ")"
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression = expr, returnByValue = true })
      return true
    end
  end
  return false
end

function State:release_auto_fix_launch(appid)
  return auto_fix_guard_action(self, "__lumenReleaseAutoFixLaunch", appid)
end

function State:cancel_auto_fix_launch(appid)
  return auto_fix_guard_action(self, "__lumenCancelAutoFixLaunch", appid)
end

function State:install_anyway(appid)
  return auto_fix_guard_action(self, "__lumenInstallAnyway", appid)
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
-- ── in-client (Discord) sign-in ────────────────────────────────────────────
-- See steamoauth.lua for why a web view has to be borrowed and why the cookie
-- can be read from any target. These run bounded blocking CDP requests (cdpreq)
-- because they need command RESULTS, which the fire-and-forget connections above
-- cannot deliver.

function State:_shared_ws()
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then return conn.ws_url end
  end
  local targets = list_all_targets()
  local shared = targets and cdp.find_shared_js_context(targets)
  return shared and shared.webSocketDebuggerUrl or nil
end

-- Open an OAuth URL in Steam's own browser window. Returns true, or false plus a
-- machine-readable reason the panel turns into copy.
function State:_open_internal_oauth(url, label)
  local port = verified_cef_port()
  if not port then return false, "no_shell" end
  local targets = list_all_targets()
  -- Whether this client can host the sign-in at all is decided BEFORE clicking,
  -- so Big Picture never flips to a blank external-browser view.
  local supported, reason = steamoauth.supported(targets,
    injector.targets_have_gamepad_ui(targets))
  if not supported then return false, reason end
  local shared = self:_shared_ws()
  if not shared then return false, "no_shell" end

  local launcher = steamoauth.pick_launcher(targets)
  local restore_url = nil

  if not launcher then
    -- No live store/community view: borrow one in the background. Big Picture
    -- shells have no MainWindowBrowserManager, and there this cannot work.
    if cdpreq.evaluate(port, shared, steamoauth.available_expr()) ~= true then
      return false, "unsupported"
    end
    restore_url = cdpreq.evaluate(port, shared, steamoauth.read_browser_url_expr())
    if type(restore_url) ~= "string" or restore_url == "" then restore_url = nil end
    if cdpreq.evaluate(port, shared,
        steamoauth.load_background_expr(steamoauth.LAUNCHER_URL)) ~= true then
      return false, "unsupported"
    end
    for _ = 1, 25 do
      socket.sleep(0.2)
      launcher = steamoauth.pick_launcher(list_all_targets())
      if launcher then break end
    end
    if not launcher then return false, "no_launcher" end
    -- The view is loading; the anchor needs a document body to click in.
    socket.sleep(0.4)
  end

  -- userGesture: CEF's popup blocker drops a gesture-less target=_blank click
  -- WITHOUT reporting failure, so the flag is what makes the window appear.
  local clicked = cdpreq.evaluate(port, launcher.webSocketDebuggerUrl,
    steamoauth.open_link_expr(url), nil, true)

  -- Put the borrowed view back on its previous page either way, so the user's
  -- Store tab is where they left it.
  if restore_url then
    cdpreq.evaluate(port, shared, steamoauth.load_background_expr(restore_url))
  end
  if clicked ~= true then return false, "click_failed" end
  log(tostring(label or "oauth") .. ": sign-in window opened")
  return true
end

function State:lua_tools_login_open(url)
  url = luatoolslogin.safe_auth_url(url)
  if not url then return false, "invalid_url" end
  return self:_open_internal_oauth(url, "lua.tools")
end

function State:lua_tools_login_close()
  local port = verified_cef_port()
  if not port then return 0 end
  local closed = 0
  for _, target in ipairs(luatoolslogin.login_windows(list_all_targets())) do
    if cdpreq.request(port, target.webSocketDebuggerUrl, "Page.close", {}) then
      closed = closed + 1
    end
  end
  return closed
end

-- Remove Discord state from Steam's CEF only. Cookies are enumerated first and
-- deleted one by one for exact Discord domains; origin storage is cleared from
-- a fixed allowlist. Steam, lua.tools and unrelated browser state are
-- never part of either request.
function State:clear_discord_session()
  local shared = self:_shared_ws()
  if not shared then return 0, 0 end
  local port = verified_cef_port()
  if not port then return 0, 0 end
  local origins = luatoolslogin.discord_storage_origins()
  local urls = {}
  for _, origin in ipairs(origins) do urls[#urls + 1] = origin .. "/" end
  local cookie_result = cdpreq.request(port, shared, "Network.getCookies", { urls = urls })
  local deleted = 0
  for _, params in ipairs(luatoolslogin.discord_cookie_deletions(cookie_result)) do
    if cdpreq.request(port, shared, "Network.deleteCookies", params) then
      deleted = deleted + 1
    end
  end
  local cleared = 0
  for _, origin in ipairs(origins) do
    if cdpreq.request(port, shared, "Storage.clearDataForOrigin", {
        origin = origin, storageTypes = "all",
      }) then
      cleared = cleared + 1
    end
  end
  return deleted, cleared
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
      if conn.sock and injector.is_menu_shell_title(conn.title) then fire(conn) end
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

function State:broadcast_auto_fix_modal(appid, launch_pending)
  local id = math.floor(tonumber(appid) or 0)
  self:_fire_on_top("window.__lumenShowAutoFixModal&&window.__lumenShowAutoFixModal("
    .. tostring(id) .. "," .. (launch_pending and "true" or "false") .. ")")
end

function State:broadcast_auto_fix_timeout(appid)
  local id = math.floor(tonumber(appid) or 0)
  self:_fire_on_top("window.__lumenShowAutoFixTimeout&&window.__lumenShowAutoFixTimeout("
    .. tostring(id) .. ")")
end

-- The guard dropped a saved launch because its queued work failed. Report it
-- where the timeout notice already appears, so the reason replaces a 0% bar.
function State:broadcast_auto_fix_failed(appid)
  local id = math.floor(tonumber(appid) or 0)
  self:_fire_on_top("window.__lumenShowAutoFixFailed&&window.__lumenShowAutoFixFailed("
    .. tostring(id) .. ")")
end

function State:broadcast_install_readiness_blocked(appid)
  local id = math.floor(tonumber(appid) or 0)
  self:_fire_on_top(
    "window.__lumenShowInstallReadinessBlocked&&"
      .. "window.__lumenShowInstallReadinessBlocked(" .. tostring(id) .. ")")
end

function State:broadcast_install_readiness_ready(appid)
  local id = math.floor(tonumber(appid) or 0)
  self:_fire_on_top(
    "window.__lumenShowInstallReadinessReady&&"
      .. "window.__lumenShowInstallReadinessReady(" .. tostring(id) .. ")")
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
