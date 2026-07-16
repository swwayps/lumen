-- cloudsettings: backend for the Lumen settings-menu "Cloud Saves" tab.
--
-- Sets up CloudRedirect cloud saves WITHOUT the flatpak. The hook (the 32-bit
-- cloud_redirect.so) and the old flatpak GUI coordinate only through files under
-- ~/.config/CloudRedirect/ (config.json + tokens_<provider>.json); the flatpak
-- reimplemented OAuth + file writes in C#. We do the same in Lua here, talking
-- to the SAME file contract — no hook rebuild, no --cli, no flatpak, no
-- background process. The OAuth2 authorization-code + PKCE(S256) flow is ported
-- from CloudRedirect's ui/Services/OAuthService.cs.
--
-- All the exposed RPCs return JSON strings (the callServerMethod convention the
-- polyfill resolves). Pure helpers (pkce/url/body/callback parsing) and the
-- config IO are split from the socket/http work so the module stays
-- host-testable (deps are injectable in authorize/auth_poll).
local json = require("json")
local sha256 = require("sha256")
local b64 = require("b64")

local cloudsettings = {}

-- Provider constants — reused verbatim from OAuthService.cs / the hook. The
-- gdrive/onedrive client credentials are the same public clasp/rclone IDs the
-- hook and flatpak already ship; nothing account-specific.
local PROVIDERS = {
  gdrive = {
    client_id = "1072944905499-vm2v2i5dvn0a0d2o4ca36i1vge8cvbn0.apps.googleusercontent.com",
    client_secret = "v6V3fKV_zWU7iw1DrpO1rknX",
    scope = "https://www.googleapis.com/auth/drive.file",
    auth_url = "https://accounts.google.com/o/oauth2/v2/auth",
    token_url = "https://oauth2.googleapis.com/token",
    fixed_port = nil,          -- dynamic loopback port
    redirect_path = "/callback",
    access_type = "offline",   -- gdrive-only
    body_scope = false,        -- gdrive omits scope in the token exchange
  },
  onedrive = {
    client_id = "b15665d9-eda6-4092-8539-0eec376afd59",
    client_secret = "qtyfaBBYA403=unZUP40~_#",
    scope = "Files.ReadWrite offline_access",
    auth_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    fixed_port = 53682,        -- rclone's Azure app only registers this port
    redirect_path = "/",
    access_type = nil,
    body_scope = true,         -- onedrive includes scope in the token exchange
  },
}

local CALLBACK_TIMEOUT = 5 * 60 -- 5 minutes, matching OAuthService.cs

-- ── pure helpers ────────────────────────────────────────────────────────────

