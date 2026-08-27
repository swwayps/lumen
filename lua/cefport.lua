-- Resolves Steam's CEF remote-debugging port. slsteam-moon rewrites Steam's
-- hard-coded 8080 to a free loopback port and writes it to the contract file
-- ~/.local/share/Lumen/cef_port. The injector reads it from here; if the file
-- is absent or invalid we fall back to 8080 (vanilla Steam / slsteam-moon off).
--
-- The contract is SELF-INVALIDATING. slsteam-moon writes:
--   line 1: <port>
--   line 2: owner <pid> <startTicks>     (optional)
-- where <pid>/<startTicks> identify the Steam client that published it (field
-- 22 of /proc/<pid>/stat, so pid reuse can't fake it). A contract whose owner is
-- gone belongs to a PREVIOUS session and is ignored:
--   * we stop polling a port nothing listens on for the first seconds of a boot
--     (the live port is only published when the client launches the webhelper),
--     and never hand a CDP handshake to whatever unrelated process may have been
--     given that ephemeral port since;
--   * a vanilla Steam launch after an injected one falls back to 8080 instead of
--     chasing the previous session's port forever.
-- A contract with no owner record (an older slsteam-moon) is trusted as before.
--
-- IMPORTANT: the port this module returns is NOT trusted on its own. Neither the
-- contract's owner record nor the 8080 fallback proves that the process actually
-- listening on that port is the Steam client, and an unprivileged local process
-- can bind a loopback port before Steam does. The injector therefore asks the
-- kernel who owns the listening socket (lua/peerauth.lua) before it speaks CDP,
-- for the contract port and the fallback alike. That check is what makes it safe
-- to keep the 8080 fallback (needed for a vanilla Steam, and for the Decky
-- Loader case) and to keep accepting ownerless contracts from older
-- slsteam-moon builds: a squatter fails the ownership check regardless of how we
-- arrived at the port number.
local cefport = {}

cefport.FALLBACK = 8080

-- Path of the contract file slsteam-moon writes ("" if HOME unset).
function cefport.contract_path()
  local home = os.getenv("HOME") or ""
  if home == "" then return "" end
  return home .. "/.local/share/Lumen/cef_port"
end

-- parse_port(s) -> integer in [1024,65535] or nil. Tolerates surrounding
-- whitespace / trailing newline; rejects non-integers and out-of-range values.
function cefport.parse_port(s)
  if type(s) ~= "string" then return nil end
  local n = tonumber(s)
  if not n then return nil end
  if n < 1024 or n > 65535 then return nil end
  if n ~= math.floor(n) then return nil end
  return math.floor(n)
end

-- parse_contract(text) -> { port = <int>, pid = <int|nil>, start = <int|nil> }
-- or nil when the first line is not a usable port. The owner record is optional
-- (older slsteam-moon builds wrote the port alone) and a malformed one is
-- treated as absent rather than as a reason to drop a valid port.
function cefport.parse_contract(text)
  if type(text) ~= "string" then return nil end
  local first = text:match("^([^\n]*)") or ""
  local port = cefport.parse_port(first)
  if not port then return nil end
  local rest = text:sub(#first + 1)
  local pid, start = rest:match("owner%s+(%d+)%s+(%d+)")
  return {
    port = port,
    pid = pid and math.floor(tonumber(pid)) or nil,
    start = start and math.floor(tonumber(start)) or nil,
  }
end

-- read_proc_stat(pid) -> the process' /proc/<pid>/stat line, or nil.
function cefport.read_proc_stat(pid)
  if type(pid) ~= "number" or pid <= 0 then return nil end
  local f = io.open("/proc/" .. math.floor(pid) .. "/stat", "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

-- stat_start_ticks(line) -> field 22 (starttime) of a /proc/<pid>/stat line, or
-- nil. The comm field is parenthesised and may itself contain spaces and ')',
-- so parsing starts after the LAST ')'.
function cefport.stat_start_ticks(line)
  if type(line) ~= "string" then return nil end
  local close = nil
  for i = #line, 1, -1 do
    if line:sub(i, i) == ")" then close = i; break end
  end
  if not close then return nil end
  local field = 3                       -- first token after comm is field 3
  for token in line:sub(close + 1):gmatch("%S+") do
    if field == 22 then
      local n = tonumber(token)
      return n and math.floor(n) or nil
    end
    field = field + 1
  end
  return nil
end

-- owner_alive(pid, start, read_stat) -> true when that exact process is still
-- running. `start` must match, so a recycled pid never revives a stale
-- contract. read_stat is injectable for tests.
function cefport.owner_alive(pid, start, read_stat)
  if type(pid) ~= "number" or type(start) ~= "number" then return false end
  read_stat = read_stat or cefport.read_proc_stat
  local ok, line = pcall(read_stat, pid)
  if not ok or type(line) ~= "string" then return false end
  return cefport.stat_start_ticks(line) == start
end

-- resolve(read_fn, fallback, read_stat) -> port, from_file, reason
--   read_fn   : function returning the file's contents (string) or nil.
--   fallback  : port to use when the file is missing/invalid/stale (default 8080).
--   read_stat : optional /proc reader used to validate the contract's owner.
-- read_fn errors are caught and treated as "no file". `reason` is "stale" when a
-- syntactically valid contract was rejected because its owning client is gone.
function cefport.resolve(read_fn, fallback, read_stat)
  fallback = fallback or cefport.FALLBACK
  local ok, content = pcall(read_fn)
  if ok and content then
    local contract = cefport.parse_contract(content)
    if contract then
      if not contract.pid or not contract.start then
        return contract.port, true          -- legacy contract: no owner to check
      end
      if cefport.owner_alive(contract.pid, contract.start, read_stat) then
        return contract.port, true
      end
      return fallback, false, "stale"
    end
  end
  return fallback, false
end

-- read_contract() -> contents of the contract file (trailing newline stripped),
-- or nil. Plain io so the pure logic above stays testable without a filesystem.
function cefport.read_contract()
  local path = cefport.contract_path()
  if path == "" then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  if type(s) ~= "string" then return nil end
  return (s:gsub("%s+$", ""))
end

return cefport
