-- Run: lua5.4 tools/test_proc.lua
-- proc.is_alive(comm, root) scans <root>/*/comm for an exact process name. Used
-- to detect whether the main `steam` client process is running, the liveness
-- signal that drives the lifecycle watcher.
package.path = "lua/?.lua;" .. package.path
local proc = require("proc")
local lfs = require("lfs")  -- available via the lumen binary's --test runner

local function assert_true(c, m) if not c then error("FAIL: " .. (m or "")) end end

-- Build a fake /proc with a couple of pids and comm files.
local function write(path, s)
  local f = assert(io.open(path, "w")); f:write(s); f:close()
end
local root = os.tmpname()
os.remove(root)
lfs.mkdir(root)
for _, e in ipairs({ { "100", "steam\n" }, { "101", "steamwebhelper\n" }, { "102", "bash\n" } }) do
  lfs.mkdir(root .. "/" .. e[1])
  write(root .. "/" .. e[1] .. "/comm", e[2])
end

-- 1. exact match finds the steam client (and is NOT fooled by steamwebhelper).
assert_true(proc.is_alive("steam", root) == true, "finds exact 'steam'")

-- 2. a name that only appears as a prefix of another comm is not matched.
assert_true(proc.is_alive("stea", root) == false, "no partial match")

-- 3. absent process -> false.
assert_true(proc.is_alive("doesnotexist", root) == false, "absent -> false")

-- 4. after removing the steam pid, it reports gone.
os.remove(root .. "/100/comm"); lfs.rmdir(root .. "/100")
assert_true(proc.is_alive("steam", root) == false, "gone after removal")

-- cleanup
for _, p in ipairs({ "101", "102" }) do
  os.remove(root .. "/" .. p .. "/comm"); lfs.rmdir(root .. "/" .. p)
end
lfs.rmdir(root)

print("test_proc: ALL PASS")
