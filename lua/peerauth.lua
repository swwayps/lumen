-- peerauth: prove that whatever is listening on the CEF debugging port is the
-- Steam client before speaking CDP to it.
--
-- Steam's remote-debugging endpoint is an unauthenticated loopback HTTP/WebSocket
-- service on a port that is either published in a contract file or, for a vanilla
-- client, the hard-coded 8080. The injector used to connect to that port and then
-- treat every Runtime.bindingCalled frame arriving over it as a legitimate call
-- from the frontend. An unprivileged local process that binds the port first can
-- therefore serve a fake target list and a fake WebSocket, and drive the whole
-- backend registry.
--
-- The kernel knows who owns a listening socket, so we ask it: find the socket's
-- inode in /proc/net/tcp[6], find the process holding that inode as an open file
-- descriptor, and require its executable to be the Steam client or its web
-- helper. Everything is injectable so the logic is testable without a live Steam.
local lfs = require("lfs")

local peerauth = {}

-- TCP state 0x0A == TCP_LISTEN.
local LISTEN = "0A"

-- Executables allowed to own the CEF endpoint. Compared as an exact basename:
-- "steamwebhelper-evil" and "mysteam" must not pass.
local STEAM_EXE = { steam = true, steamwebhelper = true }

-- listener_inodes(text, port) -> array of socket inodes listening on `port`.
-- `text` is the contents of /proc/net/tcp or /proc/net/tcp6. Columns are
-- sl, local_address, rem_address, st, tx:rx, tr:when, retrnsmt, uid, timeout,
-- inode — the inode is the tenth whitespace-separated field.
function peerauth.listener_inodes(text, port)
  local out = {}
  if type(text) ~= "string" or type(port) ~= "number" then return out end
  if port < 1 or port > 65535 or port ~= math.floor(port) then return out end
  local want = string.format("%04X", port)
  for line in text:gmatch("[^\n]+") do
    local f = {}
    for tok in line:gmatch("%S+") do f[#f + 1] = tok end
    if #f >= 10 then
      local local_port = f[2] and f[2]:match(":(%x+)$")
      if local_port and local_port:upper() == want and f[4]:upper() == LISTEN then
        local inode = tonumber(f[10])
        if inode then out[#out + 1] = math.floor(inode) end
      end
    end
  end
  return out
end

-- is_steam_exe(target) -> boolean. `target` is the /proc/<pid>/exe link target.
-- The kernel appends " (deleted)" when the binary has been replaced or removed;
-- that is no longer the file we would have vouched for, so it is refused.
function peerauth.is_steam_exe(target)
  if type(target) ~= "string" or target == "" then return false end
  if target:find(" (deleted)", 1, true) then return false end
  local base = target:match("([^/]+)$")
  return base ~= nil and STEAM_EXE[base] == true
end

-- ── default /proc readers (all injectable) ──────────────────────────────────

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function default_list_pids()
  local out = {}
  local ok, iter, dir_obj = pcall(lfs.dir, "/proc")
  if not ok then return out end
  for entry in iter, dir_obj do
    if entry:match("^%d+$") then out[#out + 1] = tonumber(entry) end
  end
  if dir_obj then pcall(function() dir_obj:close() end) end
  return out
end

local function default_fd_targets(pid)
  local out = {}
  local dir = "/proc/" .. tostring(pid) .. "/fd"
  local ok, iter, dir_obj = pcall(lfs.dir, dir)
  if not ok then return out end
  for entry in iter, dir_obj do
    if entry ~= "." and entry ~= ".." then
      local target = lfs.symlinkattributes(dir .. "/" .. entry, "target")
      if type(target) == "string" then out[#out + 1] = target end
    end
  end
  if dir_obj then pcall(function() dir_obj:close() end) end
  return out
end

local function default_exe_target(pid)
  return lfs.symlinkattributes("/proc/" .. tostring(pid) .. "/exe", "target")
end

local function resolve(deps, name, fallback)
  local fn = deps and deps[name]
  if type(fn) == "function" then return fn end
  return fallback
end

-- owner_pid(inode, deps) -> pid holding `inode` as an open fd, or nil.
function peerauth.owner_pid(inode, deps)
  if type(inode) ~= "number" then return nil end
  local needle = "socket:[" .. tostring(math.floor(inode)) .. "]"
  local list_pids = resolve(deps, "list_pids", default_list_pids)
  local fd_targets = resolve(deps, "fd_targets", default_fd_targets)
  local ok_pids, pids = pcall(list_pids)
  if not ok_pids or type(pids) ~= "table" then return nil end
  for _, pid in ipairs(pids) do
    local ok_fds, targets = pcall(fd_targets, pid)
    if ok_fds and type(targets) == "table" then
      for _, target in ipairs(targets) do
        if target == needle then return pid end
      end
    end
  end
  return nil
end

-- verify(port, deps) -> trusted (boolean), reason (string)
-- reason is one of "steam", "no listener", "owner unknown", "not steam".
-- "no listener" is distinct from the refusals on purpose: it means "nothing is
-- there yet", which for a booting Steam is the normal state and should make the
-- caller wait rather than conclude anything.
function peerauth.verify(port, deps)
  local read_tcp = resolve(deps, "read_tcp",
    function() return read_all("/proc/net/tcp") end)
  local read_tcp6 = resolve(deps, "read_tcp6",
    function() return read_all("/proc/net/tcp6") end)
  local exe_target = resolve(deps, "exe_target", default_exe_target)

  local inodes = {}
  for _, reader in ipairs({ read_tcp, read_tcp6 }) do
    local ok_read, text = pcall(reader)
    if ok_read and type(text) == "string" then
      for _, inode in ipairs(peerauth.listener_inodes(text, port)) do
        inodes[#inodes + 1] = inode
      end
    end
  end
  if #inodes == 0 then return false, "no listener" end

  local resolved_any = false
  for _, inode in ipairs(inodes) do
    local pid = peerauth.owner_pid(inode, deps)
    if pid then
      resolved_any = true
      local ok_exe, target = pcall(exe_target, pid)
      if ok_exe and peerauth.is_steam_exe(target) then return true, "steam" end
    end
  end
  if not resolved_any then return false, "owner unknown" end
  return false, "not steam"
end

-- ── per-port cache ──────────────────────────────────────────────────────────
-- Discovery probes the endpoint several times a second; a /proc-wide fd scan on
-- every probe would be wasteful. A POSITIVE verdict is cached per port. A
-- negative one is not: "nothing listening yet" and "not Steam yet" both change
-- as the client comes up, and caching them would deadlock the boot path.
function peerauth.new_cache()
  return { port = nil, trusted = false }
end

function peerauth.verify_cached(cache, port, deps)
  if type(cache) == "table" and cache.trusted and cache.port == port then
    return true, "steam (cached)"
  end
  local trusted, reason = peerauth.verify(port, deps)
  if type(cache) == "table" then
    cache.port = port
    cache.trusted = trusted == true
  end
  return trusted, reason
end

return peerauth
