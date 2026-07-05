-- slscheck: backend for the "slsteam-moon not loaded" warning modal.
--
-- Exposes two RPCs (registered into the CDP dispatch registry by register()),
-- each returning a JSON string per the callServerMethod convention:
--   GetSlsLoaded()  -> {success, loaded}   is SLSsteam.so mapped into Steam?
--   RunSlsAutofix() -> {success[, error, terminal]}   open a terminal + auto-fix
--
-- The menu (menu/13-sls-check.js) calls GetSlsLoaded the moment the moon button
-- anchors; if slsteam-moon didn't inject, it shows a modal offering the auto-fix
-- (RunSlsAutofix), which re-installs the latest slsteam-moon, repairs every
-- *steam*.desktop launcher and relaunches Steam injected.
--
-- Detection lives in proc.lib_mapped (a /proc/<pid>/maps scan of the running
-- `steam` client). The terminal-launch machinery is reused verbatim from
-- about.lua so a single implementation covers "Update All" and this auto-fix.
local json = require("json")
local proc = require("proc")
local about = require("about")

local slscheck = {}

-- The main Steam client process (comm, exact) and the library we look for in
-- its address space. slsteam-moon loads via LD_AUDIT at preinit, so by the time
-- the moon button anchors it is definitely mapped if the session is injected.
slscheck.STEAM_COMM = "steam"
slscheck.LIB_NEEDLE = "SLSsteam.so"

-- The auto-fix script, served from the slsteam-moon repo's raw branch URL (like
-- install.sh) so fixes go live without cutting a new release. The main line is
-- the branch literally named `slsteam-moon`.
slscheck.AUTOFIX_URL =
  "https://raw.githubusercontent.com/swwayps/slsteam-moon/slsteam-moon/autofix.sh"

-- Single-quote a token for safe POSIX-shell interpolation.
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- is_loaded(opts) -> boolean. opts.mapped is injectable for tests; by default it
-- scans /proc for SLSsteam.so in the running `steam` process.
function slscheck.is_loaded(opts)
  opts = opts or {}
  local mapped = opts.mapped
    or function() return proc.lib_mapped(slscheck.STEAM_COMM, slscheck.LIB_NEEDLE) end
  return mapped() and true or false
end

-- get_loaded(opts) -> JSON string {success=true, loaded=<bool>}.
function slscheck.get_loaded(opts)
  return json.encode({ success = true, loaded = slscheck.is_loaded(opts) })
end

-- The bash script the terminal runs: fetch + run autofix.sh. autofix.sh owns its
-- own success pause and the Steam relaunch, so we only pause here when the fetch
-- itself failed (no network), to keep the error on screen. No user-controlled
-- input is interpolated (the URL is a constant), so this is injection-safe.
function slscheck.autofix_script(url)
  local run = "curl -fsSL " .. shq(url) .. " | bash"
  return table.concat({
    "#!/usr/bin/env bash",
    "set -u",
    'echo "slsteam-moon auto-fix"',
    "echo",
    run,
    "status=$?",
    'if [ "$status" -ne 0 ]; then',
    "  echo",
    '  echo "Auto-fix could not start (exit $status). Check your internet connection."',
    '  read -rp "Press Enter to close this window… " _',
    "fi",
    "",
  }, "\n")
end

-- run_autofix(opts) -> table {success[, error, terminal]}. opts (injectable for
-- tests): which (PATH probe), write_file, spawn, tmp_path. Reuses about.lua's
-- terminal detection + detached-launch helpers.
function slscheck.run_autofix(opts)
  opts = opts or {}
  local which = opts.which or function(bin)
    local f = io.popen("command -v " .. shq(bin) .. " 2>/dev/null", "r")
    if not f then return false end
    local out = f:read("*a") or ""
    f:close()
    return out:gsub("%s+", "") ~= ""
  end
  local write_file = opts.write_file or function(p, text)
    local f = io.open(p, "wb"); if not f then return false end
    f:write(text); f:close(); return true
  end
  local spawn = opts.spawn or function(cmd) return os.execute(cmd) end

  local term = about.detect_terminal(which)
  if not term then
    return {
      success = false,
      error = "No terminal emulator found. Run the auto-fix manually: "
        .. "curl -fsSL " .. slscheck.AUTOFIX_URL .. " | bash",
    }
  end

  local script = opts.tmp_path or ("/tmp/lumen-slsfix-" .. tostring(os.time()) .. ".sh")
  if not write_file(script, slscheck.autofix_script(slscheck.AUTOFIX_URL)) then
    return { success = false, error = "Could not write the auto-fix script." }
  end

  spawn(about.build_command(about.launch_argv(term, script)))
  return { success = true, terminal = term.bin }
end

-- register(registry): install GetSlsLoaded / RunSlsAutofix. Args from the
-- dispatcher are ignored (both are parameterless).
function slscheck.register(registry)
  registry.GetSlsLoaded = function() return slscheck.get_loaded() end
  registry.RunSlsAutofix = function() return json.encode(slscheck.run_autofix()) end
  return registry
end

return slscheck
