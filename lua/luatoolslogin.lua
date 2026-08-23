local luatoolslogin = {}

local CALLBACK = "http://localhost:53789/callback"
local DISCORD_ORIGINS = {
  "https://discord.com",
  "https://canary.discord.com",
  "https://ptb.discord.com",
}

local function urldecode(value)
  value = tostring(value or ""):gsub("+", " ")
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function query_params(url)
  local query = tostring(url or ""):match("%?([^#]*)") or ""
  local params = {}
  for key, value in query:gmatch("([^&=]+)=([^&]*)") do
    params[urldecode(key)] = urldecode(value)
  end
  return params
end

local function origin_host(url)
  return tostring(url or ""):match("^https?://([^/%?#]+)")
end

local function discord_host(host)
  host = tostring(host or ""):lower()
  return host == "discord.com" or host:sub(-12) == ".discord.com"
end

function luatoolslogin.safe_auth_url(url)
  url = tostring(url or "")
  if url:find("[\r\n]") or origin_host(url) ~= "db.lua.tools"
      or not url:match("^https://db%.lua%.tools/auth/v1/authorize%?") then
    return nil
  end
  local params = query_params(url)
  if params.provider ~= "discord" or params.redirect_to ~= CALLBACK
      or type(params.code_challenge) ~= "string" or params.code_challenge == ""
      or tostring(params.code_challenge_method):lower() ~= "s256" then
    return nil
  end
  return url
end

function luatoolslogin.login_windows(targets)
  local result = {}
  for _, target in ipairs(type(targets) == "table" and targets or {}) do
    if type(target) == "table" and target.webSocketDebuggerUrl then
      local url = tostring(target.url or "")
      local host = origin_host(url)
      local ours = false
      if host == "db.lua.tools" and url:match("^https://db%.lua%.tools/auth/v1/") then
        ours = true
      elseif host == "localhost:53789" and url:match("^http://localhost:53789/callback") then
        ours = true
      elseif discord_host(host) and url:match("^https://[^/]*discord%.com/oauth2/authorize") then
        local decoded = urldecode(url)
        ours = decoded:find("db.lua.tools", 1, true) ~= nil
          or decoded:find("localhost:53789", 1, true) ~= nil
      end
      if ours then result[#result + 1] = target end
    end
  end
  return result
end

function luatoolslogin.discord_cookie_deletions(cookie_result)
  local deletions = {}
  local cookies = type(cookie_result) == "table" and cookie_result.cookies or nil
  for _, cookie in ipairs(type(cookies) == "table" and cookies or {}) do
    local domain = tostring(type(cookie) == "table" and cookie.domain or ""):lower():gsub("^%.", "")
    if discord_host(domain) and type(cookie.name) == "string" and cookie.name ~= "" then
      local item = {
        name = cookie.name,
        domain = cookie.domain,
        path = type(cookie.path) == "string" and cookie.path or "/",
      }
      if cookie.partitionKey ~= nil then item.partitionKey = cookie.partitionKey end
      deletions[#deletions + 1] = item
    end
  end
  return deletions
end

function luatoolslogin.discord_storage_origins()
  local result = {}
  for index, origin in ipairs(DISCORD_ORIGINS) do result[index] = origin end
  return result
end

return luatoolslogin
