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

-- CDP domains used by each connection class. Cold-boot theme hooks need to be
-- evaluated in SharedJSContext before Steam creates the first window, but the
-- full Page/binding/probe setup is intentionally deferred: enabling it during
-- early client initialization has historically stalled or blanked Steam.
function injector.connection_plan(early, bypass_csp)
  if early then
    return { runtime=true, inject_immediately=true, reinject_immediately=true }
  end
  return { runtime=true, page=true, binding=true, fetch=true,
    ready_probe=true, visibility_probe=true, bypass_csp=bypass_csp == true }
end

function injector.recreation_plan(early, has_virtual_provider, bypass_csp)
  if early then return { reinject_immediately=true } end
  return { runtime=true, page=true, fetch=has_virtual_provider == true,
    binding=true, ready_probe=true, visibility_probe=true,
    bypass_csp=bypass_csp == true }
end

-- Before Steam's UI exists we deliberately avoid exponential backoff: the
-- SharedJSContext-only interval can be shorter than a second, and missing it
-- means the default UI paints before the theme hook is installed. After boot,
-- normal bounded backoff remains appropriate for a disappeared webhelper.
function injector.discovery_retry_delay(ui_ready, backoff)
  if not ui_ready then return 0.1 end
  return math.max(1, math.min(tonumber(backoff) or 1, 15))
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

-- Browser/root CDP websocket. Fetch enabled here applies to every current and
-- future renderer, unlike a /devtools/page connection which necessarily starts
-- after that page already exists (and may already have painted).
local function browser_ws_url()
  local body = http_get("/json/version")
  if not body then return nil end
  local ok, version = pcall(json.decode, body)
  if not ok or type(version) ~= "table" then return nil end
  return version.webSocketDebuggerUrl
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

local function send_cmd(c, session, method, params, child_session)
  local frame = wsframe.encode_text(session:build_command(method, params, child_session))
  -- CDP sockets run non-blocking while the event loop drains them. A single
  -- send() is not guaranteed to write a whole large frame (theme CSS responses
  -- routinely exceed the kernel buffer); truncating it silently makes one
  -- target miss the theme. Temporarily use a bounded blocking write and honor
  -- LuaSocket's last-byte index until the entire RFC6455 frame is delivered.
  c:settimeout(5)
  local first = 1
  while first <= #frame do
    local sent, err, last = c:send(frame, first)
    local upto = sent or last
    if not upto or upto < first then c:settimeout(0); return false, err end
    first = upto + 1
    if err and err ~= "timeout" then c:settimeout(0); return false, err end
  end
  c:settimeout(0)
  return true
end

-- Pick the one active custom-theme gateway from the composed channel set.
-- Normal Lumen channels intentionally do not carry these fields, so disabled
-- themes allocate no browser socket and enable no Fetch domain at all.
function injector.theme_gateway_config(channels, ui_ready)
  local gateway = nil
  for _, channel in ipairs(channels or {}) do
    local assets = channel.assets
    if type(assets) == "table"
        and assets.browser_gateway == true
        and type(assets.virtual_provider) == "function"
        and type(assets.document_bootstrap_source) == "string" then
      gateway = gateway or {}
      gateway.virtual_provider = assets.virtual_provider
      gateway.document_bootstrap_source = assets.document_bootstrap_source
      gateway.shared_bootstrap_source = assets.shared_bootstrap_source
        or assets.document_bootstrap_source
      gateway.bypass_csp = assets.bypass_csp == true
    end
  end
  return gateway
end

-- A deliberately narrower browser-level observer for the account selector.
-- Unlike the full theme gateway it enables neither Fetch nor CSP bypass and it
-- never pauses a renderer. Its only job is registering the already-inline
-- popup bootstrap before the login document starts executing.
function injector.login_theme_gateway(channels, ui_ready)
  if ui_ready then return nil end
  for _, channel in ipairs(channels or {}) do
    local assets = channel.assets
    if type(assets) == "table"
        and assets.login_browser_gateway == true
        and type(assets.login_guard_source) == "string"
        and type(assets.login_theme_source) == "string" then
      return {
        login_only = true,
        login_guard_source = assets.login_guard_source,
        login_theme_source = assets.login_theme_source,
      }
    end
  end
  return nil
end

function injector.shared_theme_target(info)
  if type(info) ~= "table" or info.type ~= "page" then return false end
  return info.title == "SharedJSContext"
    or tostring(info.url or ""):find("IN_STEAMUI_SHARED_CONTEXT=true", 1, true) ~= nil
end

function injector.browser_uses_auto_attach(gateway)
  return not (gateway and gateway.login_only == true)
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

