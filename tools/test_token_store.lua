-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_token_store.lua
--
-- The cloud OAuth refresh token was written with io.open(path, "wb") — mode
-- 0666 minus the umask, so typically 0644 — and narrowed to 0600 only afterwards
-- by shelling out to chmod. Between those two steps the refresh token was
-- readable by every other local user. And token_path_for honoured an ABSOLUTE
-- cfg.token_path from config.json, so whoever could write that file also chose
-- where the token landed.
package.path = "lua/?.lua;" .. package.path
local lfs = require("lfs")
local cloudsettings = require("cloudsettings")

local checks = 0
local function ok(c, m)
  checks = checks + 1
  if not c then error("FAIL: " .. (m or "")) end
end

local base = (os.getenv("TMPDIR") or "/tmp") .. "/lumen-tokenstore-"
             .. tostring(os.time()) .. "-" .. tostring(math.random(1e6))
lfs.mkdir(base)
local config_path = base .. "/config"

-- ── token_path_for containment ──────────────────────────────────────────────
do
  local p = cloudsettings.token_path_for(config_path, "gdrive", {})
  ok(p == base .. "/tokens_gdrive.json",
    "default token path sits beside the config: " .. tostring(p))
end

do
  -- A relative override stays inside the config directory.
  local p = cloudsettings.token_path_for(config_path, "gdrive",
    { provider = "gdrive", token_path = "mytokens.json" })
  ok(p == base .. "/mytokens.json", "a relative override is honoured")
end

do
  -- Per-provider paths take precedence, matching CloudRedirect's resolver.
  local p = cloudsettings.token_path_for(config_path, "gdrive", {
    token_path = "legacy.json",
    token_paths = { gdrive = "providers/google.json" },
  })
  ok(p == base .. "/providers/google.json",
    "token_paths[provider] wins over the legacy token_path")
end

do
  local p = cloudsettings.token_path_for(config_path, "gdrive", {
    token_paths = { gdrive = base .. "/providers/google.json" },
  })
  ok(p == base .. "/providers/google.json",
    "an absolute registered path inside the config directory is honoured")
  local escaped = cloudsettings.token_path_for(config_path, "gdrive", {
    token_paths = { gdrive = base .. "/../escape.json" },
  })
  ok(escaped == base .. "/tokens_gdrive.json",
    "an absolute registered path cannot traverse out of the config directory")
end

do
  ok(cloudsettings.token_path_for(config_path, "r2", {}) ==
      base .. "/r2_credentials.json", "R2 uses the upstream credential filename")
  ok(cloudsettings.token_path_for(config_path, "s3", {}) ==
      base .. "/s3_credentials.json", "S3 uses the upstream credential filename")
end

do
  -- An absolute override is refused: it let config.json choose any path on the
  -- filesystem for a file holding a long-lived credential.
  local p = cloudsettings.token_path_for(config_path, "gdrive",
    { provider = "gdrive", token_path = "/tmp/anywhere.json" })
  ok(p == base .. "/tokens_gdrive.json", "an absolute override is ignored")
end

do
  -- ...and neither can a relative one climb out with "..".
  for _, bad in ipairs({ "../escape.json", "a/../../escape.json",
                         "./../escape.json", "sub/../../escape.json" }) do
    local p = cloudsettings.token_path_for(config_path, "gdrive",
      { provider = "gdrive", token_path = bad })
    ok(p == base .. "/tokens_gdrive.json",
      "a traversing override is ignored: " .. bad)
  end
end

do
  -- A path with a separator but no traversal is allowed (a subdirectory is fine).
  local p = cloudsettings.token_path_for(config_path, "gdrive",
    { provider = "gdrive", token_path = "sub/tokens.json" })
  ok(p == base .. "/sub/tokens.json", "a subdirectory override is honoured")
end

do
  for _, bad in ipairs({ "tok\0ens.json", "tok\nens.json", "" }) do
    local p = cloudsettings.token_path_for(config_path, "gdrive",
      { provider = "gdrive", token_path = bad })
    ok(p == base .. "/tokens_gdrive.json",
      "a malformed override is ignored")
  end
end

-- ── the token file is created private ───────────────────────────────────────
do
  local path = base .. "/tokens_gdrive.json"
  ok(cloudsettings.write_token_file(path, { refresh_token = "SECRET" }) == true,
    "writes the token file")
  ok(lfs.attributes(path, "permissions") == "rw-------",
    "token file is 0600 from creation, got "
      .. tostring(lfs.attributes(path, "permissions")))
  local f = assert(io.open(path, "rb"))
  local body = f:read("*a")
  f:close()
  ok(body:find("SECRET", 1, true) ~= nil, "the token round-trips")
end

do
  -- Re-authenticating replaces an existing token file rather than failing.
  local path = base .. "/tokens_gdrive.json"
  ok(cloudsettings.write_token_file(path, { refresh_token = "SECOND" }) == true,
    "an existing token file is replaced")
  ok(lfs.attributes(path, "permissions") == "rw-------",
    "the replacement is also 0600")
  local f = assert(io.open(path, "rb"))
  local body = f:read("*a")
  f:close()
  ok(body:find("SECOND", 1, true) ~= nil, "the new token is stored")
  ok(body:find("SECRET", 1, true) == nil, "the old token is gone")
end

do
  -- A symlink in place of the token file must not be followed: the write would
  -- otherwise land on its target.
  local victim = base .. "/victim"
  local vf = assert(io.open(victim, "wb")); vf:write("original"); vf:close()
  local link = base .. "/tokens_link.json"
  os.execute("ln -sfn " .. victim .. " " .. link)
  cloudsettings.write_token_file(link, { refresh_token = "PAYLOAD" })
  local f = assert(io.open(victim, "rb"))
  local body = f:read("*a")
  f:close()
  ok(body == "original", "a symlinked token path leaves its target untouched")
end

do
  ok(cloudsettings.write_token_file(base .. "/missing/deep/t.json",
    { refresh_token = "x" }) == false, "an unwritable path reports failure")
end

-- ── provider credentials can be overridden ──────────────────────────────────
-- The shipped client_id/client_secret are the public rclone/clasp ones, shared
-- with every other tool that copied them: they are rate-limited and revocable by
-- third-party abuse. They are a public client's credentials by design, so the fix
-- is not to hide them but to let an install use its own.
do
  local cfg = { gdrive_client_id = "OWN-ID", gdrive_client_secret = "OWN-SECRET" }
  local p = cloudsettings.provider_credentials("gdrive", cfg)
  ok(p.client_id == "OWN-ID", "a configured client id is used")
  ok(p.client_secret == "OWN-SECRET", "a configured client secret is used")
  local d = cloudsettings.provider_credentials("gdrive", {})
  ok(type(d.client_id) == "string" and d.client_id ~= "",
    "the shipped default remains when nothing is configured")
  ok(d.client_id ~= "OWN-ID", "the default is not the override")
  ok(cloudsettings.provider_credentials("nope", {}) == nil,
    "an unknown provider has no credentials")
end

os.execute("rm -rf " .. base)
print("test_token_store: ALL PASS (" .. checks .. " checks)")
