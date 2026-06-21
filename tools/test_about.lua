-- Host tests for about.lua: tag normalization/compare, latest-tag parsing,
-- installed-stamp reading, terminal detection + command building, and the
-- get_versions / update_all orchestration with injected effects (no network,
-- no desktop). Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_about.lua
package.path = "lua/?.lua;" .. package.path

local about = require("about")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.write("FAIL: " .. name .. "\n") end
end

-- ── norm_tag ────────────────────────────────────────────────────────────────
check("norm strips v + lowercases", about.norm_tag("v2.5") == "2.5")
check("norm trims whitespace", about.norm_tag("  v2.6-lumen \n") == "2.6-lumen")
check("norm no-v passthrough", about.norm_tag("3") == "3")
check("norm nil", about.norm_tag(nil) == nil)
check("norm empty", about.norm_tag("   ") == nil)

-- ── fmt_date ──────────────────────────────────────────────────────────────────
check("fmt iso -> dd/mm/yyyy", about.fmt_date("2026-06-21T03:15:25+02:00") == "21/06/2026")
check("fmt nil", about.fmt_date(nil) == "")
check("fmt garbage", about.fmt_date("nope") == "")

-- ── compare_state (asset fingerprint) ────────────────────────────────────────
-- Same tag AND same asset fingerprint -> current.
check("compare same asset -> current", about.compare_state(
  { tag = "v2.6", asset_at = "2026-06-17T00:00:00Z", size = 100 },
  { tag = "v2.6", asset_at = "2026-06-17T00:00:00Z", size = 100 }) == "current")
-- THE KEY CASE: same tag, asset re-uploaded (newer created_at) -> update.
check("compare same tag, new asset -> update", about.compare_state(
  { tag = "v2.6", asset_at = "2026-06-17T00:00:00Z", size = 100 },
  { tag = "v2.6", asset_at = "2026-06-21T03:15:25Z", size = 100 }) == "update")
-- Same tag + same time but different size -> update.
check("compare same tag, size change -> update", about.compare_state(
  { tag = "v2.6", asset_at = "2026-06-17T00:00:00Z", size = 100 },
  { tag = "v2.6", asset_at = "2026-06-17T00:00:00Z", size = 200 }) == "update")
-- Tag bump (v2.6 -> v2.7) with a new asset -> update.
check("compare tag bump -> update", about.compare_state(
  { tag = "v2.6", asset_at = "2026-06-17T00:00:00Z", size = 100 },
  { tag = "v2.7", asset_at = "2026-06-21T00:00:00Z", size = 200 }) == "update")
-- Tag bump caught even if the asset fingerprint somehow looks identical.
check("compare tag bump wins over identical asset", about.compare_state(
  { tag = "v2.6", asset_at = "2026-06-17T00:00:00Z", size = 100 },
  { tag = "v2.7", asset_at = "2026-06-17T00:00:00Z", size = 100 }) == "update")
-- No fingerprint on installed side (legacy stamp): fall back to tag compare.
check("compare legacy tag equal -> current", about.compare_state(
  { tag = "v2.6" }, { tag = "v2.6", asset_at = "x", size = 1 }) == "current")
check("compare legacy tag differ -> update", about.compare_state(
  { tag = "v2.5" }, { tag = "v2.6", asset_at = "x", size = 1 }) == "update")
check("compare no latest -> unknown", about.compare_state({ tag = "v2.6" }, nil) == "unknown")
check("compare no installed tag (legacy) -> unknown", about.compare_state(
  {}, { tag = "v2.6" }) == "unknown")

-- ── parse_latest_info ─────────────────────────────────────────────────────────
do
  local body = '{"tag_name":"v2.6","assets":[' ..
    '{"name":"other.zip","created_at":"2026-01-01T00:00:00Z","size":1},' ..
    '{"name":"lumen-linux.zip","created_at":"2026-06-21T03:15:25Z","size":2614842}]}'
  local info = about.parse_latest_info(body, "^lumen%-linux%.zip$")
  check("parse tag", info and info.tag == "v2.6")
  check("parse matched asset_at", info.asset_at == "2026-06-21T03:15:25Z")
  check("parse matched size", info.size == 2614842)
end
check("parse no matching asset -> tag only",
  (function() local i = about.parse_latest_info('{"tag_name":"v2.6","assets":[]}', "^x$")
     return i and i.tag == "v2.6" and i.asset_at == nil end)())
check("parse missing tag", about.parse_latest_info('{"assets":[]}', "^x$") == nil)
check("parse bad json", about.parse_latest_info("not json", "^x$") == nil)
check("parse empty", about.parse_latest_info("", "^x$") == nil)

-- ── read_installed (rich + legacy shapes) ────────────────────────────────────
local function reader_returning(s) return function() return s end end
do
  local t = about.read_installed("x", reader_returning(
    '{"plugin":{"tag":"v3","asset_at":"t","size":9},"lumen":"v2.5"}'))
  local pe = about.installed_entry(t, "plugin")
  check("installed rich tag", pe.tag == "v3" and pe.asset_at == "t" and pe.size == 9)
  local le = about.installed_entry(t, "lumen")
  check("installed legacy string tag", le.tag == "v2.5" and le.asset_at == nil)
  check("installed missing key -> empty", next(about.installed_entry(t, "nope")) == nil)
end
check("installed missing file -> {}",
  next(about.read_installed("x", function() return nil end)) == nil)
check("installed bad json -> {}",
  next(about.read_installed("x", reader_returning("garbage"))) == nil)

-- ── fetch_latest_info (injected http) ────────────────────────────────────────
local function http_status(status, body)
  return { get = function() return { status = status, body = body }, nil end }
