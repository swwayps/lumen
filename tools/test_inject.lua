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
  local file = assert(io.open("lua/boot.lua", "r"))
  local source = file:read("*a"); file:close()
  assert_true(source:find("delete window.__lumenThemePaletteSeed", 1, true),
    "disabling themes clears the cross-context palette seed")
  assert_true(source:find('os.getenv("LUMEN_THEME_PRELOAD_ONLY") == "1"', 1, true)
      and source:find('early_preload.stage(early_runtime)', 1, true)
      and source:find('early_preload.sync(nil)', 1, true)
      and source:find("os.exit(early_runtime and 10 or 0)", 1, true),
    "preflight cleans the verified index and stages helpers outside SteamUI")
  assert_true(source:find('os.getenv("LUMEN_THEME_PRELOAD_ACTIVE") == "1"', 1, true),
    "CDP is skipped only when the launcher also enabled Steam's loose-file override")
  assert_true(source:find('local themepreload = require("themepreload")', 1, true)
      and source:find("themepreload.stage(runtime)", 1, true)
      and source:find("if preload_ok and clean_previous then", 1, true),
    "boot stages initial helpers and commits only during an in-session reload")
  assert_true(source:find("if not preloaded then", 1, true)
      and source:find("js={runtime.popup_guard_hook},", 1, true)
      and source:find("deferred_js={runtime.popup_hook}", 1, true),
    "CDP retains an ordered fallback only when the file preloader is unavailable")
  assert_true(source:find("login_browser_gateway=true", 1, true)
      and source:find("login_guard_source=runtime.popup_guard_hook", 1, true)
      and source:find("login_theme_source=runtime.popup_hook", 1, true),
    "cold boot exposes both ordered hooks to the manual browser observer")
  assert_true(source:find("js={runtime.popup_hook}", 1, true),
    "normal SharedJSContext routing installs the complete popup theme hook")
  assert_true(source:find("anonymous_web=parental_unlock_enabled", 1, true),
    "parental unlock enables anonymous Store/Community documents")
  assert_true(source:find("refresh_parental_unlock", 1, true),
    "boot can refresh the parental gateway state in memory")
  assert_true(source:find("on_steam_returned", 1, true),
    "parental state is refreshed once when Steam returns")
  assert_true(not source:find('require("parentalunlock")', 1, true),
    "native parental state no longer needs a SharedJSContext visual patch")
  local injector_file = assert(io.open("lua/injector.lua", "r"))
  local injector_source = injector_file:read("*a"); injector_file:close()
  assert_true(injector_source:find("pcall(http.start", 1, true)
      and injector_source:find("function Conn:_poll_anonymous()", 1, true),
    "public documents use a page-scoped polled request without blocking CDP")
  local offers_pos = source:find(
    'store.steampowered.com/marketingmessages/list', 1, true)
  local store_pos = source:find(
    '{ urls = { "store.steampowered.com", "steamcommunity.com" }', 1, true)
  assert_true(offers_pos and store_pos and offers_pos < store_pos
      and source:find("__lumenOffersUnlock", 1, true)
      and source:find('data-featuretarget="store-menu-v7"', 1, true),
    "authenticated offers use an isolated channel before the LuaTools webview channel")
end

-- A cold-boot theme hook must reach SharedJSContext before Steam creates its
-- first popup, without enabling the heavier Page/binding/ready-probe machinery
-- that previously stalled or blanked startup. Once the shell is ready the
-- connection is replaced by the normal full channel.
do
  assert_true(type(injector.connection_plan) == "function",
    "injector exposes the connection plan used by CDP connections")
  local early = injector.connection_plan(true)
  assert_true(early.runtime == true and early.inject_immediately == true
      and early.reinject_immediately == true,
    "early connection evaluates its hook immediately, including after recreation")
  assert_true(not early.page and not early.binding and not early.ready_probe
      and not early.visibility_probe and not early.fetch,
    "early connection does not activate heavyweight boot-time CDP domains")
  local full = injector.connection_plan(false)
  assert_true(full.runtime and full.page and full.binding and full.ready_probe,
    "normal connection retains the complete injector setup")
  local themed_full = injector.connection_plan(false, true)
  assert_true(themed_full.bypass_csp == true,
    "a themed connection enables CSP bypass before loading theme JavaScript")
  assert_true(not injector.connection_plan(false, false).bypass_csp,
    "an ordinary connection does not weaken CSP")
  assert_true(type(injector.discovery_retry_delay) == "function"
      and injector.discovery_retry_delay(false, 15) <= 0.25,
    "cold boot polls fast enough to observe SharedJSContext before first paint")
