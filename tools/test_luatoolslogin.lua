package.path = "lua/?.lua;" .. package.path

local login = require("luatoolslogin")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

local valid = "https://db.lua.tools/auth/v1/authorize?provider=discord" ..
  "&redirect_to=http%3A%2F%2Flocalhost%3A53789%2Fcallback" ..
  "&code_challenge=test&code_challenge_method=s256"
check("L1 only the official lua.tools Discord authorize URL is accepted",
  login.safe_auth_url(valid) == valid)
check("L2 lookalike and arbitrary redirect URLs are rejected",
  login.safe_auth_url("https://db.lua.tools.evil.invalid/auth/v1/authorize?provider=discord") == nil
    and login.safe_auth_url("https://db.lua.tools/auth/v1/authorize?provider=other") == nil
    and login.safe_auth_url("https://db.lua.tools/auth/v1/authorize?provider=discord&redirect_to=https://evil.invalid") == nil)

local windows = login.login_windows({
  { id = "supabase", url = valid, webSocketDebuggerUrl = "ws://one" },
  { id = "discord", url = "https://discord.com/oauth2/authorize?redirect_to=http%3A%2F%2Flocalhost%3A53789", webSocketDebuggerUrl = "ws://two" },
  { id = "callback", url = "http://localhost:53789/callback?code=x", webSocketDebuggerUrl = "ws://three" },
  { id = "unrelated", url = "https://discord.com/channels/@me", webSocketDebuggerUrl = "ws://four" },
})
check("L3 cleanup tracks only windows belonging to this OAuth round trip", #windows == 3)

local specs = login.discord_cookie_deletions({ cookies = {
  { name = "sid", domain = ".discord.com", path = "/", partitionKey = "p" },
  { name = "canary", domain = "canary.discord.com", path = "/" },
  { name = "steamLoginSecure", domain = "steamcommunity.com", path = "/" },
  { name = "sb-refresh-token", domain = "db.lua.tools", path = "/" },
} })
check("L4 cookie cleanup includes Discord and its subdomains only", #specs == 2)
check("L5 cookie deletion preserves the exact domain, path and partition key",
  specs[1].name == "sid" and specs[1].domain == ".discord.com"
    and specs[1].path == "/" and specs[1].partitionKey == "p")

local origins = login.discord_storage_origins()
check("L6 storage cleanup is an explicit Discord-origin allowlist",
  origins[1] == "https://discord.com" and origins[2] == "https://canary.discord.com"
    and origins[3] == "https://ptb.discord.com" and #origins == 3)

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS LOGIN SECURITY CHECKS PASSED")
