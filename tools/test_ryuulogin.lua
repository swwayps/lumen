-- Run via the built binary:
--   LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_ryuulogin.lua
--
-- ryuulogin.lua drives the in-client Ryuu sign-in. Steam only spawns its own
-- browser WINDOW for a target=_blank link clicked inside a web view (the same
-- path as the ProtonDB badge); the shell swallows window.open. So the module
-- borrows a store web view as the launcher, clicks the link there, and puts the
-- view's previous URL back so the user's Store tab is untouched. The CEF cookie
-- jar is global, so the session is later read from ANY target.
--
-- These tests cover the pure decision layer: which target launches, which
-- windows belong to the login, how the session is picked out of a getCookies
-- result, and that the built JS never breaks out of its string literals.
package.path = "lua/?.lua;" .. package.path
local ryuulogin = require("ryuulogin")

local fails, checks = 0, 0
local function ok(cond, name)
  checks = checks + 1
  if cond then io.write("ok " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); fails = fails + 1 end
end

-- ── launcher pick ───────────────────────────────────────────────────────────
-- A live store/community web view is reused as-is: nothing to load, nothing to
-- restore, so the user's Store tab keeps its page.
local store = {title = "Team Fortress 2", url = "https://store.steampowered.com/app/440/",
               webSocketDebuggerUrl = "ws://127.0.0.1:1/devtools/page/A"}
local community = {title = "Steam Community", url = "https://steamcommunity.com/app/440",
                   webSocketDebuggerUrl = "ws://127.0.0.1:1/devtools/page/B"}
local shell = {title = "SharedJSContext", url = "https://steamloopback.host/index.html",
               webSocketDebuggerUrl = "ws://127.0.0.1:1/devtools/page/C"}
local menu = {title = "Library Supernav", url = "about:blank?createflags=4538378",
              webSocketDebuggerUrl = "ws://127.0.0.1:1/devtools/page/D"}

ok(ryuulogin.pick_launcher({shell, menu, store}) == store, "launcher: store web view")
ok(ryuulogin.pick_launcher({shell, community}) == community, "launcher: community web view")
ok(ryuulogin.pick_launcher({shell, menu}) == nil, "launcher: none on library-only shell")
ok(ryuulogin.pick_launcher({}) == nil, "launcher: empty list")
ok(ryuulogin.pick_launcher(nil) == nil, "launcher: nil list")
-- A web view without a debugger URL cannot be driven.
ok(ryuulogin.pick_launcher({{url = "https://store.steampowered.com/"}}) == nil,
   "launcher: web view without debugger url is unusable")
-- The Ryuu login window itself is a page on another host: never a launcher.
ok(ryuulogin.pick_launcher({{title = "Fixes", url = "https://generator.ryuu.lol/fixes",
    webSocketDebuggerUrl = "ws://127.0.0.1:1/devtools/page/E"}}) == nil,
   "launcher: the login window is not a launcher")

-- ── login windows (what we close when done) ─────────────────────────────────
local login_page = {title = "Fixes - Ryuu's Manifests", url = "https://generator.ryuu.lol/fixes",
                    webSocketDebuggerUrl = "ws://127.0.0.1:1/devtools/page/F"}
local discord = {title = "Discord | Authorize", webSocketDebuggerUrl = "ws://127.0.0.1:1/devtools/page/G",
                 url = "https://discord.com/oauth2/authorize?client_id=1&redirect_uri=" ..
                       "https%3A%2F%2Fgenerator.ryuu.lol%2Fcallback"}
local found = ryuulogin.login_windows({shell, store, login_page, discord})
ok(#found == 2, "windows: login page and its Discord step")
ok(found[1] == login_page and found[2] == discord, "windows: in discovery order")
ok(#ryuulogin.login_windows({shell, store}) == 0, "windows: none when login is closed")
ok(#ryuulogin.login_windows(nil) == 0, "windows: nil list")
-- A store page merely mentioning the host in a query string is not a login window.
ok(#ryuulogin.login_windows({{url = "https://store.steampowered.com/?q=generator.ryuu.lol",
    webSocketDebuggerUrl = "ws://x"}}) == 0, "windows: host must be the origin")

-- ── session pick out of Network.getCookies ─────────────────────────────────
local function cookies(list) return {cookies = list} end
ok(ryuulogin.pick_session(cookies({
    {name = "theme", value = "dark", domain = "generator.ryuu.lol"},
    {name = "session", value = ".signed", domain = "generator.ryuu.lol"},
  })) == ".signed", "session: picked by name")
ok(ryuulogin.pick_session(cookies({
    {name = "session", value = ".other", domain = "store.steampowered.com"},
  })) == nil, "session: other hosts ignored")
