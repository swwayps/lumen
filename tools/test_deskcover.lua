-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_deskcover.lua
-- Pure tick-decision tests for deskcover: given the autostart file's state
-- (exists/mtime/patched), decide when a re-patch should fire, rate-limited to
-- one check per interval. No IO here.
package.path = "lua/?.lua;" .. package.path
local deskcover = require("deskcover")

local function ok(c, m) if not c then error("FAIL: " .. (m or "")) end end

local w = deskcover.new_tick({ interval = 3 })

-- first observation: present, never patched -> patch
ok(w:should_repatch(0, { exists = true, mtime = 100, patched = false }) == true,
   "new vanilla autostart -> patch")
-- already patched, unchanged -> skip
ok(w:should_repatch(3, { exists = true, mtime = 100, patched = true }) == false,
   "patched + unchanged -> skip")
-- mtime changed + vanilla (Steam rewrote it) -> patch
ok(w:should_repatch(6, { exists = true, mtime = 200, patched = false }) == true,
   "rewritten vanilla -> patch")
-- absent -> skip
ok(w:should_repatch(9, { exists = false, mtime = 0, patched = false }) == false,
   "absent -> skip")
-- within the interval -> skip even if changed (rate limit)
ok(w:should_repatch(10, { exists = true, mtime = 400, patched = false }) == false,
   "within interval -> rate-limited skip")

-- path helpers derive from $HOME
local home = os.getenv("HOME") or ""
ok(deskcover.autostart_path() == home .. "/.config/autostart/steam.desktop",
   "autostart path")
ok(deskcover.cli_path() == home .. "/.local/share/SLSsteam/ensure-desktop-coverage.sh",
   "cli path")

print("test_deskcover: ALL PASS")
