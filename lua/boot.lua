-- boot: load the LuaTools backend behind the shims, then run the unified loop.
local backend = os.getenv("LUMEN_BACKEND_DIR")
assert(backend and backend ~= "", "LUMEN_BACKEND_DIR not set")
package.path = backend .. "/?.lua;" .. package.path

-- Ensure Lumen's state dir exists (for session.json).
local home = os.getenv("HOME") or "."
local state_dir = home .. "/.local/share/Lumen"
os.execute("mkdir -p '" .. state_dir .. "'")

-- Loading main.lua defines the global RPC functions (InitApis, etc.).
dofile(backend .. "/main.lua")

-- Build the dispatch registry from globals that are functions and look like
-- exported endpoints (PascalCase). This mirrors what Millennium exposed.
local registry = {}
for k, v in pairs(_G) do
  if type(v) == "function" and k:match("^%u") then registry[k] = v end
end

local loop = require("loop")
loop.run({
  session_path = state_dir .. "/session.json",
  registry = registry,
  inject_opts = { message = "Lumen RPC up" },
})
