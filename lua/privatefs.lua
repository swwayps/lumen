-- privatefs: where Lumen puts files that must not be readable, writable or
-- pre-created by another local user.
--
-- Two kinds of file need this. Scripts Lumen writes and then hands to a terminal
-- to EXECUTE (Update All, the slsteam-moon auto-fix) used to be created with
-- io.open at /tmp/lumen-update-<os.time()>.sh — a predictable path in a shared
-- directory, opened without O_EXCL or O_NOFOLLOW. A local process could
-- pre-create it as a symlink (the write then lands on, say, ~/.bashrc) or
-- pre-create it as a plain file it owns and rewrite the contents between our
-- write and the terminal's exec. And the RPCs that trigger those writes are
-- reachable from the frontend, so the attacker also picks the moment.
--
-- Files holding secrets (the cloud OAuth refresh token) have the same problem in
-- the other direction: created with the default mode and narrowed by a later
-- chmod, they are briefly world-readable.
--
-- Everything here goes into a 0700 directory under $XDG_RUNTIME_DIR (per-user,
-- tmpfs, cleaned at logout), falling back to a private directory under HOME
-- rather than /tmp. Names are random, not derived from the clock.
local lfs = require("lfs")
local nonce = require("nonce")

local privfs = nil
do
  local ok, mod = pcall(require, "lumen_privfs")
  if ok then privfs = mod end
end

local privatefs = {}

-- mkdir_private(path) -> boolean
-- Creates `path` mode 0700, or accepts it if it already is a private directory
-- we own. A directory that is a symlink, owned by someone else, or accessible to
-- group/others is REFUSED rather than reused: anything already inside it may not
-- be ours.
function privatefs.mkdir_private(path)
  if type(path) ~= "string" or path == "" then return false end
  if privfs then
    local existing, reason = privfs.is_private_dir(path)
    if existing then return true end
    if reason ~= "missing" then return false end
    return privfs.mkdir(path, tonumber("700", 8)) == true
  end
  -- Fallback for a host Lua without the C module (tests, tooling).
  local mode = lfs.attributes(path, "mode")
  if mode == "directory" then
    return lfs.attributes(path, "permissions") == "rwx------"
  end
  if mode ~= nil then return false end
  if not lfs.mkdir(path) then return false end
  os.execute("chmod 700 -- '" .. path:gsub("'", "'\\''") .. "'")
  return lfs.attributes(path, "permissions") == "rwx------"
end

-- write_private(path, data [, mode]) -> boolean
-- Creates a NEW file only: an existing path (or a symlink) is a failure, which
-- is what makes the pre-create race unwinnable. Default mode 0600.
function privatefs.write_private(path, data, mode)
  if type(path) ~= "string" or path == "" or type(data) ~= "string" then
    return false
  end
  if privfs then
    return privfs.write(path, data, mode or tonumber("600", 8)) == true
  end
  -- Fallback: refuse if anything is already there, then narrow the mode. This
  -- is weaker than O_EXCL (it is a check followed by an open) and exists only so
  -- host-side tooling works; the shipped binary always has the C module.
  if lfs.symlinkattributes(path, "mode") ~= nil then return false end
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  local octal = (mode == tonumber("700", 8)) and "700" or "600"
  os.execute("chmod " .. octal .. " -- '" .. path:gsub("'", "'\\''") .. "'")
  return true
end

-- write_script(path, text) -> boolean. Owner-only read/write/execute.
function privatefs.write_script(path, text)
  return privatefs.write_private(path, text, tonumber("700", 8))
end

-- runtime_dir(env) -> a private directory for this user's transient files.
-- env is injectable for tests: { xdg = <XDG_RUNTIME_DIR>, home = <HOME> }.
-- Returns nil when neither is usable.
function privatefs.runtime_dir(env)
  env = env or {}
  local xdg = env.xdg
  if xdg == nil and env.home == nil then
    xdg = os.getenv("XDG_RUNTIME_DIR")
  end
  local home = env.home
  if home == nil and env.xdg == nil then home = os.getenv("HOME") end

  if type(xdg) == "string" and xdg ~= "" then
    local dir = xdg .. "/lumen"
    if privatefs.mkdir_private(dir) then return dir end
  end
  -- No runtime dir (a bare service manager, a container). Use HOME, never /tmp:
  -- /tmp is shared with every other local user, which is the whole problem.
  if type(home) == "string" and home ~= "" then
    local dir = home .. "/.cache/lumen-private"
    -- The parent may not exist yet; create it without requiring 0700 on ~/.cache
    -- itself (that is the user's own directory and may legitimately be 0755).
    if lfs.attributes(home .. "/.cache", "mode") == nil then
      lfs.mkdir(home .. "/.cache")
    end
    if privatefs.mkdir_private(dir) then return dir end
  end
  return nil
end

-- temp_script_path(prefix, env) -> an unpredictable path inside runtime_dir.
function privatefs.temp_script_path(prefix, env)
  local dir = privatefs.runtime_dir(env)
  if not dir then return nil end
  local token = nonce.hex(12) or tostring(math.random(1e9))
  return dir .. "/" .. tostring(prefix or "lumen") .. "-" .. token .. ".sh"
end

return privatefs
