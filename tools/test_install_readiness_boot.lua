local function read(path)
  local file = assert(io.open(path, "rb"))
  local source = file:read("*a")
  file:close()
  return source
end

local boot = read("lua/boot.lua")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

check("B1 boot injects the install guard only into SharedJSContext",
  boot:find('lua_dir .. "/install%-readiness%-guard%.js"') ~= nil
    and boot:find("install_readiness_guard_js", 1, true) ~= nil)
check("B2 the visible menu bundle contains the readiness modal fragment",
  boot:find('"10%-install%-readiness%.js"') ~= nil)
check("B3 readiness is refreshed before clicks and pushed through the injector",
  boot:find('require%("installreadiness"%)') ~= nil
    and boot:find("update_install_readiness_guard", 1, true) ~= nil
    and boot:find("broadcast_install_readiness_ready", 1, true) ~= nil)
check("B4 the visible guard UI is injected into desktop and Gamepad shells",
  boot:find('{ %["Steam"%] = true, %["Steam Big Picture Mode"%] = true }') ~= nil)

if failures > 0 then os.exit(1) end
