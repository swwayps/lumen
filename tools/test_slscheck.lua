-- Host tests for slscheck.lua (the "slsteam-moon not loaded" backend) and
-- proc.lib_mapped (the /proc/<pid>/maps detection), with injected effects (no
-- real /proc, no terminal, no network).
-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_slscheck.lua
package.path = "lua/?.lua;" .. package.path

local json = require("json")
local proc = require("proc")
local slscheck = require("slscheck")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.write("FAIL: " .. name .. "\n") end
end

-- ── proc.lib_mapped against a fixture /proc tree ─────────────────────────────
-- Build a temp dir shaped like /proc: <pid>/comm + <pid>/maps.
local function mkfixture()
  local root = os.tmpname()
  os.remove(root)
  os.execute("mkdir -p " .. root)
  local function pid(n, comm, maps)
    local d = root .. "/" .. n
    os.execute("mkdir -p " .. d)
    local c = io.open(d .. "/comm", "w"); c:write(comm .. "\n"); c:close()
    local m = io.open(d .. "/maps", "w"); m:write(maps); m:close()
  end
  return root, pid
end

do
  local root, pid = mkfixture()
  -- The steam client HAS SLSsteam.so mapped -> injected.
  pid(1000, "steam",
    "7f00-7f10 r-xp 00000000 00:00 0 /home/u/.local/share/SLSsteam/SLSsteam.so\n" ..
    "7f20-7f30 r--p 00000000 00:00 0 /usr/lib/libc.so.6\n")
  -- A webhelper (different comm) that must NOT be matched by comm=="steam".
  pid(1001, "steamwebhelper", "7f40-7f50 r-xp 0 00:00 0 /usr/lib/libfoo.so\n")
  check("lib_mapped finds SLSsteam.so in steam", proc.lib_mapped("steam", "SLSsteam.so", root) == true)
  check("lib_mapped needle absent -> false", proc.lib_mapped("steam", "NoSuch.so", root) == false)
  check("lib_mapped comm mismatch -> false", proc.lib_mapped("gedit", "SLSsteam.so", root) == false)
  os.execute("rm -rf " .. root)
end

do
  local root, pid = mkfixture()
  -- steam running but NOT injected (no SLSsteam.so line).
  pid(2000, "steam", "7f00-7f10 r-xp 0 00:00 0 /usr/lib/libc.so.6\n")
  check("lib_mapped un-injected steam -> false", proc.lib_mapped("steam", "SLSsteam.so", root) == false)
  os.execute("rm -rf " .. root)
end

check("lib_mapped empty needle -> false", proc.lib_mapped("steam", "", "/proc") == false)
check("lib_mapped nil comm -> false", proc.lib_mapped(nil, "x", "/proc") == false)
check("lib_mapped missing root -> false", proc.lib_mapped("steam", "x", "/nonexistent-xyz") == false)

-- ── slscheck.is_loaded / get_loaded (injected mapped) ────────────────────────
check("is_loaded true when mapped", slscheck.is_loaded({ mapped = function() return true end }) == true)
check("is_loaded false when not mapped", slscheck.is_loaded({ mapped = function() return false end }) == false)
check("is_loaded coerces truthy to bool", slscheck.is_loaded({ mapped = function() return "yes" end }) == true)

do
  local r = json.decode(slscheck.get_loaded({ mapped = function() return true end }))
  check("get_loaded success", r.success == true)
  check("get_loaded loaded=true", r.loaded == true)
  local r2 = json.decode(slscheck.get_loaded({ mapped = function() return false end }))
  check("get_loaded loaded=false", r2.loaded == false)
end

-- ── autofix_script content ───────────────────────────────────────────────────
do
  local s = slscheck.autofix_script(slscheck.AUTOFIX_URL)
  check("script fetches autofix url", s:find(slscheck.AUTOFIX_URL, 1, true) ~= nil)
  check("script pipes to bash", s:find("| bash", 1, true) ~= nil)
  check("script pauses only on failure", s:find('status" %-ne 0') ~= nil)
  check("autofix url points at slsteam-moon raw branch",
    slscheck.AUTOFIX_URL:find("swwayps/slsteam%-moon/slsteam%-moon/autofix%.sh") ~= nil)
end

-- ── run_autofix orchestration (injected effects) ─────────────────────────────
do
  local wrote, spawned = nil, nil
  local res = slscheck.run_autofix({
    which = function(b) return b == "konsole" end,
    write_file = function(p, t) wrote = { path = p, text = t }; return true end,
    spawn = function(cmd) spawned = cmd; return true end,
    tmp_path = "/tmp/test-slsfix.sh",
  })
  check("run_autofix success", res.success == true and res.terminal == "konsole")
  check("run_autofix wrote script", wrote and wrote.path == "/tmp/test-slsfix.sh")
  check("run_autofix script has url", wrote and wrote.text:find(slscheck.AUTOFIX_URL, 1, true) ~= nil)
  check("run_autofix spawned konsole detached",
    spawned and spawned:find("setsid nohup", 1, true) ~= nil and spawned:find("'konsole'", 1, true) ~= nil)
end

do
  local res = slscheck.run_autofix({ which = function() return false end })
  check("run_autofix no terminal -> error", res.success == false
    and res.error:find("terminal", 1, true) ~= nil)
end

do
  local res = slscheck.run_autofix({
    which = function() return true end,
    write_file = function() return false end,
  })
  check("run_autofix write fail -> error", res.success == false
    and res.error:find("write", 1, true) ~= nil)
end

print(string.format("slscheck: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
