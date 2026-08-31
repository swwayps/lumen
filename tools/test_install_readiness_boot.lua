local function read(path)
  local file = assert(io.open(path, "rb"))
  local source = file:read("*a")
  file:close()
  return source
end

local boot = read("lua/boot.lua")
local injector = read("lua/injector.lua")
local polyfill = read("lua/polyfill.lua")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

check("B1 boot no longer loads or injects the install-readiness guard",
  boot:find("install%-readiness%-guard") == nil
    and boot:find("install_readiness_guard", 1, true) == nil)
check("B2 the visible menu no longer contains the readiness modal",
  boot:find("10%-install%-readiness") == nil)
check("B3 the sidecar no longer polls readiness state to intercept installs",
  boot:find('require%("installreadiness"%)') == nil
    and boot:find("update_install_readiness_guard", 1, true) == nil
    and boot:find("broadcast_install_readiness", 1, true) == nil)
check("B4 the bridge no longer exposes install interception controls",
  injector:find("__lumenInstallBlocked", 1, true) == nil
    and injector:find("__lumenInstallAnyway", 1, true) == nil
    and polyfill:find("install%-readiness%-guard") == nil)

if failures > 0 then os.exit(1) end
