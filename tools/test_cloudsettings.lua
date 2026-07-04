-- Run: lua5.4 tools/test_cloudsettings.lua
-- Backend for the Cloud Saves tab. Reads/writes the CloudRedirect file contract
-- (~/.config/CloudRedirect/config.json + tokens_<provider>.json) directly in
-- Lua — no hook --cli, no flatpak. Also the OAuth2 authorization-code + PKCE
-- flow ported from CloudRedirect's OAuthService.cs. All RPCs return JSON
-- strings (the callServerMethod convention). Pure helpers + a fake-socket /
-- fake-http state machine keep it host-testable.
package.path = "lua/?.lua;" .. package.path
local cs = require("cloudsettings")
local json = require("json")
local sha256 = require("sha256")
local b64 = require("b64")

local function ok(c, m) if not c then error("FAIL: " .. (m or "")) end end
local function eq(g, w, m)
  if g ~= w then error("FAIL: " .. (m or "") .. " (got=" .. tostring(g) ..
    " want=" .. tostring(w) .. ")") end
end
local function tmpfile(contents)
  local p = os.tmpname()
  local f = assert(io.open(p, "wb")); f:write(contents or ""); f:close()
  return p
end

-- ── PKCE S256 challenge = base64url(sha256(verifier)), no padding ───────────
do
  local verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  local want = (b64.encode(sha256.digest(verifier))
                 :gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
  eq(cs.pkce_challenge(verifier), want, "pkce challenge")
  ok(not cs.pkce_challenge(verifier):find("="), "no padding in challenge")
  ok(not cs.pkce_challenge(verifier):find("[+/]"), "url-safe alphabet only")
end

-- ── auth URL carries the required OAuth params, url-encoded ─────────────────
do
  local u = cs.build_auth_url("gdrive", "http://localhost:1234/callback", "STATE1", "CHAL1")
  ok(u:find("https://accounts.google.com/o/oauth2/v2/auth", 1, true), "gdrive auth endpoint")
  ok(u:find("response_type=code", 1, true), "response_type")
  ok(u:find("client_id=1072944905499", 1, true), "gdrive client id")
  ok(u:find("code_challenge=CHAL1", 1, true), "challenge")
  ok(u:find("code_challenge_method=S256", 1, true), "S256")
  ok(u:find("state=STATE1", 1, true), "state")
  ok(u:find("access_type=offline", 1, true), "gdrive offline")
  ok(u:find("prompt=consent", 1, true), "consent")
  -- redirect uri percent-encoded (":" and "/" escaped)
  ok(u:find("redirect_uri=http%%3A%%2F%%2Flocalhost%%3A1234%%2Fcallback", 1, false),
    "redirect uri encoded")

  local o = cs.build_auth_url("onedrive", "http://localhost:53682/", "S2", "C2")
  ok(o:find("login.microsoftonline.com", 1, true), "onedrive endpoint")
  ok(o:find("client_id=b15665d9", 1, true), "onedrive client id")
  ok(not o:find("access_type", 1, true), "onedrive has no access_type")
end

-- ── token exchange request body (form-encoded) ──────────────────────────────
do
  local body = cs.token_request_body("gdrive", "AUTHCODE", "http://localhost:9/callback", "VER")
  ok(body:find("grant_type=authorization_code", 1, true), "grant type")
  ok(body:find("code=AUTHCODE", 1, true), "code")
  ok(body:find("code_verifier=VER", 1, true), "verifier")
  ok(body:find("client_secret=", 1, true), "client secret present")
  ok(not body:find("scope=", 1, true), "gdrive body omits scope")

  local ob = cs.token_request_body("onedrive", "C", "http://localhost:53682/", "V")
  ok(ob:find("scope=", 1, true), "onedrive body includes scope")
end

-- ── parse the OAuth callback HTTP request line ──────────────────────────────
do
  local code, state = cs.parse_callback("GET /callback?code=abc123&state=xyz HTTP/1.1")
  eq(code, "abc123", "parsed code")
  eq(state, "xyz", "parsed state")
  -- order-independent + percent-decoding
  local c2, s2 = cs.parse_callback("GET /?state=s%20p&code=a%2Bb HTTP/1.1")
  eq(c2, "a+b", "url-decoded code")
  eq(s2, "s p", "url-decoded state")
  -- error param, no code
  local c3, s3, err = cs.parse_callback("GET /callback?error=access_denied&state=x HTTP/1.1")
  eq(c3, nil, "no code on error")
  eq(err, "access_denied", "parsed error")
end

-- ── read_config: missing file yields defaults (provider=local) ──────────────
do
  local cfg = cs.read_config("/nonexistent/nope.json")
  eq(cfg.provider, "local", "default provider local")
end

-- ── status: no token file => not authenticated ─────────────────────────────
do
  local p = tmpfile('{"provider":"gdrive"}')
  local st = json.decode(cs.status(p))
  eq(st.success, true, "status success")
  eq(st.provider, "gdrive", "status provider")
  eq(st.authenticated, false, "not authenticated without token")
  os.remove(p)
end

-- ── status: token file with refresh_token => authenticated ─────────────────
do
  local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p '" .. dir .. "'"))
  local cfgp = dir .. "/config.json"
  local f = io.open(cfgp, "wb"); f:write('{"provider":"gdrive"}'); f:close()
  local tf = io.open(dir .. "/tokens_gdrive.json", "wb")
  tf:write('{"refresh_token":"RT","access_token":"AT","expires_at":9999999999}'); tf:close()
  local st = json.decode(cs.status(cfgp))
  eq(st.authenticated, true, "authenticated with refresh token")
  os.execute("rm -rf '" .. dir .. "'")
end

-- ── set_provider writes provider, preserves other keys ──────────────────────
do
  local p = tmpfile('{"provider":"local","upload_inflight_mb":24,"notifications_enabled":true}')
  local res = json.decode(cs.set_provider(p, "onedrive"))
  eq(res.success, true, "set_provider success")
  local cfg = cs.read_config(p)
  eq(cfg.provider, "onedrive", "provider written")
  eq(cfg.upload_inflight_mb, 24, "unrelated int key preserved")
  eq(cfg.notifications_enabled, true, "unrelated bool key preserved")
  os.remove(p)
end

-- ── set_provider rejects an unknown provider ────────────────────────────────
do
  local p = tmpfile('{"provider":"local"}')
  local res = json.decode(cs.set_provider(p, "dropbox"))
  eq(res.success, false, "unknown provider rejected")
  eq(cs.read_config(p).provider, "local", "config unchanged")
  os.remove(p)
end

-- ── set_provider creates a default config when the file is absent ───────────
do
  local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p '" .. dir .. "'"))
  local cfgp = dir .. "/config.json"
  local res = json.decode(cs.set_provider(cfgp, "gdrive"))
  eq(res.success, true, "creates config when missing")
  eq(cs.read_config(cfgp).provider, "gdrive", "provider persisted to new file")
  os.execute("rm -rf '" .. dir .. "'")
end

-- ── set_toggle only accepts the two stats keys ──────────────────────────────
do
  local p = tmpfile('{"provider":"gdrive"}')
  eq(json.decode(cs.set_toggle(p, "sync_achievements", true)).success, true, "achievements ok")
  eq(json.decode(cs.set_toggle(p, "sync_playtime", true)).success, true, "playtime ok")
  eq(cs.read_config(p).sync_achievements, true, "achievements persisted")
  eq(cs.read_config(p).sync_playtime, true, "playtime persisted")
  -- schema_fetch and arbitrary keys are rejected (never written)
  eq(json.decode(cs.set_toggle(p, "schema_fetch", false)).success, false, "schema_fetch rejected")
  eq(json.decode(cs.set_toggle(p, "stats_sync_enabled", false)).success, false, "master rejected")
  eq(cs.read_config(p).schema_fetch, nil, "schema_fetch not written")
  os.remove(p)
end

-- ── sign_out deletes the token file and resets provider to local ────────────
do
  local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p '" .. dir .. "'"))
  local cfgp = dir .. "/config.json"
  local f = io.open(cfgp, "wb"); f:write('{"provider":"gdrive"}'); f:close()
  local tp = dir .. "/tokens_gdrive.json"
  local tf = io.open(tp, "wb"); tf:write('{"refresh_token":"RT"}'); tf:close()
  local res = json.decode(cs.sign_out(cfgp, "gdrive"))
  eq(res.success, true, "sign_out success")
  eq(cs.read_config(cfgp).provider, "local", "provider reset to local")
  ok(io.open(tp, "rb") == nil, "token file deleted")
  os.execute("rm -rf '" .. dir .. "'")
end

-- ── authorize/auth_poll state machine with fake socket + http ───────────────
-- Fake a listener whose accept() first times out (waiting), then returns a
-- client delivering the OAuth redirect. Fake http returns a token JSON.
do
  local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p '" .. dir .. "'"))
  local cfgp = dir .. "/config.json"

  local sent_response = false
  local captured_state
  local function make_client(reqline)
    return {
      receive = function(_, pat) return reqline end,
      send = function(_, data) sent_response = true; return #data end,
      close = function() end,
      settimeout = function() end,
    }
  end

  local accept_calls = 0
  local fake_listener = {
    settimeout = function() end,
    getsockname = function() return "127.0.0.1", 45999 end,
    bind = function() return 1 end,
    listen = function() return 1 end,
    close = function() end,
    accept = function()
      accept_calls = accept_calls + 1
      if accept_calls == 1 then return nil, "timeout" end
      -- second poll: deliver the redirect with the state we generated
      return make_client("GET /callback?code=THECODE&state=" .. captured_state .. " HTTP/1.1\r\n")
    end,
  }
  local fake_socket = { tcp = function() return fake_listener end }

  local opened
  local fake_http = {
    post = function(url, body, opts)
      ok(url:find("oauth2.googleapis.com/token", 1, true), "posts to token endpoint")
      ok(body:find("code=THECODE", 1, true), "posts the received code")
      return { status = 200,
        body = '{"access_token":"AT","refresh_token":"RT","expires_in":3600}' }
    end,
  }

  local seq = 0
  local deps = {
    socket = fake_socket,
    http = fake_http,
    now = function() return 1000 end,
    open_url = function(u) opened = u end,
    gen_random = function(n) seq = seq + 1; return "RAND" .. seq .. "_" .. n end,
  }

  local a = json.decode(cs.authorize(cfgp, "gdrive", deps))
  eq(a.status, "waiting", "authorize returns waiting")
  ok(a.auth_url and a.auth_url:find("accounts.google.com", 1, true), "authorize returns the auth url")
  -- authorize no longer opens the browser itself (the frontend drives a
  -- focus-carrying open via Steam); the URL is returned for it to use.
  eq(opened, nil, "authorize does not open the browser itself")
  -- recover the state we generated for the callback the fake will echo back
  captured_state = a.auth_url:match("state=([^&]+)")
  ok(captured_state ~= nil, "state captured from auth url")

  local p1 = json.decode(cs.auth_poll(deps))
  eq(p1.status, "waiting", "first poll still waiting (accept timeout)")

  local p2 = json.decode(cs.auth_poll(deps))
  eq(p2.status, "done", "second poll completes")
  eq(p2.authenticated, true, "authenticated after exchange")
  ok(sent_response, "browser got the closing response")

  -- token file + provider written
  local tf = io.open(dir .. "/tokens_gdrive.json", "rb")
  ok(tf ~= nil, "token file written")
  local tok = json.decode(tf:read("*a")); tf:close()
  eq(tok.refresh_token, "RT", "refresh token stored")
  eq(tok.access_token, "AT", "access token stored")
  eq(tok.expires_at, 1000 + 3600, "expires_at = now + expires_in")
  eq(cs.read_config(cfgp).provider, "gdrive", "provider set after auth")

  os.execute("rm -rf '" .. dir .. "'")
end

-- ── auth_poll reports timeout past the deadline ─────────────────────────────
do
  local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p '" .. dir .. "'"))
  local cfgp = dir .. "/config.json"
  local fake_listener = {
    settimeout = function() end,
    getsockname = function() return "127.0.0.1", 46000 end,
    bind = function() return 1 end, listen = function() return 1 end,
    close = function() end,
    accept = function() return nil, "timeout" end,
  }
  local t = 1000
  local deps = {
    socket = { tcp = function() return fake_listener end },
    http = { post = function() error("should not exchange") end },
    now = function() return t end,
    open_url = function() end,
    gen_random = function(n) return "R" .. n end,
  }
  json.decode(cs.authorize(cfgp, "onedrive", deps))
  eq(json.decode(cs.auth_poll(deps)).status, "waiting", "waiting before deadline")
  t = 1000 + 10 * 60 -- 10 minutes later, well past the 5-min timeout
  eq(json.decode(cs.auth_poll(deps)).status, "timeout", "timeout past deadline")
  -- a poll with no pending auth is idle
  eq(json.decode(cs.auth_poll(deps)).status, "idle", "idle when nothing pending")
  os.execute("rm -rf '" .. dir .. "'")
end

-- ── register() + the real RPC dispatch path (Millennium arg convention) ─────
-- The frontend sends a SINGLE {json: JSON.stringify(payload)} arg; the
-- dispatcher (rpc.lua) sorts keys alphabetically and passes their VALUES
-- positionally, so the registered wrapper receives the json STRING and must
-- decode it. This guards the "unknown provider" regression where the wrapper
-- wrongly treated the positional string as an args table.
do
  local rpc = require("rpc")
  local p = tmpfile('{"provider":"local"}')
  local registry = {}
  cs.register(registry, p)

  local ok1, res1 = rpc.dispatch(registry.LumenCloudSetProvider,
    { json = json.encode({ provider = "onedrive" }) })
  ok(ok1, "SetProvider dispatch did not error")
  eq(json.decode(res1).success, true, "SetProvider via dispatch succeeds")
  eq(cs.read_config(p).provider, "onedrive", "provider persisted via dispatch")

  local ok2, res2 = rpc.dispatch(registry.LumenCloudSetToggle,
    { json = json.encode({ key = "sync_playtime", value = true }) })
  ok(ok2, "SetToggle dispatch did not error")
  eq(json.decode(res2).success, true, "SetToggle via dispatch succeeds")
  eq(cs.read_config(p).sync_playtime, true, "toggle persisted via dispatch")

  local _, res3 = rpc.dispatch(registry.LumenCloudStatus, {})
  eq(json.decode(res3).provider, "onedrive", "Status via dispatch reads provider")

  local _, res4 = rpc.dispatch(registry.LumenCloudSignOut,
    { json = json.encode({ provider = "onedrive" }) })
  eq(json.decode(res4).success, true, "SignOut via dispatch succeeds")
  eq(cs.read_config(p).provider, "local", "SignOut reset provider via dispatch")
  os.remove(p)
end

-- ── remote_appids: provider/auth gating + delegation to cloudremote ─────────
do
  -- local provider => no remote enumeration, empty appids (quietly).
  local p = tmpfile('{"provider":"local"}')
  local r = json.decode(cs.remote_appids(p, 1))
  eq(r.success, true, "local provider remote ok")
  eq(#r.appids, 0, "local provider has no remote appids")
  os.remove(p)

  -- gdrive but no token file => not_authenticated.
  local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p '" .. dir .. "'"))
  local cfgp = dir .. "/config.json"
  local f = io.open(cfgp, "wb"); f:write('{"provider":"gdrive"}'); f:close()
  local na = json.decode(cs.remote_appids(cfgp, 1052518393))
  eq(na.success, false, "gdrive without token fails")
  eq(na.reason, "not_authenticated", "reason is not_authenticated")

  -- gdrive with a token => delegates to cloudremote (fake http returns appids).
  local tf = io.open(dir .. "/tokens_gdrive.json", "wb")
  tf:write('{"refresh_token":"RT","access_token":"AT","expires_at":9999999999}'); tf:close()
  local fake = {
    post = function() return { status = 200, body = '{"access_token":"ATOK","expires_in":3599}' } end,
    get = function(url)
      if url:find("CloudRedirect", 1, true) and url:find("root", 1, true) then
        return { status = 200, body = json.encode({ files = { { id = "R", name = "CloudRedirect",
          mimeType = "application/vnd.google-apps.folder" } } }) }
      elseif url:find("1052518393", 1, true) then
        return { status = 200, body = json.encode({ files = { { id = "A", name = "1052518393",
          mimeType = "application/vnd.google-apps.folder" } } }) }
      else
        return { status = 200, body = json.encode({ files = {
          { id = "x", name = "250900", mimeType = "application/vnd.google-apps.folder" } } }) }
      end
    end,
  }
  local rr = json.decode(cs.remote_appids(cfgp, 1052518393, { http = fake }))
  eq(rr.success, true, "gdrive with token succeeds")
  ok(rr.appids[1] == 250900, "remote appid enumerated via cloudremote")
  os.execute("rm -rf '" .. dir .. "'")
end

print("test_cloudsettings: ALL PASS")
