-- Run:
--   LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_steamoauth.lua
--
-- steamoauth.lua decides how an in-client sign-in gets a window open. Steam only
-- spawns its own browser WINDOW for a target=_blank link clicked inside a web
-- view (the same path as the ProtonDB badge); the shell swallows window.open. So
-- the module borrows a store web view as the launcher, clicks the link there, and
-- puts the view's previous URL back so the user's Store tab is untouched.
--
-- These tests cover the pure decision layer: which target launches, whether the
-- client can host a sign-in at all, and that the built JS never breaks out of its
-- string literals. The lua.tools Discord login runs on exactly this surface
-- (State:_open_internal_oauth), so these are its guard rails too.
package.path = "lua/?.lua;" .. package.path
local steamoauth = require("steamoauth")

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

ok(steamoauth.pick_launcher({shell, menu, store}) == store, "launcher: store web view")
ok(steamoauth.pick_launcher({shell, community}) == community, "launcher: community web view")
ok(steamoauth.pick_launcher({shell, menu}) == nil, "launcher: none on library-only shell")
ok(steamoauth.pick_launcher({}) == nil, "launcher: empty list")
ok(steamoauth.pick_launcher(nil) == nil, "launcher: nil list")
-- A web view without a debugger URL cannot be driven.
ok(steamoauth.pick_launcher({{url = "https://store.steampowered.com/"}}) == nil,
   "launcher: web view without debugger url is unusable")
-- The sign-in window itself is a page on another host: never a launcher.
ok(steamoauth.pick_launcher({{title = "Authorize", url = "https://discord.com/oauth2/authorize",
    webSocketDebuggerUrl = "ws://127.0.0.1:1/devtools/page/E"}}) == nil,
   "launcher: the login window is not a launcher")
-- Origin match, not substring: a store page carrying another host in its query
-- string is still a store page.
ok(steamoauth.is_origin("https://store.steampowered.com/search/?term=discord.com",
   "store.steampowered.com") == true, "origin: query strings do not change the origin")
ok(steamoauth.is_origin("https://evil.example/?x=store.steampowered.com",
   "store.steampowered.com") == false, "origin: host must be the actual origin")

-- ── can this client host a sign-in at all ───────────────────────────────────
-- Asked BEFORE anything is clicked: Big Picture accepts the click and then shows
-- an empty external-browser route, which would strand the user.
ok(steamoauth.supported({shell, store}, false) == true, "supported: desktop shell with a web view")
ok(steamoauth.supported({shell, menu}, false) == true, "supported: desktop shell, launcher borrowed later")
ok(steamoauth.supported({shell, store}, true) == false, "supported: gamepad UI refused")
ok(steamoauth.supported({}, false) == false, "supported: no targets")
ok(steamoauth.supported(nil, false) == false, "supported: nil targets")
local _, reason = steamoauth.supported({shell, store}, true)
ok(reason == "unsupported", "supported: gamepad UI reports 'unsupported'")
local _, no_shell = steamoauth.supported({store}, false)
ok(no_shell == "no_shell", "supported: a missing shell reports 'no_shell'")

-- ── generated JS is injection-safe ─────────────────────────────────────────
local nasty = "https://example.test/login?x=';alert(1);//"
local expr = steamoauth.open_link_expr(nasty)
ok(expr:find("target='_blank'", 1, true) ~= nil, "js: opens in a new window")
-- The URL must sit entirely inside one double-quoted literal, so a quote or a
-- semicolon in it cannot start new statements.
local literal = expr:match('a%.href=(.-);a%.target=')
ok(literal ~= nil and literal:sub(1, 1) == '"' and literal:sub(-1) == '"',
   "js: url is one double-quoted literal")
ok(literal ~= nil and literal:find("';alert(1);", 1, true) ~= nil,
   "js: the payload stays inert inside that literal")
ok(steamoauth.load_background_expr("https://store.steampowered.com/about/")
     :find("MainWindowBrowserManager.LoadURL", 1, true) ~= nil, "js: background load")
ok(steamoauth.read_browser_url_expr():find("MainWindowBrowserManager", 1, true) ~= nil,
   "js: reads the current browser-view url")
ok(steamoauth.available_expr():find("MainWindowBrowserManager", 1, true) ~= nil,
   "js: availability probe asks for the browser manager")
-- Only http(s) may be handed to the click helper.
ok(steamoauth.open_link_expr("javascript:alert(1)") == nil, "js: refuses javascript: urls")
ok(steamoauth.open_link_expr("") == nil, "js: refuses empty url")
ok(steamoauth.open_link_expr(nil) == nil, "js: refuses nil url")
ok(steamoauth.load_background_expr("file:///etc/passwd") == nil, "js: refuses file: urls")

io.write((fails == 0 and "all ok" or (fails .. " FAILED")) .. " (" .. checks .. " checks)\n")
os.exit(fails == 0 and 0 or 1)