end

-- Changing account restarts steamwebhelper: the SharedJSContext websocket gets
-- a new identity, then the login popup is created roughly one second later.
-- A manager that stays latched in full/UI-ready mode misses that pre-paint
-- window and applies the theme several seconds after the default UI is shown.
-- A new SharedJSContext generation must therefore return discovery to the
-- lightweight early-hook phase and discard connections from the dead helper.
do
  local state = injector.new({channels={}, registry={}})
  local stale_closed = false
  state.ui_ready = true
  state.shared_ws_url = "ws://localhost:8080/devtools/page/OLD"
  state.early_grace_deadline = 99
  state.theme_reload_pending = true
  state.theme_reload_deadline = 99
  state.conns[state.shared_ws_url] = { close=function() stale_closed=true end }
  assert_true(type(state.observe_shared_generation) == "function",
    "injector state exposes SharedJSContext generation tracking")
  local changed = state:observe_shared_generation({{
    title="SharedJSContext",
    webSocketDebuggerUrl="ws://localhost:9090/devtools/page/NEW",
  }})
  assert_true(changed == true, "a replaced SharedJSContext is a new bootstrap generation")
  assert_true(state.ui_ready == false,
    "new SharedJSContext returns discovery to the early-hook phase")
  assert_true(stale_closed and next(state.conns) == nil,
    "connections owned by the dead webhelper generation are discarded")
  assert_true(state.early_grace_deadline == nil and state.theme_reload_pending == nil,
    "old generation timing gates cannot delay the new early hook")
end

-- Steam replaces the renderer context of pre-created popup targets during
-- boot. Every target-scoped CDP domain required by theme delivery must be
-- restored before links are injected into that new context; otherwise the
-- virtual stylesheet requests fail until Lumen itself is restarted.
do
  assert_true(type(injector.recreation_plan) == "function",
    "injector exposes its renderer-recreation plan")
  local themed = injector.recreation_plan(false, true, true)
  assert_true(themed.page and themed.fetch and themed.binding and themed.ready_probe
      and themed.bypass_csp,
    "themed renderer recreation restores CSP/Fetch before reinjection")
  local ordinary = injector.recreation_plan(false, false)
  assert_true(ordinary.page and not ordinary.fetch and ordinary.binding,
    "ordinary renderer recreation avoids an unnecessary Fetch domain")
  local early = injector.recreation_plan(true, true)
  assert_true(early.reinject_immediately and not early.fetch and not early.binding,
    "early popup hook remains lightweight during recreation")
end

do
  local expr = injector.theme_transition_expr()
  assert_true(expr:find("lumen%-theme%-transition") ~= nil,
    "theme reload transition has a stable cleanup id")
  assert_true(expr:find("8s", 1, true) ~= nil and expr:find("@keyframes", 1, true) ~= nil,
    "theme reload transition has a fail-safe timeout")
end

