-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_peerauth.lua
--
-- The injector talks CDP to whatever is listening on the CEF port. Nothing used
-- to establish that the peer WAS the Steam client, so any unprivileged local
-- process could bind 127.0.0.1:8080 before Steam, serve a fake /json plus a
-- WebSocket, and drive the backend registry by emitting Runtime.bindingCalled
-- events. peerauth resolves the owner of the listening socket through /proc and
-- refuses to hand the handshake to anything that is not Steam.
package.path = "lua/?.lua;" .. package.path
local peerauth = require("peerauth")

local checks = 0
local function ok(c, m)
  checks = checks + 1
  if not c then error("FAIL: " .. (m or "")) end
end

local TCP = [[
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:0035 00000000:0000 0A 00000000:00000000 00:00000000 00000000   974        0 15473 1 0000000000000000 100 0 0 10 5
   1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 987654 1 0000000000000000 100 0 0 10 0
   2: 0100007F:1F91 0100007F:C001 01 00000000:00000000 00:00000000 00000000  1000        0 111111 1 0000000000000000 100 0 0 10 0
]]

local TCP6 = [[
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000001:1F92 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 222222 1 0000000000000000 100 0 0 10 5
]]

-- ── /proc/net/tcp parsing ───────────────────────────────────────────────────

-- 8080 == 0x1F90: the LISTEN row's inode is picked up.
do
  local inodes = peerauth.listener_inodes(TCP, 8080)
  ok(#inodes == 1 and inodes[1] == 987654, "listen inode for port 8080")
end

-- A non-LISTEN row on a neighbouring port is not a listener.
do
  local inodes = peerauth.listener_inodes(TCP, 8081)
  ok(#inodes == 0, "established socket is not a listener")
end

-- Ports are matched exactly, never by hex prefix.
do
  ok(#peerauth.listener_inodes(TCP, 53) == 1, "port 53 (0x0035) found")
  -- A listener on a different loopback address (127.0.0.54) is a different
  -- socket from the 127.0.0.1 one the injector connects to.
  local OTHER_LOOPBACK = [[
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 3600007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 777777 1 0000000000000000 100 0 0 10 0
]]
  ok(#peerauth.listener_inodes(OTHER_LOOPBACK, 8080) == 0,
    "a listener on another loopback address is not counted")
  ok(#peerauth.listener_inodes(TCP, 8082) == 0, "unlisted port yields nothing")
  ok(#peerauth.listener_inodes(TCP, 0) == 0, "port 0 yields nothing")
end

-- The IPv6 table uses a 32-hex-digit address; the same row shape applies.
do
  local inodes = peerauth.listener_inodes(TCP6, 8082)
  ok(#inodes == 1 and inodes[1] == 222222, "ipv6 listen inode parsed")
end

-- Garbage in never produces a false inode.
do
  ok(#peerauth.listener_inodes("", 8080) == 0, "empty table")
  ok(#peerauth.listener_inodes(nil, 8080) == 0, "nil table")
  ok(#peerauth.listener_inodes("nonsense\nlines\n", 8080) == 0, "unparseable table")
end

-- ── executable identification ───────────────────────────────────────────────
do
  ok(peerauth.is_steam_exe("/home/u/.steam/steam/ubuntu12_64/steamwebhelper"),
    "steamwebhelper accepted")
  ok(peerauth.is_steam_exe("/home/u/.steam/steam/ubuntu12_32/steam"),
    "steam accepted")
  ok(peerauth.is_steam_exe("/home/u/.local/share/Steam/ubuntu12_32/steam"),
    "the data-dir installation is accepted")
  ok(not peerauth.is_steam_exe("/tmp/evil"), "unrelated binary refused")
  ok(not peerauth.is_steam_exe("/tmp/steamwebhelper-evil"),
    "lookalike suffix refused")
  ok(not peerauth.is_steam_exe("/tmp/mysteam"), "lookalike prefix refused")
  ok(not peerauth.is_steam_exe("/tmp/steam.sh"), "launcher script refused")
  -- The right NAME in the wrong place is the trivial squatter: any process can
  -- call its binary "steam", so the path has to place it in a Steam install.
  ok(not peerauth.is_steam_exe("/tmp/steam"), "correct name outside a Steam tree refused")
  ok(not peerauth.is_steam_exe("/home/u/evil/steamwebhelper"),
    "correct name in an unrelated directory refused")
  ok(not peerauth.is_steam_exe(nil), "nil refused")
  ok(not peerauth.is_steam_exe(""), "empty refused")
  -- A deleted binary is reported by the kernel with a " (deleted)" suffix; that
  -- is not the same file any more, so it is not trusted.
  ok(not peerauth.is_steam_exe("/home/u/.steam/steam/ubuntu12_64/steamwebhelper (deleted)"),
    "deleted binary refused")
end

-- ── socket owner resolution ─────────────────────────────────────────────────
local function deps(overrides)
  local d = {
    read_tcp = function() return TCP end,
    read_tcp6 = function() return TCP6 end,
    list_pids = function() return { 100, 200 } end,
    fd_targets = function(pid)
      if pid == 200 then return { "/dev/null", "socket:[987654]" } end
      return { "socket:[42]" }
    end,
    exe_target = function(pid)
      if pid == 200 then return "/home/u/.steam/steam/ubuntu12_64/steamwebhelper" end
      return "/usr/bin/python3"
    end,
  }
  for k, v in pairs(overrides or {}) do d[k] = v end
  return d
end

-- The pid holding the socket inode is found and identified as Steam.
do
  local pid = peerauth.owner_pid(987654, deps())
  ok(pid == 200, "owner pid resolved from fd links")
  local trusted, reason = peerauth.verify(8080, deps())
  ok(trusted == true, "steam-owned listener trusted (" .. tostring(reason) .. ")")
end

-- An unrelated process squatting the port is refused.
do
  local trusted, reason = peerauth.verify(8080, deps({
    exe_target = function() return "/tmp/evil" end,
  }))
  ok(trusted == false, "squatter refused")
  ok(reason == "not steam", "reason names the check that failed: " .. tostring(reason))
end

-- No listener at all on the port: refuse, and say so distinctly from "not
-- steam" so the caller can keep waiting instead of giving up.
do
  local trusted, reason = peerauth.verify(9999, deps())
  ok(trusted == false, "no listener refused")
  ok(reason == "no listener", "reason is 'no listener': " .. tostring(reason))
end

-- The socket exists but no readable /proc entry owns it (hidepid, or a process
-- we cannot inspect). Fail closed.
do
  local trusted, reason = peerauth.verify(8080, deps({
    fd_targets = function() return {} end,
  }))
  ok(trusted == false, "unresolvable owner refused")
  ok(reason == "owner unknown", "reason is 'owner unknown': " .. tostring(reason))
end

-- Reading /proc raising an error must not propagate out of verify.
do
  local trusted, reason = peerauth.verify(8080, deps({
    read_tcp = function() error("boom") end,
    read_tcp6 = function() error("boom") end,
  }))
  ok(trusted == false, "read failure refused")
  ok(reason == "no listener", "read failure treated as no listener")
end

-- ── caching ─────────────────────────────────────────────────────────────────
-- The cheap listener table is checked on every discovery tick, while the
-- expensive all-process fd walk is reused as long as the listening socket's
-- inode is unchanged. A port handoff necessarily creates a new inode.
do
  local listener_reads, owner_reads = 0, 0
  local d = deps({
    read_tcp = function() listener_reads = listener_reads + 1; return TCP end,
    fd_targets = function(pid)
      owner_reads = owner_reads + 1
      if pid == 200 then return { "/dev/null", "socket:[987654]" } end
      return { "socket:[42]" }
    end,
  })
  local cache = peerauth.new_cache()
  ok(peerauth.verify_cached(cache, 8080, d, 1000) == true, "first check trusts")
  ok(peerauth.verify_cached(cache, 8080, d, 1000) == true, "second check trusts")
  ok(listener_reads == 2, "listener identity is checked on every call")
  ok(owner_reads == 2, "unchanged inode skips the second fd walk")
  -- A different port is a different peer and must be re-verified.
  peerauth.verify_cached(cache, 9999, d, 1000)
  ok(listener_reads == 3, "new port checks its listener table")
end

-- A refusal is NOT cached as a permanent verdict: Steam may simply not have
-- opened the port yet, and the next tick has to look again.
do
  local scans = 0
  local d = deps({
    read_tcp = function() scans = scans + 1; return TCP end,
    read_tcp6 = function() return TCP6 end,
  })
  local cache = peerauth.new_cache()
  ok(peerauth.verify_cached(cache, 9999, d) == false, "unknown port refused")
  ok(peerauth.verify_cached(cache, 9999, d) == false, "still refused")
  ok(scans == 2, "refusals are re-checked, not cached (scans=" .. scans .. ")")
end

-- ── the positive verdict is bound to the listener inode ─────────────────────
do
  local owner_reads = 0
  local d = deps({
    fd_targets = function(pid)
      owner_reads = owner_reads + 1
      if pid == 200 then return { "socket:[987654]" } end
      return {}
    end,
  })
  local cache = peerauth.new_cache()
  ok(peerauth.verify_cached(cache, 8080, d, 1000) == true, "trusted at t=1000")
  ok(peerauth.verify_cached(cache, 8080, d, 999999) == true,
    "same socket stays trusted without a timed fd rescan")
  ok(owner_reads == 2, "only the first check walked both candidate processes")
end

do
  -- A handoff inside the old two-second cache window must be noticed at once.
  local current_tcp = TCP
  local d = deps({
    read_tcp = function() return current_tcp end,
    fd_targets = function(pid)
      if pid == 200 and current_tcp == TCP then return { "socket:[987654]" } end
      if pid == 200 then return { "socket:[123456]" } end
      return {}
    end,
    exe_target = function()
      return current_tcp == TCP
        and "/home/u/.steam/steam/ubuntu12_64/steamwebhelper" or "/tmp/steam"
    end,
  })
  local cache = peerauth.new_cache()
  ok(peerauth.verify_cached(cache, 8080, d, 2000) == true, "trusted while Steam owns it")
  current_tcp = TCP:gsub("987654", "123456")
  ok(peerauth.verify_cached(cache, 8080, d, 2000.1) == false,
    "new listener inode is refused immediately when its owner is not Steam")
end

do
  -- invalidate() drops the verdict immediately, for use when a connection to the
  -- port fails.
  local d = deps()
  local cache = peerauth.new_cache()
  ok(peerauth.verify_cached(cache, 8080, d, 3000) == true, "trusted")
  peerauth.invalidate(cache)
  ok(cache.trusted == false and cache.port == nil, "invalidate clears the entry")
end

-- ── the listener must be on loopback ────────────────────────────────────────
-- The injector always connects to 127.0.0.1. A Steam-owned listener on some other
-- local address must not vouch for whoever holds the loopback address.
do
  local FOREIGN = [[
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100A8C0:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 987654 1 0000000000000000 100 0 0 10 0
]]
  ok(#peerauth.listener_inodes(FOREIGN, 8080) == 0,
    "a listener on a non-loopback address is not counted")

  local WILDCARD = [[
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 555555 1 0000000000000000 100 0 0 10 0
]]
  local wild = peerauth.listener_inodes(WILDCARD, 8080)
  ok(#wild == 1 and wild[1] == 555555,
    "a wildcard listener is counted (it includes loopback)")

  local MAPPED = [[
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0000000000000000FFFF00000100007F:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 666666 1 0000000000000000 100 0 0 10 5
]]
  local mapped = peerauth.listener_inodes(MAPPED, 8080)
  ok(#mapped == 1 and mapped[1] == 666666,
    "an IPv4-mapped loopback listener is counted")
end

print("test_peerauth: hardening PASS")
