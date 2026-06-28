-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_loop_deskcover.lua
-- Static check: loop.lua wires the desktop-coverage re-assert into its existing
-- tick (autostart stat) and runs a final pass before exit. loop.run is an
-- infinite loop, so we assert on the source rather than executing it.
local dir = os.getenv("LUMEN_LUA_DIR") or "lua"
local fh = assert(io.open(dir .. "/loop.lua")); local src = fh:read("*a"); fh:close()
local function ok(c, m) if not c then error("FAIL: " .. m) end end
ok(src:find("deskcover", 1, true), "loop.lua requires deskcover")
ok(src:find("should_repatch", 1, true), "loop.lua calls should_repatch on tick")
ok(src:find("deskcover.run", 1, true), "loop.lua runs the coverage CLI (tick and/or exit)")
print("test_loop_deskcover: ALL PASS")
