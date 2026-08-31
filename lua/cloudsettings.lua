-- cloudsettings: backend for the Lumen settings-menu "Cloud Saves" tab.
--
-- Sets up CloudRedirect cloud saves without the flatpak. OAuth and config IO
-- stay in Lua; provider-generic bucket probes, remote listing and migration use
-- CloudRedirect's own small CLI beside the 32-bit hook so S3/R2/folder semantics
-- remain identical to upstream.
--
-- All the exposed RPCs return JSON strings (the callServerMethod convention the
-- polyfill resolves). Pure helpers (pkce/url/body/callback parsing) and the
-- config IO are split from the socket/http work so the module stays
-- host-testable (deps are injectable in authorize/auth_poll).
local json = require("json")
local nonce = require("nonce")
local privatefs = require("privatefs")
local sha256 = require("sha256")
local b64 = require("b64")
local lfs = require("lfs")
local utils = require("utils")

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
local staged_tokens = {}

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

-- build_auth_url(provider, redirect_uri, state, challenge, cfg) -> string.
-- `cfg` may carry <provider>_client_id / _client_secret to use this install's own
-- OAuth client instead of the shared public one (see provider_credentials).
function cloudsettings.build_auth_url(provider, redirect_uri, state, challenge, cfg)
  local p = cloudsettings.provider_credentials(provider, cfg)
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

-- token_request_body(provider, code, redirect_uri, verifier, cfg) -> form body.
function cloudsettings.token_request_body(provider, code, redirect_uri, verifier, cfg)
  local p = cloudsettings.provider_credentials(provider, cfg)
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

local function read_file_snapshot(path)
  local f = io.open(path, "rb")
  if not f then return { path = path, exists = false } end
  local data = f:read("*a") or ""
  f:close()
  return { path = path, exists = true, data = data }
end

local function restore_file_snapshot(snap, private)
  if not snap or not snap.path then return end
  if not snap.exists then os.remove(snap.path); return end
  if private then
    local ok, value = pcall(json.decode, snap.data or "")
    if ok and type(value) == "table" then
      cloudsettings.write_token_file(snap.path, value)
      return
    end
  end
  local tmp = snap.path .. ".rollback.lumen"
  local f = io.open(tmp, "wb")
  if not f then return end
  f:write(snap.data or "")
  f:close()
  os.rename(tmp, snap.path)
end

local function default_credential_name(provider)
  if provider == "r2" then return "r2_credentials.json" end
  if provider == "s3" then return "s3_credentials.json" end
  return "tokens_" .. tostring(provider) .. ".json"
end

