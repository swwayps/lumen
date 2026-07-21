-- Run: lua5.4 tools/test_steamrestart.lua
package.path = "lua/?.lua;" .. package.path

local json = require("json")
local ok, steamrestart = pcall(require, "steamrestart")

local function assert_true(condition, message)
  if not condition then error("FAIL: " .. (message or "")) end
end

assert_true(ok, "steamrestart module loads")

-- The helper is detached from Lumen because Steam's shutdown also tears down
-- the process tree that originated the RPC.
do
  local command = steamrestart.build_command("/tmp/Lumen test/restart_steam.sh")
  assert_true(command:find("nohup bash", 1, true) ~= nil,
    "restart helper is detached")
  assert_true(command:find("setsid", 1, true) == nil,
    "restart helper preserves the graphical session")
  assert_true(command:find("'/tmp/Lumen test/restart_steam.sh'", 1, true) ~= nil,
    "restart helper path is shell quoted")
  assert_true(command:find(">/dev/null 2>&1 &", 1, true) ~= nil,
    "restart helper runs in the background")
end

-- restart() checks the runtime helper before spawning it.
do
  local spawned
  local success, err = steamrestart.restart({
    lua_dir = "/opt/Lumen/lua",
    exists = function(path)
      return path == "/opt/Lumen/lua/restart_steam.sh"
    end,
    preflight = function() return true end,
    spawn = function(command)
      spawned = command
      return true
    end,
  })
  assert_true(success == true and err == nil, "existing helper starts")
  assert_true(spawned and spawned:find("/opt/Lumen/lua/restart_steam.sh", 1, true),
    "runtime helper path is launched")
end

do
  local spawned = false
  local success, err = steamrestart.restart({
    lua_dir = "/missing",
    exists = function() return false end,
    preflight = function() return true end,
    spawn = function() spawned = true; return true end,
  })
  assert_true(success == false and tostring(err):find("not found", 1, true),
    "missing helper returns a useful error")
  assert_true(spawned == false, "missing helper is never spawned")
end

do
  local spawned = false
  local success, err = steamrestart.restart({
    lua_dir = "/runtime/lua",
    exists = function() return true end,
    preflight = function() return false end,
    spawn = function() spawned = true; return true end,
  })
  assert_true(success == false and tostring(err):find("injected launcher", 1, true),
    "failed preflight reports that no injected launcher is available")
  assert_true(spawned == false, "failed preflight never starts the helper")
end

-- Lumen's native RPC replaces a plugin-provided RestartSteam endpoint, keeping
-- restart behavior identical with and without the optional LuaTools plugin.
do
  local registry = { RestartSteam = function() return "plugin" end }
  local now, starts = 100, 0
  steamrestart.register(registry, {
    lua_dir = "/runtime/lua",
    exists = function() return true end,
    preflight = function() return true end,
    spawn = function() starts = starts + 1; return true end,
    now = function() return now end,
  })
  local response = json.decode(registry.RestartSteam())
  assert_true(response.success == true, "native RestartSteam RPC reports success")
  assert_true(response.error == nil, "successful restart omits an error field")
  local duplicate = json.decode(registry.RestartSteam())
  assert_true(duplicate.success == false
      and tostring(duplicate.error):find("already", 1, true),
    "native RestartSteam rejects a concurrent restart")
  assert_true(starts == 1, "concurrent restart does not spawn another helper")
  now = 159
  local settling = json.decode(registry.RestartSteam())
  assert_true(settling.success == false and starts == 1,
    "restart guard covers Steam account-session stabilization")
  now = 160
  local later = json.decode(registry.RestartSteam())
  assert_true(later.success == true and starts == 2,
    "restart guard expires after the stabilization window")
end

do
  local package_file = assert(io.open("scripts/package.sh", "rb"))
  local package_source = package_file:read("*a")
  package_file:close()
  assert_true(package_source:find(
      'cp lua/restart_steam.sh "$STAGE/lua/"', 1, true) ~= nil,
    "release package requires the restart helper")
end

print("test_steamrestart: ALL PASS")
