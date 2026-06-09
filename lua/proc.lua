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
  for entry in iter, dir_obj do
    if entry:match("^%d+$") then
      local f = io.open(root .. "/" .. entry .. "/comm", "r")
      if f then
        local name = f:read("l")   -- first line, without the newline
        f:close()
        if name == comm then return true end
      end
    end
  end
  return false
end

return proc
