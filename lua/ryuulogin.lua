-- ryuulogin.lua — decision layer for the in-client Ryuu (Discord) sign-in.
--
-- Ryuu serves fix archives only to a signed-in session, and the sign-in is a
-- Discord OAuth round trip. Doing it in the user's system browser is useless:
-- that cookie lands in a different jar. So the login happens inside Steam.
--
-- Two client facts drive this module (both verified against a live client):
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
-- Everything here is pure: target choice, cookie extraction and JS building.
-- The IO lives in the injector (see State:ryuu_login_*).
local json = require("json")

local ryuulogin = {}

ryuulogin.HOST = "generator.ryuu.lol"
ryuulogin.ORIGIN = "https://generator.ryuu.lol"
ryuulogin.LOGIN_URL = "https://generator.ryuu.lol/login?next=/fixes"
-- Loaded into a background web view only when no store/community view is live.
-- A small static page, so borrowing it costs almost nothing.
ryuulogin.LAUNCHER_URL = "https://store.steampowered.com/about/"

-- Hosts whose pages are Steam web views: the only contexts where a target
-- =_blank click makes the client open its own browser window.
local WEB_VIEW_HOSTS = {"store.steampowered.com", "steamcommunity.com"}

local function url_of(target)
  return tostring((type(target) == "table" and target.url) or "")
end

-- Origin match, not a substring match: a store page carrying the Ryuu host in a
-- query string must not be mistaken for the login window.
local function is_origin(url, host)
  local scheme_host = url:match("^https?://([^/%?#]+)")
  if not scheme_host then return false end
  scheme_host = scheme_host:lower()
  return scheme_host == host or scheme_host:sub(-(#host + 1)) == "." .. host
end

-- pick_launcher(targets) -> target | nil
-- A live, drivable store/community web view to click the login link in.
function ryuulogin.pick_launcher(targets)
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

-- login_windows(targets) -> array of targets
-- Everything opened by the sign-in: the Ryuu page and the Discord authorize
-- step it redirects through. Used to close the window once the session is in.
function ryuulogin.login_windows(targets)
  local out = {}
  for _, target in ipairs(targets or {}) do
    if type(target) == "table" and target.webSocketDebuggerUrl then
      local url = url_of(target)
      local ryuu = is_origin(url, ryuulogin.HOST)
      -- The Discord step is identified by the redirect back to Ryuu, so an
      -- unrelated Discord window the user opened is left alone.
      local discord = is_origin(url, "discord.com")
        and url:find("generator%.ryuu%.lol") ~= nil
      if ryuu or discord then out[#out + 1] = target end
    end
  end
  return out
end

-- pick_session(result) -> value | nil
-- The Ryuu session cookie out of a CDP Network.getCookies result. Only the Ryuu
-- host counts: Steam's jar holds a `session` cookie for other hosts too.
function ryuulogin.pick_session(result)
  local list = type(result) == "table" and result.cookies
  for _, cookie in ipairs(type(list) == "table" and list or {}) do
    if type(cookie) == "table" and cookie.name == "session" then
      local domain = tostring(cookie.domain or ""):lower():gsub("^%.", "")
      local value = tostring(cookie.value or "")
      if value ~= "" and (domain == ryuulogin.HOST
          or domain:sub(-(#ryuulogin.HOST + 1)) == "." .. ryuulogin.HOST) then
        return value
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
function ryuulogin.open_link_expr(url)
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
function ryuulogin.load_background_expr(url)
  url = safe_url(url)
  if not url then return nil end
  return "(function(){try{if(!window.MainWindowBrowserManager)return false;"
    .. "MainWindowBrowserManager.LoadURL(" .. json.encode(url) .. ");return true;}"
    .. "catch(e){return false;}})()"
end

-- read_browser_url_expr() -> JS
-- The browser view's current URL, so it can be restored after borrowing it.
function ryuulogin.read_browser_url_expr()
  return "(function(){try{return String((window.MainWindowBrowserManager"
    .. "&&MainWindowBrowserManager.m_URL)||'');}catch(e){return '';}})()"
end

-- supported(targets, gamepad_ui) -> true | false, reason
-- Whether this client can run the in-client sign-in at all.
--
-- Big Picture / gamepad UI cannot (verified on a live Bazzite session): the
-- target=_blank click IS accepted, but the shell only flips to an empty
-- external-browser route and no page ever loads — and
-- MainWindowBrowserManager.LoadURL is a no-op there as well. So the answer must
-- be known BEFORE clicking, otherwise the user is left on a blank Steam view
-- with no way to finish. There the manual paste is the only path.
function ryuulogin.supported(targets, gamepad_ui)
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

-- poll_state(session, adopt_result) -> "waiting" | "configured" | "error", message
-- Maps one poll tick to the state the panel renders. Ryuu issues an ANONYMOUS
-- session cookie before the Discord sign-in (it carries the OAuth state), so a
-- cookie that the backend probe rejects means "still waiting", not "failed" —
-- otherwise the panel would give up the moment the login window opens.
function ryuulogin.poll_state(session, adopt_result)
  if type(session) ~= "string" or session == "" then return "waiting" end
  if type(adopt_result) ~= "table" then return "waiting" end
  if adopt_result.success and adopt_result.configured then return "configured" end
  -- A refused probe is the pre-sign-in cookie. Anything else (storage failure,
  -- malformed value) is a real error the user must see.
  local err = tostring(adopt_result.error or "")
  if err ~= "" and err:lower():find("sign in", 1, true) == nil then
    return "error", err
  end
  return "waiting"
end

-- available_expr() -> JS
-- Whether this client can drive the in-client login at all. Gamepad/Big Picture
-- shells have no MainWindowBrowserManager, and there the manual paste is the
-- only path.
function ryuulogin.available_expr()
  return "(function(){try{return !!window.MainWindowBrowserManager;}"
    .. "catch(e){return false;}})()"
end

return ryuulogin
