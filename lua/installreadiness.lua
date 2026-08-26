local json = require("json")
local utils = require("utils")

local installreadiness = {}

local function positive_appid(value)
  local number = tonumber(value)
  if not number or number <= 0 or number ~= math.floor(number) then return nil end
  return math.floor(number)
end

function installreadiness.default_path()
  local home = os.getenv("HOME") or ""
  return home ~= "" and (home .. "/.config/SLSsteam/install-readiness.json") or nil
end

function installreadiness.snapshot(opts)
  opts = opts or {}
  local path = opts.path or installreadiness.default_path()
  local reader = opts.read_file or utils.read_file
  if not path and opts.read_file == nil then return {}, false end
  local ok_read, raw = pcall(reader, path)
  if not ok_read or type(raw) ~= "string" or raw == "" then return {}, false end
  local ok_decode, state = pcall(json.decode, raw)
  if not ok_decode or type(state) ~= "table" or tonumber(state.version) ~= 1
      or type(state.apps) ~= "table" then return {}, false end

  local now = tonumber(opts.now) or os.time()
  local updated_at = tonumber(state.updated_at)
  local max_age = math.max(1, tonumber(opts.max_age) or 90)
  if not updated_at or updated_at > now + 5 or now - updated_at > max_age then
    return {}, false
  end

  local ttl_ms = math.max(250, math.min(10000, tonumber(opts.ttl_ms) or 2500))
  local blocked = {}
  for key, value in pairs(state.apps) do
    local appid = positive_appid(key)
    if appid and type(value) == "table" and value.blocked == true then
      blocked[tostring(appid)] = {
        blocking = true,
        ttlMs = ttl_ms,
      }
    end
  end
  return blocked, true
end

function installreadiness.recovered_apps(previous, current)
  local recovered = {}
  current = type(current) == "table" and current or {}
  for key in pairs(type(previous) == "table" and previous or {}) do
    local appid = positive_appid(key)
    if appid and current[tostring(appid)] == nil then
      recovered[#recovered + 1] = appid
    end
  end
  table.sort(recovered)
  return recovered
end

return installreadiness
