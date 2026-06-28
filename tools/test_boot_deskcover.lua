-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_boot_deskcover.lua
-- Static check: boot.lua runs one initial desktop-coverage pass per injected
-- session. boot.lua wires up the whole sidecar, so we assert on the source.
local dir = os.getenv("LUMEN_LUA_DIR") or "lua"
local fh = assert(io.open(dir .. "/boot.lua")); local src = fh:read("*a"); fh:close()
local function ok(c, m) if not c then error("FAIL: " .. m) end end
ok(src:find("deskcover", 1, true), "boot.lua references deskcover")
ok(src:find('require("deskcover").run', 1, true), "boot.lua runs an initial coverage pass")
print("test_boot_deskcover: ALL PASS")