-- Theme delivery must be installed on the browser-level CDP endpoint before
-- Steam creates any renderer target. This is what makes virtual font/image
-- requests available to login popups and lets the SharedJSContext hook enter
-- the document before the first themed window can paint. With no active theme
-- there is no gateway config (and therefore no browser Fetch overhead).
do
  local provider = function() return "asset", "font/woff2" end
  local themed = {{all=true, compose=true, assets={
    browser_gateway=true,
    virtual_provider=provider,
    document_bootstrap_url="https://lumen-theme.local/T/V/__lumen_bootstrap.js",
    document_bootstrap_source="/* popup hook */",
  }}}
  assert_true(type(injector.theme_gateway_config) == "function",
    "injector exposes browser theme-gateway selection")
  local gateway = injector.theme_gateway_config(themed)
  assert_true(gateway and gateway.virtual_provider == provider,
    "active theme exposes its virtual provider to the browser gateway")
  assert_true(gateway.bypass_csp == false,
    "theme JavaScript CSP bypass is opt-in in the channel assets")
  assert_true(type(gateway.document_bootstrap_source) == "string"
      and gateway.document_bootstrap_source:find("popup hook", 1, true),
    "active theme exposes its pre-document bootstrap source")
  assert_true(injector.theme_gateway_config({{assets={js={"ordinary"}}}}) == nil,
    "ordinary Lumen channels do not activate browser Fetch")
  assert_true(injector.theme_gateway_config({{assets={
      virtual_provider=provider,
      document_bootstrap_source="hook",
    }}}) == nil,
    "theme assets do not activate experimental browser auto-attach without opt-in")

  local anonymous_channels = {{assets={anonymous_web=true}}}
  local anonymous_gateway = injector.theme_gateway_config(anonymous_channels, true)
  assert_true(anonymous_gateway == nil,
    "parental unlock does not activate browser-wide auto-attach")
  assert_true(injector.theme_gateway_config(anonymous_channels, false) == nil,
    "anonymous gateway does not attach during Steam cold boot")

  local login_channels = {{assets={
    login_browser_gateway=true,
    login_guard_source="/* tiny guard */",
    login_theme_source="/* compiled popup theme */",
  }}}
  local login_gateway = injector.login_theme_gateway(login_channels, false)
  assert_true(login_gateway and login_gateway.login_only == true
      and login_gateway.login_guard_source:find("tiny guard", 1, true)
      and login_gateway.login_theme_source:find("compiled popup theme", 1, true),
    "pre-login observer exposes an ordered guard and compiled theme")
  assert_true(injector.login_theme_gateway(login_channels, true) == nil,
    "pre-login observer is removed after Steam's main UI is ready")
  assert_true(injector.login_theme_gateway({{assets={js={"ordinary"}}}}, false) == nil,
    "ordinary Lumen channels never allocate the pre-login observer")

  assert_true(type(injector.browser_fetch_patterns) == "function",
    "injector exposes browser Fetch patterns")
  local patterns = injector.browser_fetch_patterns(gateway)
  assert_true(#patterns == 1, "each renderer installs only the virtual-file Fetch pattern")
  assert_true(patterns[1].urlPattern == "https://lumen-theme.local/*"
      and patterns[1].requestStage == "Request",
    "virtual theme files are fulfilled before network access")
  local anonymous_patterns = injector.page_fetch_patterns(
    anonymous_channels[1].assets, false)
  assert_true(#anonymous_patterns == 2
      and anonymous_patterns[1].resourceType == "Document"
      and anonymous_patterns[2].resourceType == "Document",
    "anonymous mode intercepts only Store and Community documents")
  assert_true(type(injector.anonymous_web_url) == "function"
      and injector.anonymous_web_url("https://store.steampowered.com/app/440")
      and injector.anonymous_web_url("https://steamcommunity.com/app/440")
      and not injector.anonymous_web_url(
        "https://store.steampowered.com/marketingmessages/list/?include_seen=1")
      and not injector.anonymous_web_url("https://store.steampowered.com.evil.test/")
      and not injector.anonymous_web_url("https://help.steampowered.com/"),
    "anonymous proxy preserves authenticated offers on the exact HTTPS hosts")
  assert_true(type(injector.anonymous_request_headers) == "function",
    "injector exposes credential-free public request headers")
  local public_headers = injector.anonymous_request_headers({
    ["User-Agent"]="Valve Steam Client", Cookie="secret",
    Authorization="token", ["Accept-Language"]="en-US",
    ["Accept-Encoding"]="gzip", ["X-Steam-SessionID"]="session",
  })
  local joined = table.concat(public_headers, "\n"):lower()
  assert_true(joined:find("user%-agent: valve steam client")
      and joined:find("accept%-language: en%-us")
      and not joined:find("cookie", 1, true)
      and not joined:find("authorization", 1, true)
      and not joined:find("session", 1, true)
      and not joined:find("accept%-encoding"),
    "public proxy preserves presentation headers but never credentials or compression")
  assert_true(type(injector.anonymous_response_plan) == "function",
    "injector exposes anonymous response validation")
  local html_plan = injector.anonymous_response_plan({
    status=200, body="<html></html>", content_type="text/html; charset=UTF-8",
  })
  assert_true(html_plan and html_plan.action == "document",
    "public HTML is accepted")
  local redirect_plan = injector.anonymous_response_plan({
    status=302, body="", content_type="text/html",
    redirect_url="https://steamcommunity.com/",
  })
  assert_true(redirect_plan and redirect_plan.action == "redirect",
    "HTTPS redirects inside the exact host allowlist are passed to CEF")
  assert_true(injector.anonymous_response_plan({
      status=302, body="", redirect_url="https://example.com/",
    }) == nil,
    "cross-host redirects are rejected")
  assert_true(injector.anonymous_response_plan({
      status=302, body="", redirect_url="http://store.steampowered.com/",
    }) == nil,
    "redirect downgrades are rejected")
  assert_true(injector.anonymous_response_plan({
      status=200, body="binary", content_type="application/octet-stream",
    }) == nil,
    "non-HTML documents are rejected")
  assert_true(injector.anonymous_response_plan({
      status=403, body="<html></html>", content_type="text/html",
    }) == nil,
    "non-success public documents are rejected")
  assert_true(injector.anonymous_response_plan({
      status=200, body="<html></html>", content_type="text/html",
      effective_url="https://example.com/",
    }) == nil,
    "an unexpected effective response host is rejected")
  assert_true(type(injector.browser_auto_attach_params) == "function",
    "injector exposes the renderer startup gate")
  local attach = injector.browser_auto_attach_params(true)
  assert_true(attach.autoAttach == true and attach.flatten == true
      and attach.waitForDebuggerOnStart == false,
    "Steam CEF targets are observed without its unreliable debugger startup pause")
  local detach = injector.browser_auto_attach_params(false)
  assert_true(detach.autoAttach == false and detach.waitForDebuggerOnStart == false,
    "disabling themes removes the renderer startup gate")
  assert_true(type(injector.document_bootstrap_params) == "function",
    "injector exposes pre-document hook registration")
  local prepared = injector.document_bootstrap_params("new-theme", false)
  assert_true(prepared.source == "new-theme" and prepared.runImmediately == nil,
    "a theme switch registers the new hook without applying it to the old context")
  local recovery = injector.document_bootstrap_params("active-theme", true)
  assert_true(recovery.runImmediately == true,
    "attaching to an already-running Steam context can recover its active theme")
  assert_true(type(injector.renderer_startup_plan) == "function",
    "injector exposes paused-renderer command ordering")
  local fresh = injector.renderer_startup_plan(true)
  assert_true(fresh.resume_after_queue == true and fresh.wait_for_setup_results == false,
    "a debugger-paused renderer resumes after setup is queued, without deadlocking on replies")
  local existing = injector.renderer_startup_plan(false)
  assert_true(existing.resume_after_queue == false and existing.wait_for_setup_results == true,
    "an already-running renderer may wait for setup acknowledgements")

  -- Change Account reuses the already-created "Welcome to Steam" target and
  -- navigates it to a fresh document.  Registering the bootstrap only in
  -- SharedJSContext cannot cover that navigation: the target paints Valve's
  -- default document and receives the theme later from the ready-state path.
  -- Every page session owned by the browser gateway therefore needs its own
  -- evaluate-on-new-document registration; non-page targets must stay untouched.
  assert_true(type(injector.browser_target_setup_plan) == "function",
    "injector exposes per-renderer browser setup planning")
  local welcome = injector.browser_target_setup_plan(
    {type="page", title="Welcome to Steam"}, false)
  assert_true(welcome.bootstrap == true and welcome.run_immediately == true,
    "an existing account target installs and immediately recovers its document bootstrap")
  local future = injector.browser_target_setup_plan(
    {type="page", title="Account Menu"}, false, true)
  assert_true(future.bootstrap == true and future.run_immediately == true
      and future.bypass_csp == true,
    "a future popup is recovered immediately and receives the opted-in CSP bypass")
  local worker = injector.browser_target_setup_plan({type="worker"}, true)
  assert_true(worker.bootstrap == false,
    "non-document targets do not receive theme document scripts")
  assert_true(type(injector.shared_theme_target) == "function"
      and injector.shared_theme_target({type="page", title="SharedJSContext"})
      and injector.shared_theme_target({type="page",
        url="https://steamloopback.host/?IN_STEAMUI_SHARED_CONTEXT=true"}),
    "manual observer identifies SharedJSContext as soon as discovery reports it")
  assert_true(not injector.shared_theme_target({type="page", title="Sign in to Steam"})
      and not injector.shared_theme_target({type="worker", title="SharedJSContext"}),
    "manual observer never attaches to visible or non-page targets")
  assert_true(injector.browser_uses_auto_attach(login_gateway) == false
      and injector.browser_uses_auto_attach(gateway) == true,
    "the login observer uses manual SharedJSContext attachment, never Target.setAutoAttach")
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
end

local SAMPLE = {
  { title = "Steam",           url = "about:blank",                          webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/A" },
  { title = "SharedJSContext", url = "https://steamloopback.host/index.html", webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/B" },
  { title = "Welcome to Steam",url = "https://store.steampowered.com/",      webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/C" },
  { title = "Community",       url = "https://steamcommunity.com/app/440",   webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/D" },
  { title = "Friends",         url = "https://steamcommunity.com/chat",      webSocketDebuggerUrl = "ws://localhost:8080/devtools/page/E" },
}

-- Theme routing is staged and must not replace live channels until the reload
-- transaction commits it. The SharedJSContext control socket survives long
-- enough to issue RestartJSContext; themed UI sockets are closed beforehand.
do
  local old_channels, new_channels = {{id="old"}}, {{id="new"}}
  local state = injector.new({channels=old_channels, registry={}})
  local shell_closed, shared_closed = false, false
  state.conns = {
    shell = {title="Steam", close=function() shell_closed=true end},
    shared = {title="SharedJSContext", assets={js={"old-theme"}},
      close=function() shared_closed=true end},
  }
  state:queue_channels(new_channels)
  assert_true(state.channels == old_channels, "staging does not alter live theme channels")
  assert_true(state.pending_channels == new_channels, "new theme channels are staged")
  assert_true(state:commit_pending_channels(), "staged channels commit for reload")
  assert_true(state.channels == new_channels, "reload sees the new channels")
  assert_true(state.theme_reload_pending == true,
    "UI discovery is gated until the new JavaScript context exists")
  assert_true(shell_closed, "old themed UI connection closes before reload")
  assert_true(not shared_closed and state.conns.shared ~= nil,
    "SharedJSContext control survives to issue reload")
  assert_true(state.conns.shared.assets == nil,
    "preserved control socket cannot re-inject the old theme into the new context")
end

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

-- Parental public documents use each Store/Community page connection. The
-- browser-wide gateway remains theme-only, so enabling parental unlock cannot
-- put unrelated popups into Chromium's debugger-paused state.
do
  local anonymous_assets = {anonymous_web=true}
  local patterns = injector.page_fetch_patterns(anonymous_assets, false)
  assert_true(#patterns == 2
      and patterns[1].resourceType == "Document"
      and patterns[2].resourceType == "Document",
    "page connection intercepts Store and Community documents")
  assert_true(injector.page_recovery_url(
      "https://store.steampowered.com/?snr=client")
      == "https://store.steampowered.com/?snr=client"
      and injector.page_recovery_url("data:text/html,error", {
        {url="https://store.steampowered.com/app/440"},
        {url="data:text/html,error"},
      }, 1) == "https://store.steampowered.com/app/440"
      and injector.page_recovery_url("data:text/html,error", {
        {url="https://example.com/"},
        {url="data:text/html,error"},
      }, 1) == nil,
    "page recovery uses only an allowlisted original or history document")

  local recovery_assets = {anonymous_web=true}
  local recovery_routes = injector.route_targets_with_recovery({
    {title="Error", type="page", url="data:text/html,error",
      webSocketDebuggerUrl="ws://localhost/devtools/page/recovery"},
    {title="Unrelated", type="page", url="data:text/html,other",
      webSocketDebuggerUrl="ws://localhost/devtools/page/unrelated"},
  }, {{urls={"store.steampowered.com"}, assets=recovery_assets}})
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

  assert_true(injector.theme_gateway_config({{assets=anonymous_assets}}, true) == nil,
    "parental unlock never enables the browser-wide theme gateway")
  local provider = function() return "x", "text/plain" end
  local themed = injector.theme_gateway_config({{assets={
    browser_gateway=true,
    virtual_provider=provider,
    document_bootstrap_source="theme",
    anonymous_web=true,
  }}}, true)
  assert_true(themed and themed.virtual_provider == provider
      and themed.anonymous_web == nil,
    "custom theme gateway ignores parental anonymous state")
  local browser_patterns = injector.browser_fetch_patterns({
    virtual_provider=provider, anonymous_web=true,
  })
  assert_true(#browser_patterns == 1
      and browser_patterns[1].urlPattern == "https://lumen-theme.local/*",
    "browser-wide Fetch remains limited to virtual theme assets")

  local state = injector.new({channels={}})
  assert_true(state:needs_fast_tick() == false,
    "injector stays on its idle cadence without a public request")
  state.conns.example = {requests={document={}}}
  assert_true(state:needs_fast_tick() == true and state:idle_delay() == 0.01,
    "injector polls quickly only while a public request is pending")

  local source_file = assert(io.open("lua/injector.lua", "r"))
  local source = source_file:read("*a"); source_file:close()
  assert_true(source:find("function Conn:_start_anonymous_request", 1, true)
      and not source:find("function BrowserConn:_start_anonymous", 1, true),
    "anonymous gateway is page-scoped with no dead browser implementation")
end

print("test_inject: ALL PASS")