local function base64url(bytes)
  return (b64.encode(bytes):gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

-- Percent-encode per RFC 3986 (like C#'s Uri.EscapeDataString): keep the
-- unreserved set, escape everything else.
local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Decode a query component (%XX escapes; '+' means space).
local function urldecode(s)
  s = tostring(s):gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- pkce_challenge(verifier) -> base64url(sha256(verifier)), no padding (S256).
function cloudsettings.pkce_challenge(verifier)
  return base64url(sha256.digest(verifier))
end

-- build_auth_url(provider, redirect_uri, state, challenge) -> string.
function cloudsettings.build_auth_url(provider, redirect_uri, state, challenge)
  local p = PROVIDERS[provider]
  if not p then return nil end
  local parts = {
    "client_id=" .. urlencode(p.client_id),
    "redirect_uri=" .. urlencode(redirect_uri),
    "response_type=code",
    "scope=" .. urlencode(p.scope),
  }
  if p.access_type then parts[#parts + 1] = "access_type=" .. p.access_type end
  parts[#parts + 1] = "prompt=consent"
  parts[#parts + 1] = "state=" .. urlencode(state)
  parts[#parts + 1] = "code_challenge=" .. urlencode(challenge)
  parts[#parts + 1] = "code_challenge_method=S256"
  return p.auth_url .. "?" .. table.concat(parts, "&")
end

-- token_request_body(provider, code, redirect_uri, verifier) -> form body.
function cloudsettings.token_request_body(provider, code, redirect_uri, verifier)
  local p = PROVIDERS[provider]
  if not p then return nil end
  local parts = {
    "code=" .. urlencode(code),
    "client_id=" .. urlencode(p.client_id),
    "client_secret=" .. urlencode(p.client_secret),
    "redirect_uri=" .. urlencode(redirect_uri),
    "grant_type=authorization_code",
    "code_verifier=" .. urlencode(verifier),
  }
  if p.body_scope then parts[#parts + 1] = "scope=" .. urlencode(p.scope) end
  return table.concat(parts, "&")
end

-- parse_callback(request_line) -> code, state, error. Reads the query string
-- from an HTTP request line ("GET /callback?code=..&state=.. HTTP/1.1").
function cloudsettings.parse_callback(request_line)
  local query = tostring(request_line):match("%s/[^%s%?]*%?([^%s]*)%s") or
                tostring(request_line):match("%s/[^%s%?]*%?([^%s]*)")
  if not query then return nil, nil, "no query" end
  local params = {}
  for k, v in query:gmatch("([^&=]+)=([^&]*)") do
    params[urldecode(k)] = urldecode(v)
  end
  if params.code and params.code ~= "" then
    return params.code, params.state
  end
  return nil, params.state, params.error or "no code"
end

-- ── config / token file IO ──────────────────────────────────────────────────

function cloudsettings.default_config_path()
  local home = os.getenv("HOME") or ""
  if home == "" then return nil end
  return home .. "/.config/CloudRedirect/config.json"
end

local function dirname(path)
  return path:match("^(.*)/[^/]*$") or "."
end

-- read_config(path) -> decoded table. A missing/unreadable/invalid file yields
-- the local-only default the hook treats as "no cloud".
function cloudsettings.read_config(path)
  if not path then return { provider = "local" } end
  local f = io.open(path, "rb")
  if not f then return { provider = "local" } end
  local data = f:read("*a") or ""
  f:close()
  if data == "" then return { provider = "local" } end
  local ok, cfg = pcall(json.decode, data)
  if not ok or type(cfg) ~= "table" then return { provider = "local" } end
  if cfg.provider == nil then cfg.provider = "local" end
  return cfg
end

-- Atomic write of a config table (tmp + rename), creating the directory if
-- needed so a first-run setup works before the hook has ever written.
local write_seq = 0
local function write_config(path, cfg)
  if not path then return false, "no path" end
  os.execute("mkdir -p '" .. dirname(path):gsub("'", "'\\''") .. "' 2>/dev/null")
  local tmp = string.format("%s.tmp.lumen.%d.%d", path, os.time(), write_seq)
  write_seq = write_seq + 1
  local w, werr = io.open(tmp, "wb")
  if not w then return false, werr or "open failed" end
  w:write(json.encode(cfg))
  w:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then os.remove(tmp); return false, rerr or "rename failed" end
  return true
end

-- Read-modify-write one config key, preserving every other key the hook wrote.
local function set_config_key(path, key, value)
  local cfg = cloudsettings.read_config(path)
  cfg[key] = value
  return write_config(path, cfg)
end

-- Resolve the token file for a provider: config.token_path override (absolute
-- or relative to the config dir), else tokens_<provider>.json beside config.
local function token_path_for(config_path, provider, cfg)
  cfg = cfg or {}
  local dir = dirname(config_path)
  local tp = cfg.token_path
  if type(tp) == "string" and tp ~= "" then
    if tp:sub(1, 1) == "/" then return tp end
    return dir .. "/" .. tp
  end
  return dir .. "/tokens_" .. provider .. ".json"
end

local function has_refresh_token(token_file)
  local f = io.open(token_file, "rb")
  if not f then return false end
  local data = f:read("*a") or ""
  f:close()
  local ok, tok = pcall(json.decode, data)
  if not ok or type(tok) ~= "table" then return false end
  return type(tok.refresh_token) == "string" and tok.refresh_token ~= ""
end

-- ── RPC-facing operations (return JSON strings) ─────────────────────────────

-- status(config_path) -> {success, provider, authenticated, sync_achievements,
-- sync_playtime}. authenticated = the current provider's token file carries a
-- non-empty refresh_token (the only thing the hook needs; it re-mints access
-- tokens itself).
function cloudsettings.status(config_path)
  local cfg = cloudsettings.read_config(config_path)
  local provider = cfg.provider or "local"
  local authed = false
  if provider == "gdrive" or provider == "onedrive" then
    authed = has_refresh_token(token_path_for(config_path, provider, cfg))
  end
  return json.encode({
    success = true,
    provider = provider,
    authenticated = authed,
    sync_achievements = cfg.sync_achievements == true,
    sync_playtime = cfg.sync_playtime == true,
  })
end

-- set_provider(config_path, provider) -> {success[,error]}. "local" is the
-- no-cloud state; tokens are kept (sign_out clears them explicitly).
function cloudsettings.set_provider(config_path, provider)
  if provider ~= "gdrive" and provider ~= "onedrive" and provider ~= "local" then
    return json.encode({ success = false, error = "unknown provider" })
  end
  local ok, err = set_config_key(config_path, "provider", provider)
  if not ok then return json.encode({ success = false, error = tostring(err) }) end
  return json.encode({ success = true })
end

-- set_toggle(config_path, key, value) -> {success[,error]}. Only the two user
-- stats switches are writable; schema_fetch and the master stats_sync_enabled
-- keep their hook defaults.
function cloudsettings.set_toggle(config_path, key, value)
  if key ~= "sync_achievements" and key ~= "sync_playtime" then
    return json.encode({ success = false, error = "unknown toggle" })
  end
  local ok, err = set_config_key(config_path, key, value == true)
  if not ok then return json.encode({ success = false, error = tostring(err) }) end
  return json.encode({ success = true })
end

-- sign_out(config_path, provider) -> {success[,error]}. Delete the token file
-- and drop back to local-only.
function cloudsettings.sign_out(config_path, provider)
  if provider == "gdrive" or provider == "onedrive" then
    os.remove(token_path_for(config_path, provider, cloudsettings.read_config(config_path)))
  end
  local ok, err = set_config_key(config_path, "provider", "local")
  if not ok then return json.encode({ success = false, error = tostring(err) }) end
  return json.encode({ success = true, authenticated = false })
end

-- ── OAuth flow (authorize / auth_poll) ──────────────────────────────────────
-- Frontend-driven, no background thread: authorize() binds a NON-blocking
-- loopback listener and opens the browser, returning immediately; the frontend
-- then polls auth_poll() (~1 Hz), each call doing a non-blocking accept(). All
-- socket work happens inside RPC calls the injector loop drives, so nothing
-- runs between polls. `deps` (socket/http/now/open_url/gen_random) are
-- injectable for host tests; nil uses the real ones.
local pending = nil

local function default_gen_random(n)
  local bytes
  local f = io.open("/dev/urandom", "rb")
  if f then bytes = f:read(n); f:close() end
  if not bytes or #bytes < n then
    -- Fallback: math.random (seeded once). Only hit if /dev/urandom is absent.
    math.randomseed(os.time() + os.clock() * 1e6)
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    bytes = table.concat(t)
  end
  return base64url(bytes):sub(1, n)
end

local function default_open_url(url)
  local u = url:gsub("'", "%%27")
  -- Route through Steam's own external-URL handler instead of a bare xdg-open.
  -- This sidecar is a background process with no focus-activation token, so a
  -- direct xdg-open opens the OAuth tab WITHOUT raising the browser (Wayland's
  -- focus-stealing prevention keeps Steam in front). Steam IS the focused GUI
  -- app, so handing it the URL via steam://openurl_external makes it launch the
  -- default browser with activation, so the tab comes to the foreground — same
  -- as clicking any external link inside Steam. Fall back to a direct open if
  -- the steam:// scheme handler isn't registered.
  os.execute("{ xdg-open 'steam://openurl_external/" .. u .. "' || xdg-open '"
    .. u .. "'; } >/dev/null 2>&1 &")
end

local function resolve_deps(deps)
  deps = deps or {}
  return {
    socket = deps.socket or require("socket"),
    http = deps.http or require("http"),
    now = deps.now or os.time,
    open_url = deps.open_url or default_open_url,
    gen_random = deps.gen_random or default_gen_random,
  }
end

-- authorize(config_path, provider, deps) -> {status="waiting"|... }.
function cloudsettings.authorize(config_path, provider, deps)
  local p = PROVIDERS[provider]
  if not p then return json.encode({ status = "error", error = "unknown provider" }) end
  local d = resolve_deps(deps)

  -- close any stale pending listener before starting fresh
  if pending and pending.listener then pcall(function() pending.listener:close() end) end
  pending = nil

  local ok_srv, srv = pcall(d.socket.tcp)
  if not ok_srv or not srv then
    return json.encode({ status = "error", error = "socket unavailable" })
  end
  local port = p.fixed_port or 0
  local bok, berr = srv:bind("127.0.0.1", port)
  if not bok then
    pcall(function() srv:close() end)
    return json.encode({ status = "error", error = "bind failed: " .. tostring(berr) })
  end
  srv:listen()
  if p.fixed_port == nil then
    local _, boundport = srv:getsockname()
    port = tonumber(boundport) or 0
  end
  srv:settimeout(0)

  local state = d.gen_random(32)
  local verifier = d.gen_random(64)
  local challenge = cloudsettings.pkce_challenge(verifier)
  local redirect_uri = "http://localhost:" .. tostring(port) .. p.redirect_path
  local auth_url = cloudsettings.build_auth_url(provider, redirect_uri, state, challenge)

  pending = {
    listener = srv, provider = provider, state = state, verifier = verifier,
    redirect_uri = redirect_uri, config_path = config_path,
    deadline = d.now() + CALLBACK_TIMEOUT,
  }
  -- Return the URL for the frontend to open. Opening is NOT done here: a bare
  -- xdg-open from this background sidecar can't raise the browser under Wayland
  -- (no focus-activation token), so the frontend routes the open through Steam's
  -- own handler (SteamClient, via the __lumenOpenExternalUrl relay) which brings
  -- the browser to the foreground. LumenCloudOpenUrl is a backend xdg-open
  -- fallback for when that relay isn't available.
  return json.encode({ status = "waiting", auth_url = auth_url })
end

-- open_url(url): backend fallback opener (used by LumenCloudOpenUrl when the
-- frontend's Steam relay can't run). Best-effort; returns a JSON status.
function cloudsettings.open_url(url, deps)
  local d = resolve_deps(deps)
  if type(url) == "string" and url ~= "" then d.open_url(url) end
  return json.encode({ success = true })
end

local CLOSE_HTML =
  "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n" ..
  "<html><body style=\"font-family:sans-serif;text-align:center;padding:60px;" ..
  "background:#1e1e1e;color:#fff\"><h1>Signed in</h1>" ..
  "<p>You can close this window and return to Steam.</p></body></html>"

local function finish(status_tbl)
  if pending and pending.listener then pcall(function() pending.listener:close() end) end
  pending = nil
  return json.encode(status_tbl)
end

-- auth_poll(deps) -> {status="waiting"|"done"|"timeout"|"error"|"idle"}.
function cloudsettings.auth_poll(deps)
  if not pending then return json.encode({ status = "idle" }) end
  local d = resolve_deps(deps)

  local client, aerr = pending.listener:accept()
  if not client then
    if d.now() > pending.deadline then return finish({ status = "timeout" }) end
    return json.encode({ status = "waiting" }) -- aerr == "timeout": nothing yet
  end

  client:settimeout(2)
  local reqline = client:receive("*l") or ""
  pcall(function() client:send(CLOSE_HTML) end)
  pcall(function() client:close() end)

  local code, state, cberr = cloudsettings.parse_callback(reqline)
  if pending.state and state ~= pending.state then
    return finish({ status = "error", error = "state mismatch" })
  end
  if not code then
    return finish({ status = "error", error = cberr or "no code" })
  end

  local provider = pending.provider
  local config_path = pending.config_path
  local body = cloudsettings.token_request_body(provider, code, pending.redirect_uri, pending.verifier)
  local resp, herr = d.http.post(PROVIDERS[provider].token_url, body, {
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    timeout = 30,
  })
  if not resp or (resp.status and resp.status >= 400) then
    return finish({ status = "error",
      error = "token exchange failed: " .. tostring(herr or (resp and resp.status)) })
  end
  local ok_tok, tok = pcall(json.decode, resp.body or "")
  if not ok_tok or type(tok) ~= "table" or not tok.refresh_token or tok.refresh_token == "" then
    return finish({ status = "error", error = "no refresh token in response" })
  end

  local expires_in = tonumber(tok.expires_in) or 3600
  local token_file = token_path_for(config_path, provider, cloudsettings.read_config(config_path))
  local tf, tferr = io.open(token_file, "wb")
  if not tf then return finish({ status = "error", error = "cannot write token: " .. tostring(tferr) }) end
  tf:write(json.encode({
    access_token = tok.access_token or "",
    refresh_token = tok.refresh_token,
    expires_at = d.now() + expires_in,
  }))
  tf:close()
  os.execute("chmod 600 '" .. token_file:gsub("'", "'\\''") .. "' 2>/dev/null")

  set_config_key(config_path, "provider", provider)
  return finish({ status = "done", authenticated = true })
end

-- ── local apps list (Cloud Saves games list, phase 1) ──────────────────────
-- The tab shows one card per game that has cloud-save data. Phase 1 sources the
-- LOCAL apps straight from the hook's storage dir; remote apps merge in later.
-- CloudRedirect's own per-app metadata files are not save data, so they're not
-- counted toward the file count / size.
local STORAGE_META = {
  ["cn.cloudredirect"] = true, ["cn.dat"] = true,
  ["root_token.cloudredirect"] = true, ["root_token.dat"] = true,
  ["file_tokens.cloudredirect"] = true, ["file_tokens.dat"] = true,
  ["manifest.cloudredirect"] = true, ["manifest.dat"] = true,
  ["state.cloudredirect"] = true,
  ["deleted.cloudredirect"] = true, ["deleted.dat"] = true,
}

local function is_storage_metadata(path)
  -- CloudRedirect bookkeeping lives at the app-directory root. Do not suppress
  -- a game's own nested file merely because it uses a generic metadata basename.
  if path:find("/", 1, true) then return false end
  return STORAGE_META[path] or path:match("^manifest%.%d+%.cloudredirect$") ~= nil
end

function cloudsettings.default_storage_root()
  local home = os.getenv("HOME") or ""
  if home == "" then return nil end
  return home .. "/.config/CloudRedirect/storage"
end

-- The account folder names under storage/ are 32-bit Steam account ids. Steam's
-- config/loginusers.vdf keys users by the 64-bit SteamID; the low 32 bits are
-- the account id. parse_loginusers maps accountid -> PersonaName so the account
-- filter can show a friendly name instead of a raw number. Pure.
local STEAMID64_BASE = 76561197960265728

function cloudsettings.parse_loginusers(text)
  local names = {}
  for sid, block in (tostring(text or "")):gmatch('"(%d+)"%s*(%b{})') do
    local id64 = math.tointeger(tonumber(sid))
    if id64 and id64 > STEAMID64_BASE then
      local persona = block:match('"[Pp]ersona[Nn]ame"%s*"([^"]*)"')
      names[id64 - STEAMID64_BASE] = persona or ""
    end
  end
  return names
end

local function steam_root_guess()
  local h = os.getenv("HOME") or ""
  if h == "" then return nil end
  for _, c in ipairs({ h .. "/.steam/steam", h .. "/.steam/debian-installation",
                       h .. "/.local/share/Steam" }) do
    local f = io.open(c .. "/config/loginusers.vdf", "rb")
    if f then f:close(); return c end
  end
  return nil
end

local function load_account_names()
  local root = steam_root_guess()
  if not root then return {} end
  local f = io.open(root .. "/config/loginusers.vdf", "rb")
  if not f then return {} end
  local t = f:read("*a"); f:close()
  return cloudsettings.parse_loginusers(t or "")
end

local function list_dir(dir)
  local names = {}
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs then
    pcall(function() for e in lfs.dir(dir) do names[#names + 1] = e end end)
  else
    local p = io.popen("ls -1 '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
    if p then for line in p:lines() do names[#names + 1] = line end; p:close() end
  end
  return names
end

-- Count save files + total bytes under an app dir, excluding CloudRedirect's
-- metadata files. Uses find -printf so a single spawn walks the whole tree.
local function scan_app_dir(dir)
  local files, size = 0, 0
  local cmd = "find '" .. dir:gsub("'", "'\\''") ..
    "' -type f -printf '%s\\t%P\\n' 2>/dev/null"
  local p = io.popen(cmd, "r")
  if not p then return 0, 0 end
  for line in p:lines() do
    local sz, path = line:match("^(%d+)\t(.*)$")
    if sz and not is_storage_metadata(path) then
      files = files + 1
      size = size + (tonumber(sz) or 0)
    end
  end
  p:close()
  return files, size
end

-- list_apps(storage_root) -> JSON {success, apps=[{appid, account, files, size,
-- location, local, remote}]}. A missing storage root yields an empty list (no
-- cloud saves cached yet), not an error. Names/cover art are resolved in the
-- frontend via the Steam store API (like the Game Updates tab).
-- list_apps -> JSON {success, accounts=[{id,name,files}], apps=[{appid, account,
-- files, size, location, local, remote}]}. Apps are PER ACCOUNT: a game with a
-- save folder under two Steam accounts yields two entries (the frontend shows an
-- account filter when 2+ accounts exist, so each view is unambiguous). Accounts
-- are sorted by total save files desc (the active account, with real saves,
-- floats to the top and becomes the default filter). Names via loginusers.vdf.
-- list_apps(storage_root[, account_names_override]) — account_names_override is
-- a {accountid=persona} map used instead of reading loginusers.vdf (tests).
function cloudsettings.list_apps(storage_root, account_names_override)
  storage_root = storage_root or cloudsettings.default_storage_root()
  local apps = {}
  local acct_files, acct_size = {}, {}
  if storage_root then
    for _, acct in ipairs(list_dir(storage_root)) do
      if acct:match("^%d+$") then
        local acctid = math.tointeger(tonumber(acct))
        local acctdir = storage_root .. "/" .. acct
        for _, app in ipairs(list_dir(acctdir)) do
          if app ~= "0" and app:match("^%d+$") then
            local files, size = scan_app_dir(acctdir .. "/" .. app)
            apps[#apps + 1] = {
              appid = math.tointeger(tonumber(app)), account = acctid,
              files = files, size = size,
              location = "local", ["local"] = true, remote = false,
            }
            acct_files[acctid] = (acct_files[acctid] or 0) + files
            acct_size[acctid] = (acct_size[acctid] or 0) + size
          end
        end
      end
    end
  end

  -- Union the accounts that have LOCAL saves with the accounts Steam knows
  -- about (loginusers.vdf). A Steam account with no local folder but cloud
  -- saves would otherwise be invisible (its id is needed to query the cloud);
  -- offering it as a candidate makes its remote-only saves reachable. This adds
  -- no network cost — remote enumeration stays on-demand per selected account.
  local names = account_names_override or load_account_names()
  local acct_set = {}
  for id in pairs(acct_files) do acct_set[id] = true end
  for id in pairs(names) do acct_set[id] = true end
  local accounts = {}
  for id in pairs(acct_set) do
    accounts[#accounts + 1] = { id = id, name = names[id] or "",
                                files = acct_files[id] or 0, size = acct_size[id] or 0 }
  end
  -- Default filter = the account with the most save DATA (the active account
  -- has real saves; stale/other accounts are near-empty). Sort by size desc,
  -- then file count, then id for a stable order.
  table.sort(accounts, function(a, b)
    if a.size ~= b.size then return a.size > b.size end
    if a.files ~= b.files then return a.files > b.files end
    return a.id < b.id
  end)
  table.sort(apps, function(a, b)
    if a.appid ~= b.appid then return a.appid < b.appid end
    return a.account < b.account
  end)
  return json.encode({ success = true, accounts = json.array(accounts),
                       apps = json.array(apps) })
end

-- Read the stored refresh token for a provider (nil if absent/empty).
local function read_refresh_token(config_path, provider, cfg)
  local tf = token_path_for(config_path, provider, cfg or cloudsettings.read_config(config_path))
  local f = io.open(tf, "rb"); if not f then return nil end
  local data = f:read("*a"); f:close()
  local ok, t = pcall(json.decode, data or "")
  if ok and type(t) == "table" and type(t.refresh_token) == "string" and t.refresh_token ~= "" then
    return t.refresh_token
  end
  return nil
end

-- remote_apps(config_path, account, local_appids[, deps]) -> JSON. Enumerates
-- the app-id folders present in the user's cloud and returns logical statistics
-- for remote-only games. Apps that already exist locally skip the metadata
-- download because their displayed statistics come from list_apps().
function cloudsettings.remote_apps(config_path, account, local_appids, deps)
  local cfg = cloudsettings.read_config(config_path)
  local provider = cfg.provider or "local"
  if provider ~= "gdrive" and provider ~= "onedrive" then
    return json.encode({ success = true, appids = json.array({}), apps = json.array({}),
                         provider = provider, reason = "local" })
  end
  local rt = read_refresh_token(config_path, provider, cfg)
  if not rt then
    return json.encode({ success = false, reason = "not_authenticated", provider = provider })
  end
  local acct = math.tointeger(tonumber(account))
  if not acct then return json.encode({ success = false, error = "bad account" }) end
  local ok, cr = pcall(require, "cloudremote")
  if not ok then return json.encode({ success = false, error = "cloudremote unavailable" }) end
  if type(local_appids) ~= "table" then local_appids = {} end
  local apps, err = cr.list_apps(provider, rt, acct, local_appids, deps)
  if not apps then return json.encode({ success = false, error = tostring(err), provider = provider }) end
  local appids = {}
  for _, app in ipairs(apps) do appids[#appids + 1] = app.appid end
  return json.encode({ success = true, appids = json.array(appids),
                       apps = json.array(apps), provider = provider })
end

-- Compatibility for callers that only need presence and use the old signature.
function cloudsettings.remote_appids(config_path, account, deps)
  local cfg = cloudsettings.read_config(config_path)
  local provider = cfg.provider or "local"
  if provider ~= "gdrive" and provider ~= "onedrive" then
    return json.encode({ success = true, appids = json.array({}),
                         provider = provider, reason = "local" })
  end
  local rt = read_refresh_token(config_path, provider, cfg)
  if not rt then
    return json.encode({ success = false, reason = "not_authenticated", provider = provider })
  end
  local acct = math.tointeger(tonumber(account))
  if not acct then return json.encode({ success = false, error = "bad account" }) end
  local ok, cr = pcall(require, "cloudremote")
  if not ok then return json.encode({ success = false, error = "cloudremote unavailable" }) end
  local appids, err = cr.list_appids(provider, rt, acct, deps)
  if not appids then
    return json.encode({ success = false, error = tostring(err), provider = provider })
  end
  return json.encode({ success = true, appids = json.array(appids), provider = provider })
end

-- ── registration ────────────────────────────────────────────────────────────

-- The frontend calls these with a single {json: JSON.stringify(payload)} arg
-- (the callServerMethod convention every Lumen tab uses). The RPC dispatcher
-- (rpc.lua) sorts the JS keys alphabetically and passes their VALUES
-- POSITIONALLY, so the wrapper receives the json STRING as its first arg and
-- must decode it — NOT an args table.
local function decode_arg(json_str)
  local ok, req = pcall(json.decode, json_str)
  if ok and type(req) == "table" then return req end
  return {}
end

-- register(registry[, config_path]): install the six Cloud Saves RPCs. The path
-- is injectable for host tests; nil uses the real ~/.config/CloudRedirect path.
function cloudsettings.register(registry, config_path)
  local cp = config_path or cloudsettings.default_config_path()
  registry.LumenCloudStatus = function() return cloudsettings.status(cp) end
  registry.LumenCloudSetProvider = function(j)
    return cloudsettings.set_provider(cp, decode_arg(j).provider)
  end
  registry.LumenCloudSetToggle = function(j)
    local r = decode_arg(j)
    return cloudsettings.set_toggle(cp, r.key, r.value)
  end
  registry.LumenCloudAuthorize = function(j)
    return cloudsettings.authorize(cp, decode_arg(j).provider)
  end
  registry.LumenCloudAuthPoll = function() return cloudsettings.auth_poll() end
  registry.LumenCloudSignOut = function(j)
    return cloudsettings.sign_out(cp, decode_arg(j).provider)
  end
  registry.LumenCloudOpenUrl = function(j)
    return cloudsettings.open_url(decode_arg(j).url)
  end
  registry.LumenCloudApps = function() return cloudsettings.list_apps() end
  registry.LumenCloudRemoteApps = function(j)
    local r = decode_arg(j)
    return cloudsettings.remote_apps(cp, r.account, r.local_appids)
  end
  return registry
end

return cloudsettings