end
do
  local comp = { repo = "a/b", asset_pat = "^lumen%-linux%.zip$" }
  local body = '{"tag_name":"v9","assets":[{"name":"lumen-linux.zip","created_at":"T","size":5}]}'
  local info = about.fetch_latest_info(comp, http_status(200, body))
  check("fetch ok tag", info and info.tag == "v9")
  check("fetch ok fingerprint", info.asset_at == "T" and info.size == 5)
  check("fetch non-200", about.fetch_latest_info(comp, http_status(404, "")) == nil)
  check("fetch nil resp",
    about.fetch_latest_info(comp, { get = function() return nil, "err" end }) == nil)
end

-- ── get_versions orchestration ───────────────────────────────────────────────
do
  -- installed plugin asset_at is OLDER than the API's -> "update" (same tag,
  -- re-uploaded asset). slsteam_moon matches exactly -> "current". lumen has no
  -- installed entry -> "unknown".
  local api_body = function(url)
    -- Every repo returns v2.6 with a matching asset uploaded at 06-21.
    local name = url:find("lumen", 1, true) and "lumen-linux.zip"
      or url:find("ltsteamplugin", 1, true) and "luatools-linux.zip"
      or "slsteam-moon-linux-2.6-lumen.zip"
    return '{"tag_name":"v2.6","assets":[{"name":"' .. name ..
      '","created_at":"2026-06-21T03:15:25Z","size":100}]}'
  end
  local http = { get = function(url) return { status = 200, body = api_body(url) }, nil end }
  local res = about.get_versions({
    http = http,
    read_file = reader_returning(
      '{"slsteam_moon":{"tag":"v2.6","asset_at":"2026-06-21T03:15:25Z","size":100},' ..
      '"plugin":{"tag":"v2.6","asset_at":"2026-06-17T00:00:00Z","size":100}}'),
  })
  check("gv success", res.success == true and #res.components == 3)
  local by = {}
  for _, c in ipairs(res.components) do by[c.key] = c end
  check("gv sls current (same asset)", by.slsteam_moon.state == "current")
  check("gv plugin update (asset re-uploaded, same tag)", by.plugin.state == "update")
  check("gv plugin shows build dates", by.plugin.installedBuild == "17/06/2026"
    and by.plugin.latestBuild == "21/06/2026")
  check("gv lumen unknown (no installed entry)", by.lumen.state == "unknown")
end
do
  -- Forge down (nil resp) -> every latest unknown.
  local res = about.get_versions({
    http = { get = function() return nil, "down" end },
    read_file = reader_returning('{"plugin":{"tag":"v2.6","asset_at":"t","size":1}}'),
  })
  local by = {}
  for _, c in ipairs(res.components) do by[c.key] = c end
  check("gv forge-down plugin unknown", by.plugin.state == "unknown")
end

-- ── terminal detection + command building ────────────────────────────────────
do
  -- Only konsole present -> picked; x-terminal-emulator/gnome-terminal absent.
  local term = about.detect_terminal(function(b) return b == "konsole" end)
  check("detect konsole", term and term.bin == "konsole" and term.mode == "dashe")
  local argv = about.launch_argv(term, "/tmp/u.sh")
  check("konsole argv", argv[1] == "konsole" and argv[2] == "-e"
    and argv[3] == "bash" and argv[4] == "/tmp/u.sh")
end
do
  -- Preference order: when several exist, the first in the list wins.
  local present = { ["xterm"] = true, ["gnome-terminal"] = true }
  local term = about.detect_terminal(function(b) return present[b] == true end)
  check("detect prefers gnome-terminal over xterm", term.bin == "gnome-terminal")
  local argv = about.launch_argv(term, "/tmp/u.sh")
  check("gnome-terminal uses --", argv[2] == "--")
end
check("detect none -> nil", about.detect_terminal(function() return false end) == nil)
do
  local cmd = about.build_command({ "gnome-terminal", "--", "bash", "/tmp/u.sh" })
  check("build_command detached", cmd:find("setsid nohup", 1, true) ~= nil
    and cmd:sub(-1) == "&")
  check("build_command quotes tokens", cmd:find("'gnome%-terminal'") ~= nil)
end
do
  local s = about.update_script(about.INSTALL_URL)
  check("script has installer url", s:find(about.INSTALL_URL, 1, true) ~= nil)
  check("script pauses", s:find("Press Enter", 1, true) ~= nil)
end

-- ── update_all orchestration (injected effects) ──────────────────────────────
do
  local wrote, spawned = nil, nil
  local res = about.update_all({
    which = function(b) return b == "kitty" end,
    write_file = function(p, t) wrote = { path = p, text = t }; return true end,
    spawn = function(cmd) spawned = cmd; return true end,
    tmp_path = "/tmp/test-update.sh",
  })
  check("update_all success", res.success == true and res.terminal == "kitty")
  check("update_all wrote script", wrote and wrote.path == "/tmp/test-update.sh")
  check("update_all spawned kitty", spawned and spawned:find("'kitty'", 1, true) ~= nil)
  check("update_all kitty direct mode", spawned:find("'bash' '/tmp/test%-update.sh'") ~= nil)
end
do
  local res = about.update_all({ which = function() return false end })
  check("update_all no terminal -> error", res.success == false
    and res.error:find("No terminal", 1, true) ~= nil)
end
do
  local res = about.update_all({
    which = function() return true end,
    write_file = function() return false end,
  })
  check("update_all write fail -> error", res.success == false
    and res.error:find("write", 1, true) ~= nil)
end

print(string.format("about: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
