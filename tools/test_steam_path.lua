-- Run via the built binary (lfs is in the binary, not host lua5.4):
--   LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_steam_path.lua
--
-- Guards millennium.steam_path() against materializing a phantom
-- ~/.steam/steam directory. The function must:
--   * resolve a real, bootstrapped Steam root (one that has steam.sh),
--     across distro layouts (Fedora ~/.local/share/Steam, Debian
--     ~/.steam/debian-installation, classic ~/.steam/steam);
--   * return "" when no bootstrapped Steam exists, so callers skip instead
--     of creating ~/.steam/steam as a real dir (which breaks Valve bootstrap).
package.path = "lua/?.lua;" .. package.path
local fs = require("fs")

local fails = 0
local function ok(cond, name)
  if cond then
    io.write("ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. "\n")
    fails = fails + 1
  end
end

local base = "/tmp/lumen_steam_path_test"
os.execute("rm -rf " .. base)

-- Sandbox HOME so steam_path() scans our fixtures.
local orig_getenv = os.getenv
local function set_home(h) os.getenv = function(k) if k == "HOME" then return h end return orig_getenv(k) end end

-- Fresh require each case (the module is stateless, but be explicit).
local function fresh_steam_path()
  package.loaded["millennium"] = nil
  return require("millennium").steam_path
end

-- Case 1: Fedora/Arch layout — ~/.steam/steam symlinks to ~/.local/share/Steam.
do
  local home = base .. "/fedora"
  os.execute("mkdir -p '" .. home .. "/.local/share/Steam'")
  os.execute("touch '" .. home .. "/.local/share/Steam/steam.sh'")
  os.execute("mkdir -p '" .. home .. "/.steam'")
  os.execute("ln -s '" .. home .. "/.local/share/Steam' '" .. home .. "/.steam/steam'")
  set_home(home)
  local p = fresh_steam_path()()
  ok(fs.exists(fs.join(p, "steam.sh")), "C1 fedora: resolves a real root (has steam.sh)")
end

-- Case 2: Debian/Mint layout — ~/.steam/steam symlinks to ~/.steam/debian-installation.
do
  local home = base .. "/debian"
  os.execute("mkdir -p '" .. home .. "/.steam/debian-installation'")
  os.execute("touch '" .. home .. "/.steam/debian-installation/steam.sh'")
  os.execute("ln -s '" .. home .. "/.steam/debian-installation' '" .. home .. "/.steam/steam'")
  set_home(home)
  local p = fresh_steam_path()()
  ok(fs.exists(fs.join(p, "steam.sh")), "C2 debian: resolves a real root (has steam.sh)")
end

-- Case 3: Never bootstrapped — nothing exists. Must return "" and NOT create
-- ~/.steam/steam.
do
  local home = base .. "/fresh"
  os.execute("mkdir -p '" .. home .. "'")
  set_home(home)
  local p = fresh_steam_path()()
  ok(p == "", "C3 fresh: returns empty when no bootstrapped Steam")
  ok(not fs.exists(home .. "/.steam/steam"), "C3 fresh: did NOT create ~/.steam/steam")
end

-- Case 4: Phantom dir present (the bug) — ~/.steam/steam is a real directory
-- with only steamui/ in it, no steam.sh. Must be rejected (not treated as a
-- real root) and return "".
do
  local home = base .. "/phantom"
  os.execute("mkdir -p '" .. home .. "/.steam/steam/steamui/webkit'")
  set_home(home)
  local p = fresh_steam_path()()
  ok(p == "", "C4 phantom: rejects ~/.steam/steam dir without steam.sh")
end

os.getenv = orig_getenv
os.execute("rm -rf " .. base)

if fails == 0 then io.write("\ntest_steam_path: ALL PASS\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
