-- Integration test for the boot-time registry selection. Static source audits
-- catch most drift, but this proves a plugin method absent from Lumen's legacy
-- fallback is still registered when the plugin publishes it through lifecycle.
local lfs = require("lfs")

local function ok(condition, message)
  if not condition then error("FAIL: " .. message, 0) end
end

local root = os.tmpname()
os.remove(root)
assert(lfs.mkdir(root))
local backend = root .. "/backend"
assert(lfs.mkdir(backend))

local main = assert(io.open(backend .. "/main.lua", "wb"))
main:write([[
function ContractOnlyMethod()
  return "contract"
end
return { rpc_methods = { "ContractOnlyMethod" } }
]])
main:close()

local captured
local noop_registry = { register = function() end }
package.loaded["millennium"] = {
  queued_css = function() return {} end,
  queued_js = function() return {} end,
}
package.loaded["utils"] = { read_file = function() return "" end }
package.loaded["polyfill"] = {}
package.loaded["slsconfig"] = {
  default_path = function() return root .. "/config.yaml" end,
  read = function() return { DisableParentalRestrictions = false } end,
  has_cloudredirect = function() return false end,
}
for _, name in ipairs({
    "slsmenu", "manifestpins", "about", "fixesmenu", "slscheck", "steamrestart",
  }) do
  package.loaded[name] = noop_registry
end
package.loaded["notifyqueue"] = { drain = function() return {} end }
package.loaded["plugintick"] = {
  new = function()
    return { run = function() return nil end }
  end,
}
package.loaded["loop"] = {
  run = function(options) captured = options end,
}

local real_getenv = os.getenv
os.getenv = function(name)
  if name == "LUMEN_BACKEND_DIR" then return backend end
  if name == "LUMEN_LUA_DIR" then return "lua" end
  return real_getenv(name)
end

local loaded, load_error = pcall(dofile, "lua/boot.lua")
os.getenv = real_getenv

ok(loaded, "boot loads with a plugin-owned contract: " .. tostring(load_error))
ok(type(captured) == "table" and type(captured.registry) == "table",
  "boot hands a registry to the loop")
ok(type(captured.registry.ContractOnlyMethod) == "function",
  "a contract-only method is registered without editing Lumen's fallback")
ok(captured.registry.ContractOnlyMethod() == "contract",
  "the registered contract method is the plugin implementation")

_G.ContractOnlyMethod = nil
os.remove(backend .. "/main.lua")
lfs.rmdir(backend)
lfs.rmdir(root)

print("test_boot_rpc_contract: ALL PASS")
