-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_privatefs.lua
--
-- Scripts that Lumen writes and then hands to a terminal to EXECUTE used to be
-- created with io.open(path, "wb") at a predictable /tmp path derived from
-- os.time(). Two local attacks followed from that: pre-create the path as a
-- symlink and the write lands on the target (a shell rc file); or pre-create the
-- file so the attacker owns it, let the victim truncate and write, then rewrite
-- the contents before the terminal starts. The RPCs that trigger those writes
-- are reachable from the frontend, so the attacker also controls the timing.
--
-- privatefs writes with O_CREAT|O_EXCL|O_NOFOLLOW at mode 0600 inside a 0700
-- directory under $XDG_RUNTIME_DIR, with a random name.
package.path = "lua/?.lua;" .. package.path
local lfs = require("lfs")
local privatefs = require("privatefs")

local checks = 0
local function ok(c, m)
  checks = checks + 1
  if not c then error("FAIL: " .. (m or "")) end
end

local root = os.getenv("TMPDIR") or "/tmp"
local base = root .. "/lumen-privatefs-test-" .. tostring(os.time())
             .. "-" .. tostring(math.random(1e6))
lfs.mkdir(base)

local function mode_of(path)
  return lfs.attributes(path, "permissions")
end

-- ── mkdir_private ───────────────────────────────────────────────────────────
do
  local dir = base .. "/d1"
  ok(privatefs.mkdir_private(dir) == true, "creates a directory")
  ok(mode_of(dir) == "rwx------", "directory is 0700, got " .. tostring(mode_of(dir)))
  -- Idempotent on an existing private directory.
  ok(privatefs.mkdir_private(dir) == true, "existing private directory accepted")
end

do
  -- A directory that is group/world accessible must be rejected, not silently
  -- reused: anything already inside it may not be ours.
  local dir = base .. "/d2"
  lfs.mkdir(dir)
  os.execute("chmod 0777 " .. dir)
  ok(privatefs.mkdir_private(dir) == false, "world-writable directory refused")
end

do
  -- A symlink standing in for the directory is refused.
  local target = base .. "/d3-target"
  local link = base .. "/d3"
  lfs.mkdir(target)
  os.execute("chmod 0700 " .. target)
  os.execute("ln -s " .. target .. " " .. link)
  ok(privatefs.mkdir_private(link) == false, "symlinked directory refused")
end

-- ── write_private ───────────────────────────────────────────────────────────
do
  local path = base .. "/f1"
  ok(privatefs.write_private(path, "hello") == true, "writes a new file")
  ok(mode_of(path) == "rw-------", "file is 0600, got " .. tostring(mode_of(path)))
  local f = assert(io.open(path, "rb"))
  ok(f:read("*a") == "hello", "content is written verbatim")
  f:close()
end

do
  -- An existing path is NOT overwritten: O_EXCL is what defeats the pre-create
  -- race, so a second write to the same name has to fail.
  local path = base .. "/f2"
  ok(privatefs.write_private(path, "first") == true, "first write succeeds")
  ok(privatefs.write_private(path, "second") == false, "existing file is not overwritten")
  local f = assert(io.open(path, "rb"))
  ok(f:read("*a") == "first", "original content survives")
  f:close()
end

do
  -- A symlink at the destination must not be followed. Without O_NOFOLLOW this
  -- write would land on the link target.
  local victim = base .. "/victim"
  local vf = assert(io.open(victim, "wb")); vf:write("original"); vf:close()
  local link = base .. "/f3"
  os.execute("ln -s " .. victim .. " " .. link)
  ok(privatefs.write_private(link, "payload") == false, "symlink destination refused")
  local f = assert(io.open(victim, "rb"))
  ok(f:read("*a") == "original", "the symlink target is untouched")
  f:close()
end

do
  -- Binary-safe, including NUL and a large body.
  local path = base .. "/f4"
  local data = "a\0b\255" .. string.rep("x", 100000)
  ok(privatefs.write_private(path, data) == true, "writes binary content")
  local f = assert(io.open(path, "rb"))
  ok(f:read("*a") == data, "binary content round-trips")
  f:close()
end

do
  ok(privatefs.write_private(base .. "/missing-dir/f", "x") == false,
    "a missing parent directory fails rather than creating one")
  ok(privatefs.write_private(nil, "x") == false, "nil path refused")
  ok(privatefs.write_private(base .. "/f5", nil) == false, "nil content refused")
end

-- ── runtime_dir / temp_script_path ──────────────────────────────────────────
do
  -- With XDG_RUNTIME_DIR set, that is where private work goes.
  local dir = privatefs.runtime_dir({ xdg = base, home = base })
  ok(type(dir) == "string" and dir:find(base, 1, true) == 1,
    "runtime dir sits under XDG_RUNTIME_DIR: " .. tostring(dir))
  ok(mode_of(dir) == "rwx------", "runtime dir is 0700")
end

do
  -- Without it, a private directory under HOME is used instead of /tmp, which is
  -- shared with every other local user.
  local dir = privatefs.runtime_dir({ xdg = nil, home = base })
  ok(type(dir) == "string" and dir:find(base .. "/", 1, true) == 1,
    "falls back inside HOME: " .. tostring(dir))
  ok(mode_of(dir) == "rwx------", "fallback dir is 0700")
  -- The point of the fallback is that it is NOT the shared temp directory.
  local f = assert(io.open("lua/privatefs.lua", "r"))
  local source = f:read("*a"); f:close()
  ok(not source:find('"/tmp', 1, true), "privatefs never names /tmp as a location")
end

do
  local a = privatefs.temp_script_path("lumen-update", { xdg = base, home = base })
  local b = privatefs.temp_script_path("lumen-update", { xdg = base, home = base })
  ok(type(a) == "string" and a:match("%.sh$"), "temp path ends in .sh: " .. tostring(a))
  ok(a ~= b, "temp paths are not predictable")
  ok(mode_of(a:match("^(.*)/[^/]+$")) == "rwx------",
    "the directory holding the temp script is 0700")
  -- The file NAME must not be derived from the clock (the old path was
  -- /tmp/lumen-update-<os.time()>.sh, guessable within a second).
  local name = a:match("([^/]+)$")
  ok(not name:find(tostring(os.time()), 1, true),
    "temp file name does not embed the current time: " .. tostring(name))
  ok(#name >= 20, "temp file name carries enough entropy: " .. tostring(name))
end

do
  -- write_script creates the file executable-by-owner only.
  local dir = privatefs.runtime_dir({ xdg = base, home = base })
  local path = dir .. "/s1.sh"
  ok(privatefs.write_script(path, "#!/bin/sh\ntrue\n") == true, "writes a script")
  ok(mode_of(path) == "rwx------", "script is 0700, got " .. tostring(mode_of(path)))
end

os.execute("rm -rf " .. base)
print("test_privatefs: ALL PASS (" .. checks .. " checks)")
