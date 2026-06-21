-- Leak/regression test for lua/proc.lua (proc.is_alive).
--
-- is_alive scans /proc and BREAKS early when it finds the target comm. The
-- lfs directory handle must be closed on that early-exit path or the /proc
-- directory fd leaks (it's polled every lifecycle tick -> fd exhaustion ->
-- is_alive starts failing -> Lumen wrongly exits mid-session). This test calls
-- is_alive many times via the early-break path (matching this process's own
-- comm, "lumen") and asserts the count of open fds pointing at /proc does not
-- grow.
--
-- Run:  LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_proc.lua

local proc = require("proc")
local lfs = require("lfs")

local function procfd_count()
  local n = 0
  for e in lfs.dir("/proc/self/fd") do
    if e ~= "." and e ~= ".." then
      local target = lfs.symlinkattributes("/proc/self/fd/" .. e, "target")
      if target == "/proc" then n = n + 1 end
    end
  end
  return n
end

-- This process's comm is "lumen" (the test runner binary), so is_alive finds it
-- partway through /proc and takes the early-break path that used to leak.
assert(proc.is_alive("lumen") == true, "expected to find own comm 'lumen' alive")
assert(proc.is_alive("definitely_not_a_real_comm_zzz") == false, "false positive")

local before = procfd_count()
for _ = 1, 300 do
  proc.is_alive("lumen")
end
collectgarbage("collect")  -- pre-fix would still show growth pre-GC; post-fix is 0 regardless
local after = procfd_count()

io.stderr:write("test_proc: /proc fds before=" .. before .. " after=" .. after .. "\n")
assert(after <= before + 1,
  "FAIL: proc.is_alive leaks /proc fds (" .. before .. " -> " .. after .. ")")
io.stderr:write("test_proc OK\n")
