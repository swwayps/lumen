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

local function run_with(guardian_available, cli_present, mode)
  local commands = {}
  local result = deskcover.run(mode, {
    execute = function(command)
      commands[#commands + 1] = command
      if #commands == 1 then return guardian_available end
      return true
    end,
    file_exists = function(path)
      ok(path == deskcover.cli_path(), "run checks the coverage CLI path")
      return cli_present
    end,
  })
  return result, commands
end

local ran, commands = run_with(true, true, "--user")
ok(ran == true, "available guardian -> success")
ok(#commands == 2, "available guardian -> probe then start")
ok(commands[1] == "timeout 1s systemctl --user --quiet --no-ask-password " ..
                  "is-enabled slsteam-desktop-guardian.path >/dev/null 2>&1",
   "guardian probe is bounded and noninteractive")
ok(commands[2] == "systemctl --user start slsteam-desktop-guardian.service >/dev/null 2>&1 &",
   "available guardian -> detached service start")

ran, commands = run_with(false, true, nil)
ok(ran == true, "unavailable guardian + CLI -> success")
ok(#commands == 2, "unavailable guardian + CLI -> probe then fallback")
ok(commands[2] == '"' .. deskcover.cli_path() .. '" --user >/dev/null 2>&1 &',
   "unavailable guardian + CLI -> exact default detached CLI fallback")

ran, commands = run_with(false, true, "--system")
ok(commands[2] == '"' .. deskcover.cli_path() .. '" --system >/dev/null 2>&1 &',
   "CLI fallback preserves an explicit mode")

ran, commands = run_with(false, false, "--user")
ok(ran == false, "unavailable guardian without CLI -> false")
ok(#commands == 1, "unavailable guardian without CLI -> probe only")

print("test_deskcover: ALL PASS")
