-- Run: lua5.4 tools/test_inject.lua
-- Regression: the LuaTools webkit frontend must be injected ONLY into web-view
-- targets (store/community), NEVER into SharedJSContext (the main Steam client
-- shell). Injecting the webkit script into SharedJSContext breaks the native
-- top menubar (Steam/View/Friends/Games/Help), because that script monkey-
-- patches history.pushState, attaches a document.body MutationObserver, and
-- runs periodic DOM scans that the React shell never expects. Millennium only
-- ever loaded luatools.js into WebKit (web view) contexts via add_browser_js.
package.path = "lua/?.lua;" .. package.path
local cdp = require("cdp")
local injector = require("injector")

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end

do
  local f = assert(io.open("lua/boot.lua", "r"))
  local source = f:read("*a")
  f:close()
  assert_true(source:find("refresh_parental_unlock", 1, true),
    "boot can refresh the parental gateway state in memory")
  assert_true(source:find("on_steam_returned", 1, true),
    "parental state is refreshed once when Steam returns")
  assert_true(not source:find('require("themeengine")', 1, true),
    "main branch keeps theme infrastructure out of boot")
  assert_true(not source:find('require("themepreload")', 1, true),
    "main branch keeps theme preload out of boot")
  local offers_pos = source:find(
    'store.steampowered.com/marketingmessages/list', 1, true)
  local store_pos = source:find(
    '{ urls = { "store.steampowered.com", "steamcommunity.com" }', 1, true)
  assert_true(offers_pos and store_pos and offers_pos < store_pos
      and source:find("__lumenOffersUnlock", 1, true)
      and source:find('data-featuretarget="store-menu-v7"', 1, true),
    "authenticated offers use an isolated channel before the LuaTools webview channel")
end

do
  local f = assert(io.open("lua/loop.lua", "r"))
  local source = f:read("*a")
  f:close()
  assert_true(source:find("steam_returned", 1, true)
      and source:find("opts.on_steam_returned", 1, true),
    "loop forwards the one-shot Steam return event")
  local lifecycle_pos =
    source:find("local should_exit, steam_returned", 1, true)
  local injector_pos = source:find("inj:tick()", 1, true)
  assert_true(lifecycle_pos and injector_pos and lifecycle_pos < injector_pos,
    "Steam return refresh runs before injector gateway synchronization")
  assert_true(source:find("inj:needs_fast_tick()", 1, true)
      and source:find("0.01", 1, true),
    "loop polls quickly only while an asynchronous browser request is pending")
end

