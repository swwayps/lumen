-- Native Steam restart RPC. Kept in Lumen so it works in both full-plugin and
-- --noplugin installs, always relaunching through slsteam-moon's wrapper.
local json = require("json")

local steamrestart = {}

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function steamrestart.build_command(helper_path)
  return "setsid nohup bash " .. shell_quote(helper_path)
    .. " </dev/null >/dev/null 2>&1 &"
end

function steamrestart.build_preflight_command(helper_path)
  return "bash " .. shell_quote(helper_path)
    .. " --check </dev/null >/dev/null 2>&1"
end

local function default_exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function command_succeeded(result)
  return result == true or result == 0
end

function steamrestart.restart(deps)
  deps = deps or {}
  local lua_dir = deps.lua_dir or os.getenv("LUMEN_LUA_DIR") or "lua"
  local helper_path = lua_dir .. "/restart_steam.sh"
  local exists = deps.exists or default_exists
  if not exists(helper_path) then
    return false, "restart helper not found: " .. helper_path
  end

  local preflight = deps.preflight or function(path)
    return command_succeeded(os.execute(
      steamrestart.build_preflight_command(path)))
  end
  local checked, available = pcall(preflight, helper_path)
  if not checked or available ~= true then
    return false, "injected launcher not available"
  end

  local spawn = deps.spawn or os.execute
  local called, result = pcall(spawn, steamrestart.build_command(helper_path))
  if called and command_succeeded(result) then return true end
  return false, "could not start restart helper"
end

function steamrestart.register(registry, deps)
  local restarting = false
  registry.RestartSteam = function()
    if restarting then
      return json.encode({
        success = false,
        error = "Steam restart already in progress",
      })
    end
    local ok, err = steamrestart.restart(deps)
    if ok then restarting = true end
    return json.encode({
      success = ok == true,
      error = ok and nil or tostring(err),
    })
  end
  return registry
end

return steamrestart
