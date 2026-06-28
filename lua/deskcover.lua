-- deskcover: decide when to re-patch the autostart entry on Lumen's existing
-- 3s tick, and shell out to ensure-desktop-coverage.sh. Pure decision logic is
-- split from IO so it is unit-testable.
local deskcover = {}

local Tick = {}
Tick.__index = Tick

-- new_tick{ interval = <secs> } — interval rate-limits the stat-driven repatch.
function deskcover.new_tick(opts)
  opts = opts or {}
  return setmetatable({ interval = opts.interval or 3, last_check = -1, last_mtime = nil }, Tick)
end

-- should_repatch(now, st) -> boolean.
-- st = { exists=bool, mtime=number, patched=bool }. Fires when the autostart
-- file exists, is NOT patched, and (first sight OR mtime changed), at most once
-- per interval.
function Tick:should_repatch(now, st)
  if self.last_check >= 0 and (now - self.last_check) < self.interval then return false end
  self.last_check = now
  if not st.exists then self.last_mtime = nil; return false end
  local changed = (self.last_mtime == nil) or (st.mtime ~= self.last_mtime)
  self.last_mtime = st.mtime
  if st.patched then return false end
  return changed
end

local lfs_ok, lfs = pcall(require, "lfs")

local function home() return os.getenv("HOME") or "" end

function deskcover.autostart_path() return home() .. "/.config/autostart/steam.desktop" end
function deskcover.cli_path() return home() .. "/.local/share/SLSsteam/ensure-desktop-coverage.sh" end

-- stat_autostart() -> { exists, mtime, patched }
function deskcover.stat_autostart()
  local p = deskcover.autostart_path()
  local mtime, exists = 0, false
  if lfs_ok then
    local a = lfs.attributes(p)
    if a then exists = true; mtime = a.modification or 0 end
  else
    local fh = io.open(p, "r"); if fh then exists = true; fh:close() end
  end
  local patched = false
  if exists then
    local fh = io.open(p, "r")
    if fh then
      local data = fh:read("*a") or ""; fh:close()
      patched = data:find("X-SLSteamMoon-Patched=true", 1, true) ~= nil
    end
  end
  return { exists = exists, mtime = mtime, patched = patched }
end

-- run(mode) — invoke the CLI ("--user"/"--system") detached, best-effort.
function deskcover.run(mode)
  local cli = deskcover.cli_path()
  local fh = io.open(cli, "r"); if not fh then return false end; fh:close()
  os.execute('"' .. cli .. '" ' .. (mode or "--user") .. ' >/dev/null 2>&1 &')
  return true
end

return deskcover
