package.path = "lua/?.lua;" .. package.path

local ok_module, ir = pcall(require, "installreadiness")
if not ok_module then
  io.stderr:write("FAIL installreadiness module is missing\n")
  os.exit(1)
end
local json = require("json")
local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

local function snapshot(raw, now)
  local value = ir.snapshot({
    now = now or 100,
    max_age = 90,
    ttl_ms = 2500,
    read_file = function() return raw end,
  })
  return value
end

local active = snapshot(json.encode({
  version = 1,
  updated_at = 95,
  apps = {
    ["1671210"] = { blocked = true, missing = 1 },
    ["20"] = { blocked = false, missing = 0 },
    nope = { blocked = true, missing = 1 },
  },
}))
check("R1 only explicit positive blocked AppIDs enter the SharedJS map",
  active["1671210"] and active["1671210"].blocking == true
    and active["1671210"].ttlMs == 2500
    and active["20"] == nil and active.nope == nil)

local _, active_valid = ir.snapshot({
  now = 100, max_age = 90, ttl_ms = 2500,
  read_file = function() return json.encode({ version = 1, updated_at = 95, apps = {} }) end,
})

local stale = snapshot(json.encode({
  version = 1, updated_at = 1,
  apps = { ["1671210"] = { blocked = true, missing = 1 } },
}), 100)
check("R2 stale producer state fails open", next(stale) == nil)
local _, stale_valid = ir.snapshot({
  now = 100, max_age = 90,
  read_file = function() return json.encode({ version = 1, updated_at = 1, apps = {} }) end,
})
check("R2b only fresh producer state may emit a recovery notification",
  active_valid == true and stale_valid == false)

check("R3 missing, malformed and future schemas fail open",
  next(snapshot(nil)) == nil
    and next(snapshot("not json")) == nil
    and next(snapshot('{"version":2,"updated_at":100,"apps":{}}')) == nil)

local recovered = ir.recovered_apps({ ["10"] = {}, ["20"] = {} }, { ["20"] = {} })
check("R4 only an AppID removed from the blocked map emits readiness recovery",
  #recovered == 1 and recovered[1] == 10)

if failures > 0 then os.exit(1) end