local SAMPLE = {
  { title = "Steam",           url = "about:blank",                          webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/A" },
  { title = "SharedJSContext", url = "https://steamloopback.host/index.html", webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/B" },
  { title = "Welcome to Steam",url = "https://store.steampowered.com/",      webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/C" },
  { title = "Community",       url = "https://steamcommunity.com/app/440",   webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/D" },
  { title = "Friends",         url = "https://steamcommunity.com/chat",      webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/E" },
}

-- select_targets(targetsList, wantedTitles, wantedUrlFragments) is the pure
-- matcher the injector uses to decide which CEF targets receive the assets.
assert_true(type(cdp.select_targets) == "function",
  "cdp exposes select_targets for testing")

-- 1. With the production config (no title targets, URL-matched web views), the
--    matcher must pick the store/community web views and EXCLUDE SharedJSContext.
do
  local picked = cdp.select_targets(SAMPLE, {}, { "store.steampowered.com", "steamcommunity.com" })
  local byurl = {}
  for _, t in ipairs(picked) do byurl[t.webSocketDebuggerUrl] = true end
  assert_true(byurl["ws://localhost:8080/devtools/page/C"], "store web view selected")
  assert_true(byurl["ws://localhost:8080/devtools/page/D"], "community app view selected")
  for _, t in ipairs(picked) do
    assert_true(t.title ~= "SharedJSContext",
      "SharedJSContext must NOT be selected for frontend injection")
  end
end

-- 2. A target without a webSocketDebuggerUrl is never selectable.
do
  local list = {
    { title = "store", url = "https://store.steampowered.com/", },  -- no ws url
  }
  local picked = cdp.select_targets(list, {}, { "store.steampowered.com" })
  assert_true(#picked == 0, "targets without a ws url are skipped")
end

-- 3. Title matching still works for explicit title targets (kept for generality).
do
  local picked = cdp.select_targets(SAMPLE, { ["Friends"] = true }, nil)
  assert_true(#picked == 1 and picked[1].title == "Friends", "explicit title match works")
end

-- 4. route_targets(): assigns each matched target the assets of the FIRST
--    channel it matches, so the store web views get luatools.js while
--    SharedJSContext gets a DIFFERENT (lumen-menu) bundle — and never the
--    reverse. This is what lets the menu live in the shell without ever
--    putting the invasive webkit script there.
do
  assert_true(type(cdp.route_targets) == "function", "cdp exposes route_targets")
  local LUATOOLS = { js = { "luatools" } }
  local MENU = { js = { "lumenmenu" } }
  local channels = {
    { urls = { "store.steampowered.com", "steamcommunity.com" }, assets = LUATOOLS },
    { titles = { ["SharedJSContext"] = true }, assets = MENU },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local by = {}
  for _, r in ipairs(routed) do by[r.target.webSocketDebuggerUrl] = r.assets end
  -- store + community web views -> luatools bundle
  assert_true(by["ws://localhost:8080/devtools/page/C"] == LUATOOLS, "store gets luatools assets")
  assert_true(by["ws://localhost:8080/devtools/page/D"] == LUATOOLS, "community gets luatools assets")
  -- SharedJSContext -> menu bundle, NEVER luatools
  assert_true(by["ws://localhost:8080/devtools/page/B"] == MENU, "SharedJSContext gets menu assets")
  -- the bare "Steam" (about:blank) target matches nothing -> not routed
  assert_true(by["ws://localhost:8080/devtools/page/A"] == nil, "unmatched target not routed")
end

-- 5. route_targets(): a target matching two channels takes the FIRST channel's
--    assets (deterministic precedence), and is routed only once.
do
  local A = { id = "a" }
  local B = { id = "b" }
  local channels = {
    { titles = { ["SharedJSContext"] = true }, assets = A },
    { titles = { ["SharedJSContext"] = true }, assets = B },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local count, picked = 0, nil
  for _, r in ipairs(routed) do
    if r.target.title == "SharedJSContext" then count = count + 1; picked = r.assets end
  end
  assert_true(count == 1, "matched target routed exactly once")
  assert_true(picked == A, "first channel wins")
end

-- 6. route_targets passes through a channel's `control` flag so the manager can
--    tell which connection is the SharedJSContext control link (no assets).
do
  local channels = {
    { titles = { ["SharedJSContext"] = true }, control = true },
    { urls = { "store.steampowered.com" }, assets = { js = { "x" } } },
  }
  local routed = cdp.route_targets(SAMPLE, channels)
  local ctrl
  for _, r in ipairs(routed) do
    if r.target.title == "SharedJSContext" then ctrl = r end
  end
  assert_true(ctrl ~= nil and ctrl.control == true, "control flag passed through")
end

-- 7. validate_app_expr(): builds the JS that asks the Steam client to verify a
--    game's files. It must be relayed into SharedJSContext (the only context
--    with SteamClient), so we drive Steam's own steam://validate handler via
--    SteamClient.URL.ExecuteSteamURL rather than navigating window.location
--    (which would blow away the shell when the overlay is in the main window).
do
  assert_true(type(injector.validate_app_expr) == "function",
    "injector exposes validate_app_expr for testing")
  local expr = injector.validate_app_expr(250900)
  assert_true(expr:find("steam://validate/250900", 1, true) ~= nil,
    "expr targets steam://validate/<appid>")
  assert_true(expr:find("ExecuteSteamURL", 1, true) ~= nil,
    "expr drives the Steam URL handler via SteamClient")
  assert_true(expr:find("try", 1, true) ~= nil and expr:find("catch", 1, true) ~= nil,
    "expr is wrapped in try/catch so a missing API can't throw")
  -- appid is coerced to an integer: nothing user-controlled is interpolated.
  -- A malformed value can't parse as a number, so it falls back to 0 (safe) and
  -- the injected JS never makes it into the expression.
  local inj = injector.validate_app_expr("250900'); alert(1); //")
  assert_true(inj:find("alert", 1, true) == nil, "injected JS is not interpolated")
  assert_true(inj:find("steam://validate/0", 1, true) ~= nil,
    "a malformed appid coerces to 0, not the attacker tail")
  local zero = injector.validate_app_expr("not a number")
  assert_true(zero:find("steam://validate/0", 1, true) ~= nil,
    "a non-numeric appid coerces to 0")
end

-- 7b. uninstall_app_expr(): same relay shape as validate, but drives
--     steam://uninstall/<appid> (Steam's own uninstall flow). Used when a build
--     is pinned for an INSTALLED game: a verify can't switch the installed
--     build (zero chunk delta), so the game must be uninstalled + reinstalled.
do
  assert_true(type(injector.uninstall_app_expr) == "function",
    "injector exposes uninstall_app_expr for testing")
  local expr = injector.uninstall_app_expr(250900)
  assert_true(expr:find("steam://uninstall/250900", 1, true) ~= nil,
    "expr targets steam://uninstall/<appid>")
  assert_true(expr:find("ExecuteSteamURL", 1, true) ~= nil,
    "expr drives the Steam URL handler via SteamClient")
  assert_true(expr:find("try", 1, true) ~= nil and expr:find("catch", 1, true) ~= nil,
    "expr is wrapped in try/catch so a missing API can't throw")
  local inj = injector.uninstall_app_expr("250900'); alert(1); //")
  assert_true(inj:find("alert", 1, true) == nil, "injected JS is not interpolated")
  assert_true(inj:find("steam://uninstall/0", 1, true) ~= nil,
    "a malformed appid coerces to 0, not the attacker tail")
end

-- 7d. open_library_app_expr(): opens a game's library page (Game Updates card
--     click), relayed via SharedJSContext's SteamClient. Same shape/safety as
--     validate; appid coerced to an int.
do
  assert_true(type(injector.open_library_app_expr) == "function",
    "injector exposes open_library_app_expr for testing")
  local expr = injector.open_library_app_expr(1054490)
  assert_true(expr:find("steam://nav/games/details/1054490", 1, true) ~= nil,
    "expr targets steam://nav/games/details/<appid>")
  assert_true(expr:find("ExecuteSteamURL", 1, true) ~= nil,
    "expr drives the Steam URL handler via SteamClient")
  local inj = injector.open_library_app_expr("1054490'); alert(1); //")
  assert_true(inj:find("alert", 1, true) == nil, "injected JS is not interpolated")
  assert_true(inj:find("steam://nav/games/details/0", 1, true) ~= nil,
    "a malformed appid coerces to 0")
end

-- 7e. open_external_url_expr(): opens an external URL (the Cloud Saves OAuth
--     page) in the default browser via Steam's OWN handler, relayed through
--     SharedJSContext's SteamClient — so the browser comes to the foreground
--     (a bare sidecar xdg-open can't raise a window under Wayland). Tries
--     OpenInSystemBrowser, falls back to steam://openurl_external. The URL is a
--     JS string literal so it can't break out of the expression.
do
  assert_true(type(injector.open_external_url_expr) == "function",
    "injector exposes open_external_url_expr for testing")
  local expr = injector.open_external_url_expr("https://accounts.google.com/o/oauth2/v2/auth?x=1&y=2")
  assert_true(expr:find("OpenInSystemBrowser", 1, true) ~= nil,
    "prefers SteamClient.System.OpenInSystemBrowser")
  assert_true(expr:find("steam://openurl_external/", 1, true) ~= nil,
    "falls back to steam://openurl_external")
  assert_true(expr:find("accounts.google.com", 1, true) ~= nil, "carries the URL")
  assert_true(expr:find("try", 1, true) ~= nil and expr:find("catch", 1, true) ~= nil,
    "wrapped in try/catch so a missing API can't throw")
  -- The URL is emitted as a JS string literal; a quote in it must be escaped,
  -- not able to break out and inject code.
  local inj = injector.open_external_url_expr("https://x/\"); alert(1); //")
  assert_true(inj:find("alert(1)", 1, true) == nil or inj:find('\\"', 1, true) ~= nil,
    "a quote in the URL is escaped, not interpolated raw")
end

-- 8. dispatch_method(): the binding handler's registry lookup. A regression
--    here (dropping the registry lookup) makes EVERY backend RPC come back as
--    "unknown method", which is exactly what broke the menu once.
do
  assert_true(type(injector.dispatch_method) == "function",
    "injector exposes dispatch_method for testing")
  local registry = {
    GetSlsConfig = function() return '{"success":true,"values":{}}' end,
    Echo = function(a) return { got = a } end,
  }
  local r = injector.dispatch_method(registry, "GetSlsConfig", {})
  assert_true(r:find('"success":true', 1, true) ~= nil,
    "a registered method is dispatched and its result returned")
  local u = injector.dispatch_method(registry, "GetGameUpdates", {})
  assert_true(u:find("unknown method: GetGameUpdates", 1, true) ~= nil,
    "an unregistered method returns a clear unknown-method error")
  local n = injector.dispatch_method(nil, "Anything", {})
  assert_true(n:find("unknown method", 1, true) ~= nil,
    "a nil registry doesn't throw, just reports unknown")
end

-- 9. Public Store/Community fallback is post-login, accepts only the exact
--    HTTPS hosts, runs on each page connection (never browser-wide), strips
--    credentials, and rejects unsafe/non-HTML responses.
do
  assert_true(type(injector.page_fetch_patterns) == "function",
    "injector exposes page-scoped Fetch routing")
  local patterns = injector.page_fetch_patterns({ anonymous_web = true })
  assert_true(#patterns == 2
      and patterns[1].resourceType == "Document"
      and patterns[2].resourceType == "Document",
    "page connection intercepts only Store and Community documents")
  assert_true(injector.page_recovery_url(
      "https://store.steampowered.com/?snr=client")
      == "https://store.steampowered.com/?snr=client"
      and injector.page_recovery_url("data:text/html,error", {
        { url = "https://store.steampowered.com/app/440" },
        { url = "data:text/html,error" },
      }, 1) == "https://store.steampowered.com/app/440"
      and injector.page_recovery_url("data:text/html,error", {
        { url = "https://example.com/" },
        { url = "data:text/html,error" },
      }, 1) == nil
      and injector.page_recovery_url("https://example.com/") == nil,
    "page recovery uses only an allowlisted original or history document")

  local recovery_assets = { anonymous_web = true }
  local recovery_routes = injector.route_targets_with_recovery({
    { title = "Error", type = "page", url = "data:text/html,error",
      webSocketDebuggerUrl = "ws://localhost/devtools/page/recovery" },
    { title = "Unrelated", type = "page", url = "data:text/html,other",
      webSocketDebuggerUrl = "ws://localhost/devtools/page/unrelated" },
  }, {{ urls = { "store.steampowered.com" }, assets = recovery_assets }})
  assert_true(#recovery_routes == 1
      and recovery_routes[1].recovery == true
      and recovery_routes[1].assets == recovery_assets,
    "only a recognizable failed webview receives history-based recovery")
  assert_true(injector.recovery_allows_event(true, "Fetch.requestPaused")
      and not injector.recovery_allows_event(true, "Page.loadEventFired")
      and not injector.recovery_allows_event(true, "Page.frameNavigated")
      and not injector.recovery_allows_event(true, "Runtime.bindingCalled")
      and injector.recovery_allows_event(false, "Page.frameNavigated"),
    "recovery-only connections cannot bind or inject before history approval")
  assert_true(injector.recovery_navigation_needs_reroute(true, {
        url = "https://store.steampowered.com/",
      })
      and injector.recovery_navigation_needs_reroute(true, {
        url = "https://store.steampowered.com/marketingmessages/list/",
      })
      and not injector.recovery_navigation_needs_reroute(true, {
        url = "data:text/html,<body></body>",
      })
      and not injector.recovery_navigation_needs_reroute(true, {
        url = "https://store.steampowered.com/", parentId = "child",
      })
      and not injector.recovery_navigation_needs_reroute(false, {
        url = "https://store.steampowered.com/",
      }),
    "a reused recovery target is rediscovered under its final page channel")
  assert_true(injector.recovery_fetch_error_needs_retry(true, nil)
      and injector.recovery_fetch_error_needs_retry(false,
        "https://store.steampowered.com/")
      and not injector.recovery_fetch_error_needs_retry(false, nil),
    "Fetch failure retries both before and after history approval")

  local f = assert(io.open("lua/injector.lua", "r"))
  local source = f:read("*a")
  f:close()
  assert_true(not source:find("Target.setAutoAttach", 1, true),
    "parental fallback never attaches a debugger to the whole CEF browser")
  assert_true(source:find("function Conn:_start_anonymous_request", 1, true)
      and source:find('m.method == "Fetch.requestPaused"', 1, true),
    "page connection owns the asynchronous public document fallback")

  local state = injector.new({ channels = {} })
  assert_true(state:needs_fast_tick() == false,
    "injector stays on the idle cadence without pending browser requests")
  state.conns.example = { requests = { document = {} } }
  assert_true(state:needs_fast_tick() == true,
    "injector requests a fast cadence only during a pending browser request")

  local old_closed = false
  state.ui_ready = true
  state.shared_ws_url = "ws://localhost/devtools/page/old-shared"
  state.conns.example = { close = function() old_closed = true end }
  assert_true(state:observe_shared_generation({{
      title = "SharedJSContext", type = "page",
      webSocketDebuggerUrl = "ws://localhost/devtools/page/new-shared",
    }}) == true and old_closed and state.ui_ready == false
      and next(state.conns) == nil,
    "new webhelper generation resets readiness before attaching after restart")

  assert_true(injector.anonymous_web_url("https://store.steampowered.com/app/440")
      and injector.anonymous_web_url("https://steamcommunity.com/app/440")
      and not injector.anonymous_web_url(
        "https://store.steampowered.com/marketingmessages/list/?include_seen=1")
      and not injector.anonymous_web_url("https://store.steampowered.com.evil.test/")
      and not injector.anonymous_web_url("http://store.steampowered.com/")
      and not injector.anonymous_web_url("https://help.steampowered.com/"),
    "public gateway accepts the two exact HTTPS hosts except authenticated offers")

  local public_headers = injector.anonymous_request_headers({
    ["User-Agent"] = "Valve Steam Client",
    Cookie = "secret",
    Authorization = "token",
    ["Accept-Language"] = "en-US",
    ["Accept-Encoding"] = "gzip",
    ["X-Steam-SessionID"] = "session",
  })
  local joined = table.concat(public_headers, "\n"):lower()
  assert_true(joined:find("user%-agent: valve steam client")
      and joined:find("accept%-language: en%-us")
      and not joined:find("cookie", 1, true)
      and not joined:find("authorization", 1, true)
      and not joined:find("session", 1, true)
      and not joined:find("accept%-encoding"),
    "public request preserves presentation headers without credentials")

  local html_plan = injector.anonymous_response_plan({
    status = 200,
    body = "<html></html>",
    content_type = "text/html; charset=UTF-8",
  })
  assert_true(html_plan and html_plan.action == "document",
    "public HTML is accepted")
  local redirect_plan = injector.anonymous_response_plan({
    status = 302,
    body = "",
    redirect_url = "https://steamcommunity.com/",
  })
  assert_true(redirect_plan and redirect_plan.action == "redirect",
    "safe redirect is returned to CEF for another validated interception")
  assert_true(injector.anonymous_response_plan({
      status = 302, body = "", redirect_url = "https://example.com/",
    }) == nil,
    "cross-host redirects are rejected")
  assert_true(injector.anonymous_response_plan({
      status = 302, body = "", redirect_url = "http://store.steampowered.com/",
    }) == nil,
    "redirect downgrades are rejected")
  assert_true(injector.anonymous_response_plan({
      status = 200, body = "binary", content_type = "application/octet-stream",
    }) == nil,
    "non-HTML documents are rejected")
end

print("test_inject: ALL PASS")