-- Resolve the credential file exactly like CloudRedirect: a per-provider entry
-- wins, then the active provider's legacy token_path, then the provider's
-- convention filename. Relative paths are anchored beside config.json.
--
-- The override used to accept an ABSOLUTE path, so whoever could write
-- config.json chose where a long-lived refresh token was stored. It is now
-- confined to the config directory: absolute paths, traversal and control
-- characters all fall back to the default name.
function cloudsettings.token_path_for(config_path, provider, cfg)
  cfg = cfg or {}
  local dir = dirname(config_path)
  local tp
  if type(cfg.token_paths) == "table" then tp = cfg.token_paths[provider] end
  if (type(tp) ~= "string" or tp == "") and cfg.provider == provider then
    tp = cfg.token_path
  end
  local function has_parent_segment(path)
    for seg in path:gmatch("[^/]+") do
      if seg == ".." then return true end
    end
    return false
  end
  if type(tp) == "string" and tp ~= "" and tp:sub(1, 1) ~= "/"
      and not tp:find("[%z\n\r]") and not has_parent_segment(tp) then
    return dir .. "/" .. tp
  end
  if type(tp) == "string" and tp:sub(1, #dir + 1) == dir .. "/"
      and not tp:find("[%z\n\r]") and not has_parent_segment(tp) then
    return tp
  end
  return dir .. "/" .. default_credential_name(provider)
end
-- Local alias for the call sites below (kept for readability).
local token_path_for = cloudsettings.token_path_for

-- write_token_file(path, payload) -> boolean
-- Creates the token file with mode 0600 from the start. It used to be written
-- with io.open("wb") — 0666 minus the umask, so typically 0644 — and narrowed
-- afterwards by shelling out to chmod, leaving the refresh token readable by
-- every other local user in between. Written to a fresh private temp name and
-- renamed over the destination, so a symlink at the destination is never
-- followed and a re-authentication never leaves a half-written token behind.
function cloudsettings.write_token_file(path, payload)
  if type(path) ~= "string" or path == "" then return false end
  local body = json.encode(payload or {})
  local temp = path .. "." .. (nonce.hex(8) or tostring(os.time())) .. ".tmp"
  if not privatefs.write_private(temp, body) then return false end
  local ok_rename = os.rename(temp, path)
  if not ok_rename then
    os.remove(temp)
    return false
  end
  return true
end

-- provider_credentials(provider, cfg) -> a copy of the provider table with the
-- client credentials overridden from config when the install supplies its own.
--
-- The shipped ids are the public rclone/clasp ones, shared with every other tool
-- that copied them: an installed desktop app's "secret" is public by definition,
-- but sharing them means sharing their rate limits and their revocation risk.
function cloudsettings.provider_credentials(provider, cfg)
  local base = PROVIDERS[provider]
  if not base then return nil end
  cfg = cfg or {}
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  local id = cfg[tostring(provider) .. "_client_id"]
  local secret = cfg[tostring(provider) .. "_client_secret"]
  if type(id) == "string" and id ~= "" then out.client_id = id end
  if type(secret) == "string" and secret ~= "" then out.client_secret = secret end
  return out
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

local function read_json_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local raw = f:read("*a") or ""
  f:close()
  local ok, value = pcall(json.decode, raw)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local function nonempty(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

local function static_credentials_valid(provider, value)
  if type(value) ~= "table" then return false end
  if provider == "r2" then
    return nonempty(value.account_id) and nonempty(value.access_key_id)
      and nonempty(value.secret_access_key) and nonempty(value.bucket)
  end
  if provider == "s3" then
    return nonempty(value.access_key_id) and nonempty(value.secret_access_key)
      and nonempty(value.bucket) and nonempty(value.endpoint)
      and nonempty(value.region)
  end
  return false
end

local function sanitized_credentials(provider, value)
  value = type(value) == "table" and value or {}
  local out = { has_secret = nonempty(value.secret_access_key) }
  local keys = provider == "r2"
    and { "account_id", "access_key_id", "bucket", "key_prefix", "endpoint" }
    or { "access_key_id", "bucket", "endpoint", "region", "key_prefix",
         "sign_payload", "allow_insecure_http", "allow_insecure_tls", "ca_cert_path" }
  for _, key in ipairs(keys) do out[key] = value[key] end
  if provider == "s3" then
    out.sign_payload = value.sign_payload == true
    out.allow_insecure_http = value.allow_insecure_http == true
    out.allow_insecure_tls = value.allow_insecure_tls == true
  end
  return out
end

local function provider_status(config_path, provider, cfg)
  if provider == "local" then return { authenticated = false } end
  if provider == "folder" then
    local path = cfg.sync_folder_path
    return {
      authenticated = nonempty(path) and lfs.attributes(path, "mode") == "directory",
      settings = { sync_folder_path = path or "" },
    }
  end
  local path = token_path_for(config_path, provider, cfg)
  if provider == "gdrive" or provider == "onedrive" then
    return {
      authenticated = has_refresh_token(path),
      pending = staged_tokens[provider] ~= nil,
    }
  end
  local value = read_json_file(path)
  return {
    authenticated = static_credentials_valid(provider, value),
    settings = sanitized_credentials(provider, value),
  }
end

-- ── RPC-facing operations (return JSON strings) ─────────────────────────────

-- status(config_path) -> {success, provider, authenticated, sync_achievements,
-- sync_playtime}. authenticated = the current provider's token file carries a
-- non-empty refresh_token (the only thing the hook needs; it re-mints access
-- tokens itself).
function cloudsettings.status(config_path)
  local cfg = cloudsettings.read_config(config_path)
  local provider = cfg.provider or "local"
  local providers = {}
  for _, name in ipairs({ "local", "folder", "gdrive", "onedrive", "r2", "s3" }) do
    providers[name] = provider_status(config_path, name, cfg)
  end
  local authed = providers[provider] and providers[provider].authenticated == true
  return json.encode({
    success = true,
    provider = provider,
    authenticated = authed,
    sync_achievements = cfg.sync_achievements == true,
    sync_playtime = cfg.sync_playtime == true,
    sync_activity = cfg.stats_sync_enabled ~= false and
      cfg.sync_achievements == true and cfg.sync_playtime == true,
    providers = providers,
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

-- Apply the complete Cloud Saves draft and immediately request a Steam
-- restart. Until this function runs, OAuth and UI edits are only staged. If the
-- restart helper refuses to launch, every changed file is restored.
function cloudsettings.apply_and_restart(config_path, request, deps)
  request = request or {}
  deps = deps or {}
  local provider = request.provider
  local supported = {
    ["local"] = true, folder = true, gdrive = true, onedrive = true,
    r2 = true, s3 = true,
  }
  if not supported[provider] then
    return json.encode({ success = false, error = "unknown provider" })
  end

  local cfg = cloudsettings.read_config(config_path)
  local source_provider = cfg.provider or "local"
  local snapshots = { { value = read_file_snapshot(config_path), private = false } }
  local final_token
  local staged_token
  if provider == "gdrive" or provider == "onedrive" then
    final_token = token_path_for(config_path, provider, cfg)
    staged_token = staged_tokens[provider]
    if not staged_token and not has_refresh_token(final_token) then
      return json.encode({ success = false, error = "provider not authenticated" })
    end
    snapshots[#snapshots + 1] = {
      value = read_file_snapshot(final_token), private = true,
    }
  elseif provider == "r2" or provider == "s3" then
    final_token = token_path_for(config_path, provider, cfg)
    snapshots[#snapshots + 1] = {
      value = read_file_snapshot(final_token), private = true,
    }
  end

  local sign_out = request.sign_out_provider
  local sign_out_path
  if supported[sign_out] and sign_out ~= "local" and sign_out ~= "folder" then
    sign_out_path = token_path_for(config_path, sign_out, cfg)
    if sign_out_path ~= final_token then
      snapshots[#snapshots + 1] = {
        value = read_file_snapshot(sign_out_path), private = true,
      }
    end
  end

  local function rollback()
    for i = #snapshots, 1, -1 do
      restore_file_snapshot(snapshots[i].value, snapshots[i].private)
    end
  end

  if staged_token then
    local f = io.open(staged_token, "rb")
    local raw = f and (f:read("*a") or "") or ""
    if f then f:close() end
    local ok_token, token = pcall(json.decode, raw)
    if not ok_token or type(token) ~= "table" or
        not cloudsettings.write_token_file(final_token, token) then
      rollback()
      return json.encode({ success = false, error = "cannot promote token" })
    end
  end


  if provider == "r2" or provider == "s3" then
    local supplied = type(request.credentials) == "table" and request.credentials or {}
    local previous = read_json_file(final_token) or {}
    local credentials = {}
    for key, value in pairs(supplied) do credentials[key] = value end
    if not nonempty(credentials.secret_access_key) then
      credentials.secret_access_key = previous.secret_access_key
    end
    if not static_credentials_valid(provider, credentials) then
      rollback()
      return json.encode({ success = false, error = "missing provider credentials" })
    end
    if not cloudsettings.write_token_file(final_token, credentials) then
      rollback()
      return json.encode({ success = false, error = "cannot write provider credentials" })
    end
  elseif provider == "folder" then
    local folder = request.sync_folder_path
    if not nonempty(folder) or folder:sub(1, 1) ~= "/" or folder:find("[%z\n\r]") then
      rollback()
      return json.encode({ success = false, error = "invalid sync folder" })
    end
    local quoted = "'" .. folder:gsub("'", "'\\''") .. "'"
    if os.execute("mkdir -p -- " .. quoted .. " 2>/dev/null") ~= true then
      rollback()
      return json.encode({ success = false, error = "cannot create sync folder" })
    end
    cfg.sync_folder_path = folder
  end

  if sign_out_path then os.remove(sign_out_path) end

  cfg.provider = provider
  cfg.stats_sync_enabled = request.sync_activity == true
  cfg.sync_achievements = request.sync_activity == true
  cfg.sync_playtime = request.sync_activity == true
  if final_token then
    if type(cfg.token_paths) ~= "table" then cfg.token_paths = {} end
    cfg.token_paths[provider] = final_token
  end
  if request.migrate == true and source_provider ~= provider and
      source_provider ~= "local" and provider ~= "local" and
      source_provider ~= "folder" then
    if type(cfg.token_paths) ~= "table" then cfg.token_paths = {} end
    cfg.token_paths[source_provider] = token_path_for(config_path, source_provider,
      cloudsettings.read_config(config_path))
  end
  local ok_write, write_err = write_config(config_path, cfg)
  if not ok_write then
    rollback()
    return json.encode({ success = false, error = tostring(write_err) })
  end


  if provider == "r2" or provider == "s3" then
    local probe = deps.probe
    local probe_ok, probe_err
    if type(probe) == "function" then
      local called, a, b = pcall(probe, provider, config_path)
      probe_ok, probe_err = called and a == true, called and b or a
    else
      probe_ok, probe_err = cloudsettings.probe_provider(config_path, provider)
    end
    if not probe_ok then
      rollback()
      return json.encode({ success = false, error = tostring(probe_err or "connection test failed") })
    end
  end


  if request.migrate == true and source_provider ~= provider and
      source_provider ~= "local" and provider ~= "local" then
    local migrate = deps.migrate
    local migrated, migration_result
    if type(migrate) == "function" then
      local called, a, b = pcall(migrate, source_provider, provider, config_path)
      migrated, migration_result = called and a == true, called and b or a
    else
      migrated, migration_result = cloudsettings.migrate_providers(
        config_path, source_provider, provider)
    end
    if not migrated then
      rollback()
      return json.encode({ success = false,
        error = tostring(migration_result or "migration failed") })
    end
  end

  local restart = deps.restart
  local ok_restart, restart_err = false, "restart unavailable"
  if type(restart) == "function" then
    local called, a, b = pcall(restart)
    if called then ok_restart, restart_err = a == true, b
    else restart_err = a end
  end
  if not ok_restart then
    rollback()
    return json.encode({ success = false, error = tostring(restart_err or "restart failed") })
  end

  for staged_provider, path in pairs(staged_tokens) do
    os.remove(path)
    staged_tokens[staged_provider] = nil
  end
  return json.encode({ success = true, restarting = true })
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function cloudsettings.default_cli_path()
  local home = os.getenv("HOME") or ""
  if home == "" then return nil end
  return home .. "/.local/share/CloudRedirect/cloud_redirect_cli"
end

local function last_json_object(output)
  local result
  for line in tostring(output or ""):gmatch("[^\n]+") do
    local ok, value = pcall(json.decode, line)
    if ok and type(value) == "table" then result = value end
  end
  return result
end

function cloudsettings.probe_provider(config_path, provider, deps)
  deps = deps or {}
  local cli = deps.cli_path or cloudsettings.default_cli_path()
  if not cli or lfs.attributes(cli, "mode") ~= "file" then
    return false, "CloudRedirect CLI not installed"
  end
  local exec = deps.exec or utils.exec
  local out, command_ok = exec(shell_quote(cli) .. " list-remote-app-ids " ..
    shell_quote(provider) .. " 0 2>/dev/null")
  local result = last_json_object(out)
  if not command_ok or type(result) ~= "table" or result.success ~= true then
    return false, type(result) == "table" and result.error or "connection test failed"
  end
  return true
end

function cloudsettings.migrate_providers(config_path, source, destination, deps)
  deps = deps or {}
  -- `migrate` streams JSON lines rather than one response object. Run it once
  -- directly and inspect the authoritative final `complete` record.
  local cli = deps.cli_path or cloudsettings.default_cli_path()
  if not cli or lfs.attributes(cli, "mode") ~= "file" then
    return false, "CloudRedirect CLI not installed"
  end
  local exec = deps.exec or utils.exec
  local out = exec(shell_quote(cli) .. " migrate " .. shell_quote(source) .. " " ..
    shell_quote(destination) .. " 2>/dev/null")
  local complete, err
  for line in tostring(out or ""):gmatch("[^\n]+") do
    local ok, value = pcall(json.decode, line)
    if ok and type(value) == "table" and value.type == "complete" then complete = value end
    if ok and type(value) == "table" and value.type == "error" and not value.file then
      err = value.message or err
    end
  end
  if not complete or tonumber(complete.failed) ~= 0 then
    return false, err or (complete and "migration completed with errors" or "migration failed")
  end
  return true, complete
end

local function cli_json(command, args, deps)
  deps = deps or {}
  local cli = deps.cli_path or cloudsettings.default_cli_path()
  if not cli or lfs.attributes(cli, "mode") ~= "file" then
    return nil, "CloudRedirect CLI not installed"
  end
  local parts = { shell_quote(cli), command }
  for _, value in ipairs(args or {}) do parts[#parts + 1] = shell_quote(value) end
  local exec = deps.exec or utils.exec
  local out, command_ok = exec(table.concat(parts, " ") .. " 2>/dev/null")
  local result = last_json_object(out)
  if type(result) ~= "table" then
    return nil, command_ok and "invalid CLI response" or "CloudRedirect CLI failed"
  end
  if result.success ~= true then return nil, result.error or "provider operation failed" end
  return result
end

local function folder_appids(root, account)
  local path = tostring(root or "") .. "/" .. tostring(account)
  if lfs.attributes(path, "mode") ~= "directory" then return {} end
  local ids = {}
  local ok = pcall(function()
    for name in lfs.dir(path) do
      local id = math.tointeger(tonumber(name))
      if id and id > 0 and lfs.attributes(path .. "/" .. name, "mode") == "directory" then
        ids[#ids + 1] = id
      end
    end
  end)
  if not ok then return nil, "cannot list sync folder" end
  table.sort(ids)
  return ids
end

function cloudsettings.discard_pending()
  for provider, path in pairs(staged_tokens) do
    os.remove(path)
    staged_tokens[provider] = nil
  end
  return json.encode({ success = true })
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
  local auth_url = cloudsettings.build_auth_url(provider, redirect_uri, state,
    challenge, cloudsettings.read_config(config_path))

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
  local cfg = cloudsettings.read_config(config_path)
  local body = cloudsettings.token_request_body(provider, code,
    pending.redirect_uri, pending.verifier, cfg)
  local resp, herr = d.http.post(
    cloudsettings.provider_credentials(provider, cfg).token_url, body, {
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
  local staged_file = token_file .. ".lumen-pending"
  if not cloudsettings.write_token_file(staged_file, {
        access_token = tok.access_token or "",
        refresh_token = tok.refresh_token,
        expires_at = d.now() + expires_in,
      }) then
    return finish({ status = "error", error = "cannot write token" })
  end

  staged_tokens[provider] = staged_file
  return finish({ status = "done", authenticated = true, pending = true })
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

-- lfs only. The shell fallback that used to sit here quoted the path correctly,
-- but a shell-out that can never be reached (lfs is linked into the binary) is
-- still one more place a future path has to stay quoted in.
local function list_dir(dir)
  local names = {}
  if type(dir) ~= "string" or dir == "" then return names end
  local ok_lfs, lfs = pcall(require, "lfs")
  if not ok_lfs then return names end
  pcall(function()
    for e in lfs.dir(dir) do
      if e ~= "." and e ~= ".." then names[#names + 1] = e end
    end
  end)
  return names
end

-- Count save files + total bytes under an app dir, excluding CloudRedirect's
-- metadata files. Walks the tree with lfs rather than spawning `find`: the path
-- comes from the hook's storage root, and quoting it correctly forever is a
-- weaker guarantee than not involving a shell.
local function scan_app_dir(dir)
  local files, size = 0, 0
  local ok_lfs, lfs = pcall(require, "lfs")
  if not ok_lfs then return 0, 0 end
  -- symlinkattributes, not attributes: `find` without -L did not follow links,
  -- and following them here would let a symlink pointing at an ancestor recurse
  -- until Lua overflows its stack, turning a stats read into an RPC error. The
  -- depth cap is a second belt for a deep tree.
  local MAX_DEPTH = 32
  local function walk(current, relative, depth)
    if depth > MAX_DEPTH then return end
    for _, entry in ipairs(list_dir(current)) do
      local full = current .. "/" .. entry
      local rel = (relative == "") and entry or (relative .. "/" .. entry)
      local mode = lfs.symlinkattributes(full, "mode")
      if mode == "directory" then
        walk(full, rel, depth + 1)
      elseif mode == "file" then
        if not is_storage_metadata(rel) then
          files = files + 1
          size = size + (lfs.symlinkattributes(full, "size") or 0)
        end
      end
    end
  end
  walk(dir, "", 0)
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
  local acct = math.tointeger(tonumber(account))
  if not acct then return json.encode({ success = false, error = "bad account" }) end
  if provider == "folder" then
    local appids, err = folder_appids(cfg.sync_folder_path, acct)
    if not appids then return json.encode({ success = false, error = err, provider = provider }) end
    return json.encode({ success = true, appids = json.array(appids), provider = provider })
  end
  if provider == "r2" or provider == "s3" then
    local result, err = cli_json("list-remote-app-ids", { provider, tostring(acct) }, deps)
    if not result then return json.encode({ success = false, error = err, provider = provider }) end
    local appids = {}
    for _, raw in ipairs(type(result.app_ids) == "table" and result.app_ids or {}) do
      local id = math.tointeger(tonumber(raw))
      if id and id > 0 then appids[#appids + 1] = id end
    end
    table.sort(appids)
    return json.encode({ success = true, appids = json.array(appids), provider = provider })
  end
  if provider ~= "gdrive" and provider ~= "onedrive" then
    return json.encode({ success = true, appids = json.array({}),
                         provider = provider, reason = "local" })
  end
  local rt = read_refresh_token(config_path, provider, cfg)
  if not rt then
    return json.encode({ success = false, reason = "not_authenticated", provider = provider })
  end
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

-- register(registry[, config_path]): install the Cloud Saves RPCs. The path
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
  registry.LumenCloudApplyAndRestart = function(j)
    local request = decode_arg(j)
    return cloudsettings.apply_and_restart(cp, request, {
      restart = function()
        if type(registry.RestartSteam) ~= "function" then
          return false, "restart unavailable"
        end
        local ok, raw = pcall(registry.RestartSteam)
        if not ok then return false, raw end
        local parsed_ok, result = pcall(json.decode, raw)
        if not parsed_ok or type(result) ~= "table" or result.success ~= true then
          return false, type(result) == "table" and result.error or "restart failed"
        end
        return true
      end,
    })
  end
  registry.LumenCloudDiscardPending = function()
    return cloudsettings.discard_pending()
  end
  registry.LumenCloudOpenUrl = function(j)
    return cloudsettings.open_url(decode_arg(j).url)
  end
  registry.LumenCloudApps = function() return cloudsettings.list_apps() end
  registry.LumenCloudRemoteApps = function(j)
    local r = decode_arg(j)
    -- The settings list only needs presence to decide local/cloud/synced.
    -- Per-app metadata turns this into dozens of provider requests, while the
    -- folder-only path returns the complete remote set in one short flow.
    return cloudsettings.remote_appids(cp, r.account)
  end
  return registry
end

return cloudsettings