ok(ryuulogin.pick_session(cookies({
    {name = "session", value = "", domain = "generator.ryuu.lol"},
  })) == nil, "session: empty value ignored")
ok(ryuulogin.pick_session(cookies({})) == nil, "session: no cookies")
ok(ryuulogin.pick_session(nil) == nil, "session: nil result")
ok(ryuulogin.pick_session({}) == nil, "session: result without cookies")
-- Sub-domain forms Steam may store the cookie under.
ok(ryuulogin.pick_session(cookies({
    {name = "session", value = ".dotted", domain = ".generator.ryuu.lol"},
  })) == ".dotted", "session: leading-dot domain")

-- ── gamepad UI is refused up front ─────────────────────────────────────────
-- Verified on a live Bazzite Big Picture session: the target=_blank click IS
-- accepted there, but the shell flips to an empty external-browser route and no
-- page ever loads (MainWindowBrowserManager.LoadURL is a no-op too). Refusing
-- must therefore happen BEFORE the click, or the user is left staring at a blank
-- Steam view with no way to finish.
ok(ryuulogin.supported({shell, store}, false) == true, "supported: desktop shell with a web view")
ok(ryuulogin.supported({shell, menu}, false) == true, "supported: desktop shell, launcher borrowed later")
ok(ryuulogin.supported({shell, store}, true) == false, "supported: gamepad UI refused")
ok(ryuulogin.supported({}, false) == false, "supported: no targets")
ok(ryuulogin.supported(nil, false) == false, "supported: nil targets")
local _, reason = ryuulogin.supported({shell, store}, true)
ok(reason == "unsupported", "supported: gamepad UI reports 'unsupported'")
local _, no_shell = ryuulogin.supported({store}, false)
ok(no_shell == "no_shell", "supported: a shell-less target list reports 'no_shell'")

-- ── poll state machine ─────────────────────────────────────────────────────
-- The anonymous pre-sign-in cookie must read as "still waiting", never as a
-- failure: it exists from the instant the login window opens.
ok(ryuulogin.poll_state(nil, nil) == "waiting", "poll: no cookie yet")
ok(ryuulogin.poll_state("", nil) == "waiting", "poll: empty cookie")
ok(ryuulogin.poll_state(".anon", {success = false,
     error = "Ryuu did not accept this session yet. Sign in on the page that opened."})
   == "waiting", "poll: refused probe keeps waiting")
ok(ryuulogin.poll_state(".good", {success = true, configured = true}) == "configured",
   "poll: verified session configures")
local state, message = ryuulogin.poll_state(".good", {success = false,
  error = "Could not save Ryuu authentication."})
ok(state == "error" and message == "Could not save Ryuu authentication.",
   "poll: a storage failure surfaces as an error")
ok(ryuulogin.poll_state(".good", {success = true}) == "waiting",
   "poll: success without configured is not enough")
ok(ryuulogin.poll_state(".good", "not a table") == "waiting", "poll: junk backend reply")

-- ── generated JS is injection-safe ─────────────────────────────────────────
local nasty = "https://generator.ryuu.lol/login?x=';alert(1);//"
local expr = ryuulogin.open_link_expr(nasty)
ok(expr:find("target='_blank'", 1, true) ~= nil, "js: opens in a new window")
-- The URL must sit entirely inside one double-quoted literal, so a quote or a
-- semicolon in it cannot start new statements.
local literal = expr:match('a%.href=(.-);a%.target=')
ok(literal ~= nil and literal:sub(1, 1) == '"' and literal:sub(-1) == '"',
   "js: url is one double-quoted literal")
ok(literal ~= nil and literal:find("';alert(1);", 1, true) ~= nil,
   "js: the payload stays inert inside that literal")
ok(ryuulogin.load_background_expr("https://store.steampowered.com/about/")
     :find("MainWindowBrowserManager.LoadURL", 1, true) ~= nil, "js: background load")
ok(ryuulogin.read_browser_url_expr():find("MainWindowBrowserManager", 1, true) ~= nil,
   "js: reads the current browser-view url")
-- Only http(s) may be handed to the click helper.
ok(ryuulogin.open_link_expr("javascript:alert(1)") == nil, "js: refuses javascript: urls")
ok(ryuulogin.open_link_expr("") == nil, "js: refuses empty url")
ok(ryuulogin.load_background_expr("file:///etc/passwd") == nil, "js: refuses file: urls")

io.write((fails == 0 and "all ok" or (fails .. " FAILED")) .. " (" .. checks .. " checks)\n")
os.exit(fails == 0 and 0 or 1)
