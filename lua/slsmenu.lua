-- slsmenu: RPC layer for the Lumen settings menu's "slsteam-moon" tab.
--
-- Exposes two backend methods (registered into the CDP dispatch registry by
-- register()), each returning a JSON string per the upstream callServerMethod
-- convention the polyfill resolves:
--   GetSlsConfig() -> {success, schema, values}   (render the tab)
--   SetSlsConfig(json) -> {success[, error]}      (persist one key)
--
-- The pure-ish get/set take an explicit path so they're host-testable; the
-- registered wrappers bind them to slsconfig.default_path().
local json = require("json")
local slsconfig = require("slsconfig")

local slsmenu = {}

-- Index SCHEMA by key for validation + type coercion.
local function schema_entry(key)
  for _, e in ipairs(slsconfig.SCHEMA) do
    if e.key == key then return e end
  end
  return nil
end

-- get(path) -> JSON string {success=true, schema=..., values=...}
function slsmenu.get(path)
  local values = slsconfig.read(path)
  return json.encode({
    success = true,
    schema = slsconfig.SCHEMA,
    values = values,
  })
end

-- Coerce a frontend value to the Lua type the key expects, so a stray string
-- "true" or a float LogLevel writes correctly. Numeric keys are clamped to the
-- schema's [min, max] when present, so an out-of-range value (e.g. a wallet
-- balance past int32) can never reach slsteam-moon and abort it.
local function coerce(entry, value)
  if entry.type == "bool" then
    if type(value) == "boolean" then return value end
    local s = tostring(value):lower()
    return s == "true" or s == "yes" or s == "1" or s == "on"
  elseif entry.type == "int" or entry.type == "enum" then
    local n = math.floor(tonumber(value) or 0)
    if entry.min and n < entry.min then n = entry.min end
    if entry.max and n > entry.max then n = entry.max end
    return n
  else
    return tostring(value)
  end
end

-- set(path, json_str) -> JSON string {success=...[, error]}
function slsmenu.set(path, json_str)
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or type(req.key) ~= "string" then
    return json.encode({ success = false, error = "bad request" })
  end
  local entry = schema_entry(req.key)
  if not entry then
    return json.encode({ success = false, error = "unknown key: " .. req.key })
  end
  local wok, werr = slsconfig.write_key(path, req.key, coerce(entry, req.value))
  if not wok then
    return json.encode({ success = false, error = tostring(werr) })
  end
  return json.encode({ success = true })
end

-- reset(path) -> JSON string {success=...[, error]}. Restores all keys to their
-- defaults and (on success) returns the fresh {schema, values} so the frontend
-- can re-render the tab without a second round-trip.
function slsmenu.reset(path)
  local ok, err = slsconfig.reset_to_defaults(path)
  if not ok then
    return json.encode({ success = false, error = tostring(err) })
  end
  return json.encode({
    success = true,
    schema = slsconfig.SCHEMA,
    values = slsconfig.read(path),
  })
end

-- register(registry): install GetSlsConfig / SetSlsConfig bound to the real
-- config path. Args from the dispatcher are ignored (the path is fixed).
function slsmenu.register(registry)
  registry.GetSlsConfig = function() return slsmenu.get(slsconfig.default_path()) end
  registry.SetSlsConfig = function(json_str) return slsmenu.set(slsconfig.default_path(), json_str) end
  registry.ResetSlsConfig = function() return slsmenu.reset(slsconfig.default_path()) end
  return registry
end

return slsmenu
