-- steamoauth.lua — decision layer for running an OAuth sign-in INSIDE Steam.
--
-- A sign-in that the user completes in their system browser is useless to us:
-- the resulting cookie lands in a different jar. So the login happens inside
-- Steam's own browser, and this module decides how to get a window open there.
--
-- Two client facts drive it (both verified against a live client):
--
--   1. Steam spawns its OWN browser window only for a target=_blank link
--      clicked inside a WEB VIEW (store/community) — the same path as an
--      external link on a store page. In the shell (SharedJSContext) both
--      window.open and a synthetic _blank click are swallowed, and
--      steam://openurl does nothing. So a web view is borrowed as the launcher.
--      When none is live, MainWindowBrowserManager.LoadURL loads one in the
--      BACKGROUND (the visible route does not change), and its previous URL is
--      put back afterwards so the user's Store tab is untouched.
--
--   2. The CEF cookie jar is GLOBAL. Once the login completes in that window,
--      Network.getCookies on any target — including the SharedJSContext
--      connection the injector already holds — returns the HttpOnly session
--      cookie. Nothing needs to attach to the login window to read it.
--
-- Everything here is pure: target choice and JS building. The IO lives in the
-- injector (State:_open_internal_oauth), and the per-provider parts (which URL
-- to open, which windows to close afterwards, how to read the session) live with
-- that provider — see luatoolslogin.lua.
local json = require("json")

local steamoauth = {}

-- Loaded into a background web view only when no store/community view is live.
-- A small static page, so borrowing it costs almost nothing.
steamoauth.LAUNCHER_URL = "https://store.steampowered.com/about/"

-- Hosts whose pages are Steam web views: the only contexts where a target
-- =_blank click makes the client open its own browser window.
local WEB_VIEW_HOSTS = {"store.steampowered.com", "steamcommunity.com"}

local function url_of(target)
  return tostring((type(target) == "table" and target.url) or "")
end

-- Origin match, not a substring match: a store page carrying a provider's host
-- in a query string must not be mistaken for the login window.
local function is_origin(url, host)
  local scheme_host = url:match("^https?://([^/%?#]+)")
  if not scheme_host then return false end
  scheme_host = scheme_host:lower()
  return scheme_host == host or scheme_host:sub(-(#host + 1)) == "." .. host
end

steamoauth.is_origin = is_origin

-- pick_launcher(targets) -> target | nil
-- A live, drivable store/community web view to click the login link in.
function steamoauth.pick_launcher(targets)
  for _, target in ipairs(targets or {}) do
    if type(target) == "table" and target.webSocketDebuggerUrl then
      local url = url_of(target)
      for _, host in ipairs(WEB_VIEW_HOSTS) do
        if is_origin(url, host) then return target end
      end
    end
  end
  return nil
end

-- Only plain http(s) URLs may reach the JS builders. Everything else (javascript:
-- , file:, data:) is refused outright rather than escaped.
local function safe_url(url)
  url = tostring(url or "")
  if url == "" or not url:match("^https?://[^%s]+$") then return nil end
  return url
end

-- open_link_expr(url) -> JS | nil
-- Click a target=_blank anchor inside a web view so the client opens the URL in
-- its own browser window. The URL is emitted as a JSON string literal.
function steamoauth.open_link_expr(url)
  url = safe_url(url)
  if not url then return nil end
  return "(function(){try{var a=document.createElement('a');a.href=" .. json.encode(url)
    .. ";a.target='_blank';a.rel='noopener noreferrer';a.style.display='none';"
    .. "document.body.appendChild(a);a.click();a.remove();return true;}"
    .. "catch(e){return false;}})()"
end

-- load_background_expr(url) -> JS | nil
-- Load a URL into the main window's browser view WITHOUT switching the visible
-- route, so a launcher exists on library-only sessions.
function steamoauth.load_background_expr(url)
  url = safe_url(url)
  if not url then return nil end
  return "(function(){try{if(!window.MainWindowBrowserManager)return false;"
    .. "MainWindowBrowserManager.LoadURL(" .. json.encode(url) .. ");return true;}"
    .. "catch(e){return false;}})()"
end

-- read_browser_url_expr() -> JS
-- The browser view's current URL, so it can be restored after borrowing it.
function steamoauth.read_browser_url_expr()
  return "(function(){try{return String((window.MainWindowBrowserManager"
    .. "&&MainWindowBrowserManager.m_URL)||'');}catch(e){return '';}})()"
end

-- supported(targets, gamepad_ui) -> true | false, reason
-- Whether this client can run an in-client sign-in at all.
--
-- Big Picture / gamepad UI cannot (verified on a live Bazzite session): the
-- target=_blank click IS accepted, but the shell only flips to an empty
-- external-browser route and no page ever loads — and
-- MainWindowBrowserManager.LoadURL is a no-op there as well. So the answer must
-- be known BEFORE clicking, otherwise the user is left on a blank Steam view
-- with no way to finish.
function steamoauth.supported(targets, gamepad_ui)
  if type(targets) ~= "table" or #targets == 0 then return false, "no_shell" end
  if gamepad_ui == true then return false, "unsupported" end
  for _, target in ipairs(targets) do
    if type(target) == "table" and target.title == "SharedJSContext"
        and target.webSocketDebuggerUrl then
      return true
    end
  end
  return false, "no_shell"
end

-- available_expr() -> JS
-- Whether this client can drive an in-client login at all. Gamepad/Big Picture
-- shells have no MainWindowBrowserManager.
function steamoauth.available_expr()
  return "(function(){try{return !!window.MainWindowBrowserManager;}"
    .. "catch(e){return false;}})()"
end

return steamoauth