-- Only presentation headers are forwarded to libcurl. In particular, do not
-- forward Cookie/Authorization/session identifiers or Accept-Encoding (the C
-- binding returns decoded bytes, which must not retain a gzip response header).
function injector.anonymous_request_headers(headers)
  local allowed = {
    ["accept"] = true,
    ["accept-language"] = true,
    ["user-agent"] = true,
  }
  local out, have_ua = {}, false
  for name, value in pairs(type(headers) == "table" and headers or {}) do
    local lower = tostring(name):lower()
    if allowed[lower] then
      out[#out + 1] = tostring(name) .. ": " .. tostring(value)
      if lower == "user-agent" then have_ua = true end
    end
  end
  if not have_ua then out[#out + 1] = "User-Agent: Valve Steam Client" end
  table.sort(out)
  return out
end

function injector.page_fetch_patterns(assets, root_owns_virtual)
  if type(assets) ~= "table" then return {} end
  local patterns = {}
  if type(assets.virtual_provider) == "function"
      and root_owns_virtual ~= true then
    patterns[#patterns + 1] = {
      urlPattern="https://lumen-theme.local/*", requestStage="Request",
    }
  end
  if assets.anonymous_web == true then
    patterns[#patterns + 1] = {
      urlPattern="https://store.steampowered.com/*",
      resourceType="Document", requestStage="Request",
    }
    patterns[#patterns + 1] = {
      urlPattern="https://steamcommunity.com/*",
      resourceType="Document", requestStage="Request",
    }
  end
  return patterns
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
          target=target, assets=recovery_assets, recovery=true,
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
  if response.effective_url
      and not injector.anonymous_web_url(response.effective_url) then
    return nil, "unsafe effective URL"
  end
  if status >= 300 and status < 400 then
    if not injector.anonymous_web_url(response.redirect_url) then
      return nil, "unsafe redirect"
    end
    return {action="redirect", status=status, url=response.redirect_url}
  end
  if status < 200 or status >= 300 then
    return nil, "unexpected HTTP status"
  end
  local content_type = tostring(response.content_type or "")
  local media_type = content_type:lower():match("^%s*([^;]+)")
  if media_type ~= "text/html" and media_type ~= "application/xhtml+xml" then
    return nil, "non-HTML response"
  end
  return {action="document", status=status, content_type=content_type}
end

function injector.browser_fetch_patterns(gateway)
  if not gateway then return {} end
  local patterns = {}
  if type(gateway.virtual_provider) == "function" then
    patterns[#patterns + 1] = {
      urlPattern="https://lumen-theme.local/*", requestStage="Request"
    }
  end
  return patterns
end

function injector.browser_auto_attach_params(enabled)
  return {
    autoAttach=enabled == true,
    -- Steam's CEF 126 can leave PopupManager-owned windows permanently
    -- suspended when this is true, even after Runtime.runIfWaitingForDebugger.
    -- Existing/reused targets are prepared ahead of navigation; internal
    -- popups are covered synchronously by the SharedJSContext hook.
    waitForDebuggerOnStart=false,
    flatten=true,
  }
end

function injector.document_bootstrap_params(source, run_immediately)
  local params = {source=source}
  if run_immediately then params.runImmediately = true end
  return params
end

function injector.renderer_startup_plan(waiting_for_debugger)
  return {
    -- Fetch.enable/Page.addScript commands are ordered ahead of Runtime.run on
    -- the same flattened session. Waiting for their replies while the renderer
    -- itself is debugger-paused deadlocks CEF, so fresh targets resume as soon
    -- as setup has been queued. Existing targets can await acknowledgements.
    resume_after_queue=waiting_for_debugger == true,
    wait_for_setup_results=waiting_for_debugger ~= true,
  }
end

function injector.theme_transition_expr()
  return [[(function(){
    if(document.getElementById('lumen-theme-transition'))return;
    var style=document.createElement('style');style.id='lumen-theme-transition-style';
    style.textContent='@keyframes lumenThemeTimeout{to{opacity:0;visibility:hidden;pointer-events:none}}'+
      '#lumen-theme-transition{position:fixed;inset:0;z-index:2147483647;display:flex;'+
      'align-items:center;justify-content:center;background:#101216;color:#b8bcbf;'+
      'font:14px Arial,sans-serif;animation:lumenThemeTimeout .01s 8s forwards}'+
      '#lumen-theme-transition:after{content:"";width:28px;height:28px;border:3px solid #59616d;'+
      'border-top-color:#1a9fff;border-radius:50%;animation:lumenThemeSpin .7s linear infinite}'+
      '@keyframes lumenThemeSpin{to{transform:rotate(360deg)}}';
    var cover=document.createElement('div');cover.id='lumen-theme-transition';
    (document.head||document.documentElement).appendChild(style);
    (document.body||document.documentElement).appendChild(cover);
  })()]]
end

-- ── Per-target connection object ───────────────────────────────────────────
local Conn = {}
Conn.__index = Conn

local function conn_new(target, assets, registry, manager, browser_target, early,
    recovery)
  return setmetatable({
    title = target.title,
    url = target.url or "",
    ws_url = target.webSocketDebuggerUrl,
    assets = assets,
    registry = registry,
    manager = manager,      -- the State, for control relays (view hide/show)
    browser_target = browser_target == true,
    early = early == true,
    recovery_only = recovery == true,
    recovery_route = recovery == true,
    sock = nil,
    session = nil,
    buf = "",
    injected = false,       -- has the first injection happened?
    deferred_after_id = nil,-- early hook ack that releases the compiled theme
    deferred_sent = false,
    ready_probe_id = nil,   -- cdp id of the document.readyState probe
    visibility_probe_id = nil,
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

function Conn:_probe_visibility()
  if not self.browser_target then return end
  self.visibility_probe_id = self.session._id + 1
  send_cmd(self.sock, self.session, "Runtime.evaluate",
    { expression = "!document.hidden", returnByValue = true })
end

function Conn:_enable_fetch()
  -- The root gateway owns virtual requests when available. Enabling the same
  -- Fetch pattern on a page as well would pause one request in two CDP clients.
  local root_owns_virtual = self.manager and self.manager.browser_conn
      and self.manager.browser_conn.enabled
      and self.manager.browser_conn.gateway
      and type(self.manager.browser_conn.gateway.virtual_provider) == "function"
  local patterns = injector.page_fetch_patterns(self.assets, root_owns_virtual)
  if #patterns == 0 then return end
  self.fetch_enable_id = self.session._id + 1
  send_cmd(self.sock, self.session, "Fetch.enable", {patterns=patterns})
end

function Conn:_fail_anonymous(request_id, reason)
  send_cmd(self.sock, self.session, "Fetch.failRequest", {
    requestId=request_id, errorReason=reason or "Failed",
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
    self:_fail_anonymous(params.requestId)
    return
  end
  local ok_start, handle, start_err = pcall(http.start, request.url, {
    headers=injector.anonymous_request_headers(request.headers),
    timeout=10,
    follow_redirects=false,
    https_only=true,
    max_bytes=8 * 1024 * 1024,
  })
  if not ok_start or not handle then
    log("anonymous web request failed to start: "
      .. tostring(ok_start and start_err or handle))
    self:_fail_anonymous(params.requestId)
    return
  end
  self.requests[params.requestId] = {handle=handle, http=http}
end

function Conn:_finish_anonymous(request_id, response, err)
  local plan, plan_err = injector.anonymous_response_plan(response)
  if not plan then
    log("anonymous web request failed: " .. tostring(err or plan_err))
    self:_fail_anonymous(request_id)
    return
  end
  if plan.action == "redirect" then
    send_cmd(self.sock, self.session, "Fetch.fulfillRequest", {
      requestId=request_id,
      responseCode=plan.status,
      responseHeaders={
        {name="Location",value=plan.url},
        {name="Cache-Control",value="no-store"},
      },
      body="",
    })
    return
  end
  send_cmd(self.sock, self.session, "Fetch.fulfillRequest", {
    requestId=request_id,
    responseCode=plan.status,
    responseHeaders={
      {name="Content-Type",value=plan.content_type},
      {name="Cache-Control",value="no-store"},
    },
    body=b64.encode(response.body),
  })
end

function Conn:_poll_anonymous()
  for request_id, pending in pairs(self.requests) do
    local ok_poll, done, response, err = pcall(
      pending.http.poll, pending.handle)
    if not ok_poll then
      self.requests[request_id] = nil
      self:_fail_anonymous(request_id)
      log("anonymous web request poll failed: " .. tostring(done))
    elseif done then
      self.requests[request_id] = nil
      self:_finish_anonymous(request_id, response, err)
    end
  end
end

function Conn:_activate_recovery(url)
  if not url or not self.recovery_only then return end
  self.recovery_only = false
  self.recovery_url = url
  self.url = url
  send_cmd(self.sock, self.session, "Runtime.enable")
  if self.assets and self.assets.bypass_csp then
    send_cmd(self.sock, self.session, "Page.setBypassCSP", {enabled=true})
  end
  send_cmd(self.sock, self.session, "Runtime.addBinding", {name=BINDING})
  self:_probe_ready()
  self:_probe_visibility()
  if self.fetch_enabled and not self.anonymous_reloaded then
    self.anonymous_reloaded = true
    send_cmd(self.sock, self.session, "Page.navigate", {url=url})
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
  self.deferred_after_id = nil
  self.deferred_sent = false
  if self.recovery_only then
    send_cmd(c, self.session, "Page.enable")
    self:_enable_fetch()
    self.history_probe_id = self.session._id + 1
    send_cmd(c, self.session, "Page.getNavigationHistory")
    log("attached recovery probe: " .. self.title)
    return true
  end
  local plan = injector.connection_plan(self.early,
    self.assets and self.assets.bypass_csp)
  if plan.runtime then send_cmd(c, self.session, "Runtime.enable") end
  if plan.page then send_cmd(c, self.session, "Page.enable") end
  if plan.bypass_csp then
    send_cmd(c, self.session, "Page.setBypassCSP", { enabled=true })
  end
  if plan.fetch then self:_enable_fetch() end
  if plan.binding then
    send_cmd(c, self.session, "Runtime.addBinding", { name = BINDING })
  end
  if plan.inject_immediately then
    self:_inject_once()
    log("attached early: " .. self.title)
    return true
  end
  -- Do NOT inject yet: injecting while the UI is still initializing blanks the
  -- Steam render (Phase 4 finding). Gate the first injection on readiness —
  -- probe document.readyState now (covers the already-loaded case) and also
  -- inject on Page.loadEventFired (covers the still-loading case).
  if plan.ready_probe then self:_probe_ready() end
  if plan.visibility_probe then self:_probe_visibility() end
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
  -- At cold boot the first tiny script installs a synchronous PopupManager
  -- prepaint guard.  Do not put the multi-megabyte compiled theme in that same
  -- evaluate: wait until Chromium acknowledges the guard, then send the heavy
  -- hook as a second command.  This preserves command ordering without using
  -- Target.setAutoAttach (which stalls Steam's login renderer).
  if self.early and not self.deferred_sent and #(a.deferred_js or {}) > 0 then
    self.deferred_after_id = s._id
  end
end

function Conn:_inject_deferred()
  if self.deferred_sent then return end
  self.deferred_sent = true
  self.deferred_after_id = nil
  for _, js in ipairs((self.assets and self.assets.deferred_js) or {}) do
    send_cmd(self.sock, self.session, "Runtime.evaluate",
      { expression = js, returnByValue = true })
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
  elseif req.fn == "__lumenViewVisibility" then
    if self.manager then
      self.manager:set_view_visibility(self.ws_url,
        req.args and req.args.visible == true)
    end
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
  elseif req.fn == "__lumenRestartJSContext" then
    local prepared = self.manager and self.manager:commit_pending_channels()
    if prepared and self.manager:restart_js_context() then
      result = '{"ok":true}'
    else
      result = '{"ok":false}'
    end
  else
    result = injector.dispatch_method(self.registry, req.fn, req.args)
  end
  -- Resolve the page-side promise. id + result passed as JS string literals.
  local expr = polyfill.resolve_js(json.encode(tostring(id)), json.encode(result))
  if self.sock then send_cmd(self.sock, self.session, "Runtime.evaluate", { expression = expr }) end
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
          send_cmd(c, self.session, "Page.navigate", {url=recovery_url})
        end
      elseif (m.kind == "result" or m.kind == "error")
          and self.deferred_after_id and m.id == self.deferred_after_id then
        self:_inject_deferred()
      elseif m.kind == "result" and self.ready_probe_id and m.id == self.ready_probe_id then
        -- Reply to our document.readyState probe.
        self.ready_probe_id = nil
        local val = m.result and m.result.result and m.result.result.value
        if val == "complete" then
          self:_inject_once()
        end
        -- If "loading"/"interactive", wait for Page.loadEventFired below.
      elseif m.kind == "result" and self.visibility_probe_id and m.id == self.visibility_probe_id then
        self.visibility_probe_id = nil
        local visible = m.result and m.result.result and m.result.result.value == true
        if self.manager and self.ws_url then
          self.manager:set_view_visibility(self.ws_url, visible)
        end
      elseif m.kind == "event" then
        if m.method == "Page.frameNavigated"
            and injector.recovery_navigation_needs_reroute(
              self.recovery_only, m.params and m.params.frame) then
          -- Steam may reuse the failed data: target for the real Store page.
          -- Close this probe so discovery can route the final URL to the right
          -- assets (ordinary Store, Special Offers, or no channel at all).
          self.recovery_failed = true
        elseif not injector.recovery_allows_event(self.recovery_only, m.method) then
          -- Wait for history approval before binding or injecting this failed
          -- document into any Steam page.
        elseif m.method == "Fetch.requestPaused" then
          local p = m.params or {}
          local url = p.request and p.request.url or ""
          if self.assets and self.assets.anonymous_web == true
              and injector.anonymous_web_url(url) then
            self:_start_anonymous_request(p)
          elseif self.assets and type(self.assets.virtual_provider) == "function"
              and url:find("https://lumen-theme.local/", 1, true) == 1 then
            local ok_asset, bytes, mime = pcall(self.assets.virtual_provider, url)
            if ok_asset and bytes then
              send_cmd(c, self.session, "Fetch.fulfillRequest", {
                requestId=p.requestId, responseCode=200,
                responseHeaders={
                  {name="Content-Type",value=mime or "application/octet-stream"},
                  {name="Cache-Control",value="public, max-age=31536000, immutable"},
                  {name="Access-Control-Allow-Origin",value="*"},
                },
                body=b64.encode(bytes),
              })
            else
              send_cmd(c, self.session, "Fetch.fulfillRequest", {
                requestId=p.requestId, responseCode=404,
                responseHeaders={{name="Content-Type",value="text/plain"}},
                body=b64.encode("theme asset not found"),
              })
            end
          else
            send_cmd(c, self.session, "Fetch.continueRequest", {
              requestId=p.requestId,
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
          if m.method == "Runtime.executionContextCreated" and
             self.title == "SharedJSContext" and self.manager then
            self.manager.theme_reload_pending = false
            self.manager.theme_reload_deadline = nil
          end
          self.injected = false
          self.deferred_after_id = nil
          self.deferred_sent = false
          if injector.connection_plan(self.early).reinject_immediately then
            -- The early SharedJSContext connection owns only the lightweight
            -- popup hook. Keep it alive across context replacement without
            -- enabling Page, bindings or readiness probes during Steam boot.
            log("recreation early (" .. self.title .. "): " .. m.method .. " -> re-inject")
            self:_inject_once()
          else
            -- Steam can replace the renderer behind a still-open target. CDP
            -- domains are target-session state, so restore all domains before
            -- probing readiness or creating virtual theme links. In particular
            -- Fetch.enable must precede reinjection; otherwise lumen-theme.local
            -- requests fail and remain empty until Lumen is restarted.
            local plan = injector.recreation_plan(false,
              self.assets and (self.assets.virtual_provider ~= nil
                or self.assets.anonymous_web == true),
              self.assets and self.assets.bypass_csp)
            log("recreation (" .. self.title .. "): " .. m.method .. " -> restore domains + re-inject (gated)")
            if plan.runtime then send_cmd(c, self.session, "Runtime.enable") end
            if plan.page then send_cmd(c, self.session, "Page.enable") end
            if plan.bypass_csp then
              send_cmd(c, self.session, "Page.setBypassCSP", { enabled=true })
            end
            if plan.fetch then self:_enable_fetch() end
            if plan.binding then
              send_cmd(c, self.session, "Runtime.addBinding", { name = BINDING })
            end
            if plan.ready_probe then self:_probe_ready() end
            if plan.visibility_probe then self:_probe_visibility() end
          end
        end
      end
    end
  end
  if self.recovery_failed then return false end
  self:_poll_anonymous()
  return true
end

function Conn:close()
  if self.manager and self.ws_url then
    self.manager:set_view_visibility(self.ws_url, false)
  end
  if self.sock then pcall(function() self.sock:close() end) end
  self.sock = nil
end

-- ── Browser/root theme gateway ─────────────────────────────────────────────
-- Millennium owns Chromium's remote-debugging pipe, where Fetch is global.
-- Lumen deliberately stays a sidecar and only has the public debugging port,
-- so it must use the port's flattened Target sessions instead: new renderers
-- are paused, their tiny virtual-file provider is enabled, SharedJSContext gets
-- the PopupManager hook as an evaluate-on-new-document script, and only then is
-- the renderer resumed. No theme/default flash can occur in that ordering.
local BrowserConn = {}
BrowserConn.__index = BrowserConn

local function browser_conn_new(ws_url, gateway)
  return setmetatable({
    ws_url=ws_url,
    gateway=gateway,
    sock=nil,
    session=nil,
    buf="",
    sessions={},
    setup_pending={},
    setup_counts={},
    manual_pending={},
    auto_attach_id=nil,
    get_targets_id=nil,
    attaching_targets={},
    enabled=false,
    enable_failed=false,
    send_failed=false,
    setup_failed=false,
  }, BrowserConn)
end

local function shared_target(info)
  return injector.shared_theme_target(info)
end

-- Decide which browser-level setup a newly attached target needs.  Theme
-- documents can navigate inside an already-created target (Change Account is
-- the important example), so every page receives an evaluate-on-new-document
-- hook.  Workers and other non-document targets only need to be resumed.
function injector.browser_target_setup_plan(info, waiting, bypass_csp)
  local page = type(info) == "table" and info.type == "page"
  return {
    fetch = page,
    bootstrap = page,
    bypass_csp = page and bypass_csp == true,
    run_immediately = page and waiting ~= true,
  }
end

function BrowserConn:_send_child(session_id, method, params, pending)
  local id = self.session._id + 1
  if not send_cmd(self.sock, self.session, method, params, session_id) then
    self.send_failed = true
    return nil
  end
  if pending then self.setup_pending[id] = pending end
  return id
end

function BrowserConn:_resume(session_id)
  self:_send_child(session_id, "Runtime.runIfWaitingForDebugger", {})
end

function BrowserConn:_queue_setup(session_id, kind, method, params, extra)
  local pending = extra or {}
  pending.session_id = session_id
  pending.kind = kind
  local id = self:_send_child(session_id, method, params, pending)
  if id then
    self.setup_counts[session_id] = (self.setup_counts[session_id] or 0) + 1
  end
  return id
end

-- The login observer mirrors Millennium's safe discovery model: discover the
-- SharedJSContext and attach to that one target explicitly.  It never pauses
-- renderer creation and never calls Target.setAutoAttach, which CEF 126 can
-- turn into a blank or permanently loading account selector.
function BrowserConn:_consider_manual_target(info)
  if not self.gateway.login_only or not shared_target(info) then return end
  local target_id = info.targetId
  if not target_id or self.attaching_targets[target_id] then return end
  for _, state in pairs(self.sessions) do
    if state.info and state.info.targetId == target_id then return end
  end
  local id = self.session._id + 1
  if self:_send_child(nil, "Target.attachToTarget",
      {targetId=target_id, flatten=true}) then
    self.attaching_targets[target_id] = true
    self.manual_pending[id] = {kind="attach", info=info, target_id=target_id}
  end
end

function BrowserConn:_install_bootstrap(session_id, run_immediately)
  local state = self.sessions[session_id]
  if not state or state.info.type ~= "page" then return true end
  if state.script_id then
    self:_send_child(session_id, "Page.removeScriptToEvaluateOnNewDocument",
      {identifier=state.script_id})
    state.script_id = nil
  end
  state.bootstrap_source = nil
  local source = state.shared and self.gateway.shared_bootstrap_source
    or self.gateway.document_bootstrap_source
  if type(source) ~= "string" then return true end
  return self:_queue_setup(session_id, "bootstrap",
    "Page.addScriptToEvaluateOnNewDocument",
    injector.document_bootstrap_params(source, run_immediately),
    {source=source}) ~= nil
end

function BrowserConn:_setup_target(session_id, info, waiting)
  if self.sessions[session_id] then return end
  local state = {
    info=info or {},
    waiting=waiting == true,
    shared=shared_target(info),
    bypass_csp=false,
  }
  self.sessions[session_id] = state
  if state.info.type ~= "page" then
    if state.waiting then self:_resume(session_id) end
    return
  end
  if self.gateway.login_only then
    if state.shared then
      self:_send_child(session_id, "Runtime.enable", {})
      local id = self.session._id + 1
      if self:_send_child(session_id, "Runtime.evaluate", {
          expression=self.gateway.login_guard_source, returnByValue=true }) then
        self.manual_pending[id] = {kind="guard", session_id=session_id}
      end
    end
    return
  end
  local setup = injector.browser_target_setup_plan(
    state.info, state.waiting, self.gateway.bypass_csp)
  if setup.bypass_csp then
    self:_queue_setup(session_id, "csp", "Page.setBypassCSP", {enabled=true})
    state.bypass_csp = true
  end
  if setup.fetch then
    self:_queue_setup(session_id, "fetch", "Fetch.enable",
      {patterns=injector.browser_fetch_patterns(self.gateway)})
  end
  -- Existing targets need recovery now; future targets are paused before their
  -- first document and run the hook only as part of that new document.
  if setup.bootstrap then
    self:_install_bootstrap(session_id, setup.run_immediately)
  end
  local startup = injector.renderer_startup_plan(state.waiting)
  if startup.resume_after_queue then
    self:_resume(session_id)
    state.waiting = false
  end
end

function BrowserConn:_fulfill_virtual(params, session_id)
  local url = params.request and params.request.url
  local ok_asset, bytes, content_type = pcall(
    self.gateway.virtual_provider, url)
  if ok_asset and bytes then
    self:_send_child(session_id, "Fetch.fulfillRequest", {
      requestId=params.requestId,
      responseCode=200,
      responseHeaders={
        {name="Content-Type",value=content_type or "application/octet-stream"},
        {name="Cache-Control",value="public, max-age=31536000, immutable"},
        {name="Access-Control-Allow-Origin",value="*"},
      },
      body=b64.encode(bytes),
    })
  else
    self:_send_child(session_id, "Fetch.fulfillRequest", {
      requestId=params.requestId,
      responseCode=404,
      responseHeaders={{name="Content-Type",value="text/plain"}},
      body=b64.encode("theme asset not found"),
    })
  end
end

function BrowserConn:_handle_paused_request(params, session_id)
  if type(self.gateway.virtual_provider) == "function" then
    self:_fulfill_virtual(params, session_id)
  else
    self:_send_child(session_id, "Fetch.continueRequest", {
      requestId=params.requestId,
    })
  end
end

function BrowserConn:_finish_setup(message)
  local pending = self.setup_pending[message.id]
  if not pending then return false end
  self.setup_pending[message.id] = nil
  local session_id = pending.session_id
  local state = self.sessions[session_id]
  if message.kind ~= "result" then
    self.setup_failed = true
  elseif state and pending.kind == "bootstrap" then
    state.script_id = message.result and message.result.identifier
    state.bootstrap_source = pending.source
  elseif state and pending.kind == "fetch" then
    state.fetch_enabled = true
  end
  local left = math.max(0, (self.setup_counts[session_id] or 1) - 1)
  self.setup_counts[session_id] = left > 0 and left or nil
  return true
end

function BrowserConn:_handle_result(message)
  local manual = self.manual_pending[message.id]
  if manual then
    self.manual_pending[message.id] = nil
    if manual.kind == "attach" then
      self.attaching_targets[manual.target_id] = nil
      local session_id = message.result and message.result.sessionId
      if session_id then self:_setup_target(session_id, manual.info, false) end
    elseif manual.kind == "guard" then
      local state = self.sessions[manual.session_id]
      if state and state.shared then
        state.theme_sent = true
        self:_send_child(manual.session_id, "Runtime.evaluate", {
          expression=self.gateway.login_theme_source, returnByValue=true })
      end
    end
    return
  end
  if self.get_targets_id and message.id == self.get_targets_id then
    self.get_targets_id = nil
    for _, info in ipairs((message.result and message.result.targetInfos) or {}) do
      self:_consider_manual_target(info)
    end
    return
  end
  if self.auto_attach_id and message.id == self.auto_attach_id then
    self.enabled = message.kind == "result"
    self.enable_failed = not self.enabled
    return
  end
  self:_finish_setup(message)
end

function BrowserConn:_handle_event(message)
  local params = message.params or {}
  if (message.method == "Target.targetCreated"
      or message.method == "Target.targetInfoChanged") and params.targetInfo then
    self:_consider_manual_target(params.targetInfo)
  elseif message.method == "Target.attachedToTarget" then
    self:_setup_target(params.sessionId, params.targetInfo,
      params.waitingForDebugger)
  elseif message.method == "Target.detachedFromTarget" then
    self.sessions[params.sessionId] = nil
    self.setup_counts[params.sessionId] = nil
  elseif message.method == "Fetch.requestPaused" and message.session_id then
    self:_handle_paused_request(params, message.session_id)
  elseif self.gateway.login_only
      and message.method == "Runtime.executionContextsCleared"
      and message.session_id and self.sessions[message.session_id] then
    local state = self.sessions[message.session_id]
    state.theme_sent = false
    self:_send_child(message.session_id, "Runtime.evaluate", {
      expression=self.gateway.login_guard_source, returnByValue=true })
    local id = self.session._id
    self.manual_pending[id] = {kind="guard", session_id=message.session_id}
  end
end

function BrowserConn:_consume(bytes)
  if bytes and #bytes > 0 then self.buf = self.buf .. bytes end
  while true do
    local frame, opcode, rest, complete = wsframe.decode_frame(self.buf)
    if not complete then break end
    self.buf = rest
    if opcode == 0x8 then return false end
    if opcode == 0x1 then
      local ok, message = pcall(cdp.parse_message, frame)
      if ok and message then
        if message.kind == "event" then self:_handle_event(message)
        else self:_handle_result(message) end
      end
    end
  end
  return true
end

function BrowserConn:_pump(timeout)
  if self.send_failed or self.setup_failed then return false end
  self.sock:settimeout(timeout or 0)
  local chunk, err, partial = self.sock:receive(8192)
  self.sock:settimeout(0)
  local got = chunk or partial
  if got and #got > 0 and not self:_consume(got) then return false end
  return err ~= "closed" and not self.send_failed and not self.setup_failed
end

function BrowserConn:_wait_until(predicate, seconds)
  local deadline = socket.gettime() + (seconds or 2)
  while socket.gettime() < deadline do
    if predicate() then return true end
    if not self:_pump(math.min(0.05, deadline - socket.gettime())) then return false end
  end
  return predicate()
end

function BrowserConn:connect()
  local path = ws_path(self.ws_url)
  if not path then return false end
  local c = socket.tcp(); c:settimeout(5)
  if not c:connect(CEF_HOST, cef_port()) then c:close(); return false end
  if not ws_handshake(c, path) then c:close(); return false end
  c:settimeout(0)
  self.sock = c
  self.session = cdp.new_session()
  self.buf = ""
  if not send_cmd(c, self.session, "Target.setDiscoverTargets", {discover=true}) then
    self:close(false)
    return false
  end
  if not injector.browser_uses_auto_attach(self.gateway) then
    self.get_targets_id = self.session._id + 1
    if not send_cmd(c, self.session, "Target.getTargets", {}) then
      self:close(false)
      return false
    end
    self.enabled = true
    log("manual SharedJSContext theme observer attached")
    return true
  end
  self.auto_attach_id = self.session._id + 1
  if not send_cmd(c, self.session, "Target.setAutoAttach",
      injector.browser_auto_attach_params(true)) then
    self:close(false)
    return false
  end
  local ready = self:_wait_until(function()
    return self.send_failed or self.setup_failed
      or ((self.enabled or self.enable_failed)
          and next(self.setup_pending) == nil)
  end, 3)
  if not ready or not self.enabled or self.send_failed or self.setup_failed then
    self:close(false)
    return false
  end
  log("browser theme gateway attached; renderer startup gate active")
  return true
end

function BrowserConn:update_gateway(gateway)
  local old_source = self.gateway.document_bootstrap_source
  local old_shared_source = self.gateway.shared_bootstrap_source
  local old_login_guard = self.gateway.login_guard_source
  local old_login_theme = self.gateway.login_theme_source
  local old_login_only = self.gateway.login_only
  local old_bypass_csp = self.gateway.bypass_csp
  self.setup_failed = false
  self.gateway = gateway
  if old_source == gateway.document_bootstrap_source
      and old_shared_source == gateway.shared_bootstrap_source
      and old_login_guard == gateway.login_guard_source
      and old_login_theme == gateway.login_theme_source
      and old_login_only == gateway.login_only
      and old_bypass_csp == gateway.bypass_csp then return true end
  if gateway.login_only then
    for session_id, state in pairs(self.sessions) do
      if state.shared then
        local id = self.session._id + 1
        if self:_send_child(session_id, "Runtime.evaluate", {
            expression=gateway.login_guard_source, returnByValue=true }) then
          self.manual_pending[id] = {kind="guard", session_id=session_id}
        end
      end
    end
    return true
  end
  for session_id, state in pairs(self.sessions) do
    -- Prepare only. Applying in the current context would recreate the exact
    -- live-theme race this gateway exists to remove; RestartJSContext follows
    -- after registration is acknowledged.
    if state.info and state.info.type == "page" and not gateway.login_only then
      if state.bypass_csp ~= (gateway.bypass_csp == true) then
        self:_queue_setup(session_id, "csp", "Page.setBypassCSP",
          {enabled=gateway.bypass_csp == true})
        state.bypass_csp = gateway.bypass_csp == true
      end
      self:_install_bootstrap(session_id, false)
    end
  end
  local ready = self:_wait_until(function()
    if self.send_failed or self.setup_failed then return true end
    for _, state in pairs(self.sessions) do
      if state.info and state.info.type == "page" then
        local desired = state.shared and gateway.shared_bootstrap_source
          or gateway.document_bootstrap_source
        if state.bootstrap_source ~= desired
            or (state.bypass_csp == true) ~= (gateway.bypass_csp == true) then
          return false
        end
      end
    end
    return true
  end, 3)
  return ready and not self.send_failed and not self.setup_failed
end

function BrowserConn:drain()
  if self.send_failed or self.setup_failed then return false end
  local data, err, partial = self.sock:receive("*a")
  local got = data or partial
  if got and #got > 0 and not self:_consume(got) then return false end
  return err ~= "closed" and not self.send_failed and not self.setup_failed
end

function BrowserConn:close(disable)
  if disable ~= false and self.sock and self.session and self.enabled then
    for session_id, state in pairs(self.sessions) do
      if state.waiting then self:_resume(session_id) end
      if not self.gateway.login_only and state.info and state.info.type == "page" then
        self:_send_child(session_id, "Fetch.disable", {})
      end
      if state.bypass_csp then
        self:_send_child(session_id, "Page.setBypassCSP", {enabled=false})
      end
      if state.script_id then
        self:_send_child(session_id, "Page.removeScriptToEvaluateOnNewDocument",
          {identifier=state.script_id})
      end
    end
    if injector.browser_uses_auto_attach(self.gateway) then
      local disable_id = self.session._id + 1
      send_cmd(self.sock, self.session, "Target.setAutoAttach",
        injector.browser_auto_attach_params(false))
      self:_wait_until(function()
        -- The command id is consumed even though no special result state is kept.
        return self.session._id >= disable_id and next(self.setup_pending) == nil
      end, 0.25)
    end
  end
  if self.sock then pcall(function() self.sock:close() end) end
  self.sock = nil
  self.enabled = false
  self.sessions = {}
  self.setup_pending = {}
  self.setup_counts = {}
  self.manual_pending = {}
  self.attaching_targets = {}
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
    visible_views = {},  -- browser ws_url -> true, reported by visibilitychange
  }, State)
end

-- Track the steamwebhelper generation through SharedJSContext's websocket
-- identity. Change Account tears the helper down and starts a fresh one; if we
-- keep ui_ready latched from the dead generation, the new SharedJSContext gets
-- the full readiness-gated connection and its login window paints before the
-- theme popup hook is installed. Resetting here makes the existing cold-boot
-- path attach the lightweight hook immediately, before Steam creates that
-- window. No work is added while the websocket identity remains stable.
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
  self.visible_views = {}
  self.shared_ws_url = current
  self.ui_ready = false
  self.early_grace_deadline = nil
  self.theme_reload_pending = nil
  self.theme_reload_deadline = nil
  self.backoff = 1
  self.next_attempt = 0
  return true
end

function State:idle_delay()
  if self:needs_fast_tick() then return 0.01 end
  return self.ui_ready and 1 or injector.discovery_retry_delay(false, self.backoff)
end

function State:needs_fast_tick()
  for _, conn in pairs(self.conns) do
    if conn.requests and next(conn.requests) ~= nil then return true end
  end
  return false
end

-- Keep one global provider only while a custom theme is active. Switching
-- between themes updates its provider atomically without a Fetch gap; disabling
-- themes explicitly disables Fetch and closes the root socket before reload.
function State:_sync_browser_gateway()
  local desired = injector.theme_gateway_config(self.channels, self.ui_ready)
    or injector.login_theme_gateway(self.channels, self.ui_ready)
  if not desired then
    if self.browser_conn then
      self.browser_conn:close(true)
      self.browser_conn = nil
      log("browser theme gateway disabled")
    end
    return true
  end
  if self.browser_conn and self.browser_conn.sock and self.browser_conn.enabled then
    local updated = self.browser_conn:update_gateway(desired)
    if not updated then
      self.browser_conn:close(false)
      self.browser_conn = nil
    end
    return updated
  end
  if self.browser_conn then self.browser_conn:close(false); self.browser_conn = nil end
  local ws_url = browser_ws_url()
  if not ws_url then return false end
  local conn = browser_conn_new(ws_url, desired)
  if not conn:connect() then return false end
  self.browser_conn = conn
  return true
end

-- fds() -> array of currently-open CDP sockets for select().
function State:fds()
  local out = {}
  if self.browser_conn and self.browser_conn.sock then
    out[#out + 1] = self.browser_conn.sock
  end
  for _, conn in pairs(self.conns) do
    if conn.sock then out[#out + 1] = conn.sock end
  end
  return out
end

-- Replace routing after a live theme setting change. Closing the CDP sockets is
-- intentional: rediscovery rebuilds each connection with the new composed
-- asset set, and RestartJSContext then starts from a clean theme JS context.
function State:set_channels(channels, preserve_control)
  for url, conn in pairs(self.conns) do
    if preserve_control and conn.title == "SharedJSContext" then
      -- Keep only the transport needed to call RestartJSContext. If the old
      -- assets remain here, its executionContextCreated handler re-injects the
      -- previous theme into the brand-new context before rediscovery replaces
      -- the route, producing a visible old/default/new sequence.
      conn.assets = nil
    else
      conn:close(); self.conns[url] = nil
    end
  end
  self.channels = channels or {}
  self.next_attempt = 0
  return self:_sync_browser_gateway()
end

function State:queue_channels(channels)
  self.pending_channels = channels
end

function State:commit_pending_channels()
  if not self.pending_channels then return false end
  local pending = self.pending_channels
  self.pending_channels = nil
  local transition = injector.theme_transition_expr()
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title ~= "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate", {expression=transition})
    end
  end
  if not self:set_channels(pending, true) then
    log("theme reload postponed: browser gateway was not ready")
    return false
  end
  self.theme_reload_pending = true
  self.theme_reload_deadline = os.time() + 5
  return true
end

function State:_sync_targets(targets, channels, early)
  local routed = injector.route_targets_with_recovery(targets, channels)
  for _, r in ipairs(routed) do
    local t = r.target
    local existing = self.conns[t.webSocketDebuggerUrl]
    if existing then
      local old, new = existing.assets or {}, r.assets or {}
      local changed = #(old.js or {}) ~= #(new.js or {})
        or #(old.css or {}) ~= #(new.css or {})
        or #(old.deferred_js or {}) ~= #(new.deferred_js or {})
        or (old.polyfill ~= nil) ~= (new.polyfill ~= nil)
        or (old.virtual_provider ~= nil) ~= (new.virtual_provider ~= nil)
        or (old.anonymous_web == true) ~= (new.anonymous_web == true)
        or existing.browser_target ~= (r.browser == true)
        or existing.early ~= (early == true)
        or existing.recovery_route ~= (r.recovery == true)
      if changed then
        log("routing changed: " .. tostring(existing.title) .. " -> " .. tostring(t.title))
        existing:close(); self.conns[t.webSocketDebuggerUrl] = nil; existing = nil
      end
    end
    if not existing then
      local conn = conn_new(t, r.assets, self.registry, self, r.browser, early,
        r.recovery)
      if conn:connect() then self.conns[t.webSocketDebuggerUrl] = conn end
    end
  end
end

-- Discover wanted targets and connect to any not yet connected (backoff-gated).
function State:_discover()
  local now = socket.gettime()
  if self.theme_reload_pending then
    if now < (self.theme_reload_deadline or 0) then return end
    -- If Steam replaced the SharedJSContext socket instead of emitting its
    -- recreation event, do not deadlock discovery indefinitely.
    self.theme_reload_pending = false
    self.theme_reload_deadline = nil
  end
  if now < self.next_attempt then return end
  local targets, err = list_all_targets()
  if not targets then
    self.next_attempt = now + injector.discovery_retry_delay(self.ui_ready, self.backoff)
    if self.ui_ready then self.backoff = math.min(self.backoff * 2, 15)
    else self.backoff = 1 end
    return
  end
  self.backoff = 1
  self.next_attempt = 0
  if self:observe_shared_generation(targets) then
    log("new SharedJSContext generation -> returning to early bootstrap")
  end
  if not self.ui_ready then
    -- Always install the SharedJSContext popup hook first, even when the first
    -- /json snapshot already contains ready markers. A short grace tick lets
    -- its Runtime.evaluate reach CEF before full routing promotes the socket.
    local early = {}
    for _, ch in ipairs(self.channels) do if ch.early then early[#early+1] = ch end end
    if #early > 0 then self:_sync_targets(targets, early, true) end
    local ready = false
    for _, t in ipairs(targets) do
      local hay = (t.title or "") .. " " .. (t.url or "")
      for _, mark in ipairs(READY_MARKERS) do
        if hay:find(mark, 1, true) then ready = true; break end
      end
      if ready then break end
    end
    if not ready then
      self.next_attempt = now + injector.discovery_retry_delay(false, self.backoff)
      return
    end
    local have_early = false
    for _, conn in pairs(self.conns) do if conn.early then have_early = true; break end end
    if have_early and not self.early_grace_deadline then
      self.early_grace_deadline = now + injector.discovery_retry_delay(false, self.backoff)
      self.next_attempt = self.early_grace_deadline
      return
    end
    self.early_grace_deadline = nil
    self.ui_ready = true
    log("Steam UI ready -> attaching full channel set")
  end
  -- Route each target to its channel's assets (store web views -> luatools.js;
  -- SharedJSContext -> lumen-menu bundle). First matching channel wins.
  self:_sync_targets(targets, self.channels)
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

-- Reload only Steam's JavaScript/UI contexts. Theme changes use this instead
-- of restarting the Steam client, so downloads and running games are untouched.
function State:restart_js_context()
  local expr = "(function(){try{if(window.SteamClient&&SteamClient.Browser&&" ..
    "typeof SteamClient.Browser.RestartJSContext==='function'){" ..
    "SteamClient.Browser.RestartJSContext();return true;}return false;}catch(e){return false;}})()"
  for _, conn in pairs(self.conns) do
    if conn.sock and conn.title == "SharedJSContext" then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        { expression=expr, returnByValue=true })
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
        { expression = "(!document.hidden)&&(" .. expr .. ")", returnByValue = true })
    end
  end
  -- Hidden browser targets remain in /json after navigating back to Library,
  -- so target presence cannot identify the composited top view. Broadcast a
  -- visibility-guarded expression instead: hidden Store/Community documents
  -- no-op, while the visible browser view (or the Library shell) opens it.
  -- Opening in both a visible shell and visible composited browser is harmless:
  -- the browser copy is physically above and receives input.
  for _, conn in pairs(self.conns) do fire(conn) end
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
  local opened = false
  for ws_url, visible in pairs(self.visible_views) do
    local conn = visible and self.conns[ws_url] or nil
    if conn and conn.sock then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        {expression="window.__lumenOpenOverlay&&window.__lumenOpenOverlay()",
         returnByValue=true})
      opened = true
    end
  end
  if not opened then self:_open_shell_overlay() end
end

function State:set_view_visibility(ws_url, visible)
  if visible then self.visible_views[ws_url] = true
  else self.visible_views[ws_url] = nil end
end

function State:_open_shell_overlay()
  local expr = "window.__lumenOpenOverlay&&window.__lumenOpenOverlay()"
  for _, conn in pairs(self.conns) do
    local u = conn.url or ""
    if conn.sock and (conn.title == "Steam" or u:find("browserType=4",1,true)) then
      send_cmd(conn.sock, conn.session, "Runtime.evaluate",
        {expression=expr,returnByValue=true})
      return
    end
  end
end

-- Show the "slsteam-moon not loaded" warning in whichever view is on top, so it
-- renders in front of the store/community web view when one is composited above
-- the shell (otherwise it would be hidden behind it — the store-in-front bug).
function State:broadcast_sls_warn()
  self:_fire_on_top("window.__lumenShowSlsWarn&&window.__lumenShowSlsWarn()")
end

-- tick(): connect to new targets, drain existing ones, drop closed ones.
function State:tick()
  self:_sync_browser_gateway()
  if self.browser_conn and self.browser_conn.sock then
    if not self.browser_conn:drain() then
      log("browser theme gateway closed (will re-attach)")
      self.browser_conn:close(false)
      self.browser_conn = nil
    end
  end
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
