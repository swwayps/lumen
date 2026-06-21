-- proc: tiny /proc scanner to detect whether a process with an exact comm name
-- is alive. Used as the liveness signal for the lifecycle watcher (is the main
-- `steam` client running?). Linux-only, which is Lumen's only target.
local lfs = require("lfs")

local proc = {}

-- is_alive(comm, root) -> boolean. True if any <root>/<pid>/comm equals `comm`
-- (exact match; trailing newline trimmed). `root` defaults to "/proc".
function proc.is_alive(comm, root)
  root = root or "/proc"
  local ok, iter, dir_obj = pcall(lfs.dir, root)
  if not ok then return false end
  local found = false
  for entry in iter, dir_obj do
    if entry:match("^%d+$") then
      local f = io.open(root .. "/" .. entry .. "/comm", "r")
      if f then
        local name = f:read("l")   -- first line, without the newline
        f:close()
        if name == comm then found = true; break end
      end
    end
  end
  -- lfs closes the directory object when the iterator runs to the end, but NOT
  -- when we break/return early (the common case: the target process is found
  -- partway through). Left to the GC, the /proc directory fd leaks; since this
  -- is polled every tick, fds accumulate until the process hits its limit (then
  -- lfs.dir starts failing -> is_alive returns false -> the lifecycle watcher
  -- wrongly concludes Steam died and exits Lumen mid-session). Close it
  -- explicitly on every path (guarded: a double close after full iteration is
  -- a harmless no-op).
  if dir_obj then pcall(function() dir_obj:close() end) end
  return found
end

return proc
