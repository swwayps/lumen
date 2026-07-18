-- Host tests for about.lua: tag normalization/compare, latest-tag parsing,
-- installed-stamp reading, terminal detection + command building, and the
-- get_versions / update_all orchestration with injected effects (no network,
-- no desktop). Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_about.lua
package.path = "lua/?.lua;" .. package.path

local about = require("about")
local json = require("json")

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

-- ── compare_state (asset id, the canonical per-upload identifier) ─────────────
-- Same tag, same asset id -> current (id wins over a noisy asset_at/size).
check("compare same id -> current", about.compare_state(
  { tag = "v2.6", id = 100, asset_at = "a", size = 1 },
  { tag = "v2.6", id = 100, asset_at = "b", size = 2 }) == "current")
-- Same tag, different asset id (re-upload) -> update.
check("compare diff id -> update", about.compare_state(
  { tag = "v2.6", id = 100 }, { tag = "v2.6", id = 200 }) == "update")
-- id compared as a string so a number/string mix from mixed decoders still matches.
check("compare id num/str equal -> current", about.compare_state(
  { tag = "v2.6", id = "100" }, { tag = "v2.6", id = 100 }) == "current")

-- ── installed_entry null-fingerprint normalization (out-of-band install) ──────
-- A manual install (no install.sh stamping) writes {tag, asset_at:null, size:null}.
-- json.decode renders null as a TRUTHY sentinel, which used to read as a
-- present-but-different fingerprint and produce a bogus "update". The entry must
-- degrade to tag-only so it compares as "current" against a matching tag.
do
  local sentinel = setmetatable({}, {})  -- stand-in for cjson's null userdata
  local t = { c = { tag = "v2.6", asset_at = sentinel, size = sentinel, id = sentinel } }
  local e = about.installed_entry(t, "c")
  check("installed null asset_at -> nil", e.asset_at == nil)
  check("installed null size -> nil", e.size == nil)
  check("installed null id -> nil", e.id == nil)
  check("installed keeps tag", e.tag == "v2.6")
  check("installed null fingerprint compares current",
    about.compare_state(e, { tag = "v2.6", asset_at = "x", size = 1, id = 9 }) == "current")
end

-- ── fmt_asset ─────────────────────────────────────────────────────────────────
check("fmt_asset number", about.fmt_asset(248139923) == "#248139923")
check("fmt_asset string", about.fmt_asset("42") == "#42")
check("fmt_asset nil", about.fmt_asset(nil) == "")
check("fmt_asset empty string", about.fmt_asset("") == "")

-- ── parse_latest_info ─────────────────────────────────────────────────────────
do
  local body = '{"tag_name":"v2.6","assets":[' ..
    '{"name":"other.zip","created_at":"2026-01-01T00:00:00Z","size":1},' ..
    '{"name":"lumen-linux.zip","id":251004412,"created_at":"2026-06-21T03:15:25Z","size":2614842}]}'
  local info = about.parse_latest_info(body, "^lumen%-linux%.zip$")
  check("parse tag", info and info.tag == "v2.6")
  check("parse matched asset_at", info.asset_at == "2026-06-21T03:15:25Z")
  check("parse matched size", info.size == 2614842)
  check("parse matched id", info.id == 251004412)
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

-- ── update channel preferences ──────────────────────────────────────────────
local channels_ready = type(about.normalize_channels) == "function"
  and type(about.read_channels) == "function"
  and type(about.save_channels) == "function"
check("exports update channel persistence", channels_ready)
if channels_ready then
  local defaults = about.normalize_channels(nil)
  check("channels nil -> all stable", defaults.slsteam_moon == "stable"
    and defaults.plugin == "stable" and defaults.lumen == "stable")

  local mixed = about.normalize_channels({
    slsteam_moon = "beta", plugin = "preview", lumen = "beta",
  })
  check("channels collapse mixed preferences to global beta",
    mixed.slsteam_moon == "beta" and mixed.plugin == "beta"
      and mixed.lumen == "beta")

  local decoded = about.read_channels("x", reader_returning(
    '{"slsteam_moon":"stable","plugin":"beta","lumen":"beta"}'))
  check("channels migrate mixed JSON to global beta",
    decoded.slsteam_moon == "beta" and decoded.plugin == "beta"
      and decoded.lumen == "beta")
  local broken = about.read_channels("x", reader_returning("not json"))
  check("channels malformed JSON -> defaults", broken.slsteam_moon == "stable"
    and broken.plugin == "stable" and broken.lumen == "stable")
end

if channels_ready then
  local writes, renamed = {}, nil
  local ok = about.save_channels("/tmp/channels.json", {
    slsteam_moon = "stable", plugin = "stable", lumen = "beta",
  }, {
    write_file = function(path, body)
      writes[#writes + 1] = { path = path, body = body }
      return true
    end,
    rename = function(from, to) renamed = { from, to }; return true end,
  })
  check("channels save succeeds", ok == true)
  check("channels save writes temporary file", #writes == 1
    and writes[1].path ~= "/tmp/channels.json")
  local saved = json.decode(writes[1].body)
  check("channels save one preference for every component",
    saved.slsteam_moon == "beta" and saved.plugin == "beta"
      and saved.lumen == "beta")
  check("channels save atomically renames", renamed
    and renamed[1] == writes[1].path and renamed[2] == "/tmp/channels.json")
end

-- ── beta artifact metadata ──────────────────────────────────────────────────
local beta_ready = type(about.beta_api_url) == "function"
  and type(about.parse_beta_info) == "function"
  and type(about.fetch_beta_info) == "function"
check("exports beta artifact metadata", beta_ready)
if beta_ready then
  local function beta_http(status, body)
    return { get = function() return { status = status, body = body }, nil end }
  end
  local component = {
    repo = "swwayps/lumen", beta_path = "dist/lumen-linux.zip",
  }
  check("beta contents API URL", about.beta_api_url(component) ==
    "https://api.github.com/repos/swwayps/lumen/contents/dist/lumen-linux.zip?ref=beta")
  local info = about.parse_beta_info(
    '{"sha":"0123456789abcdef","size":2733136,' ..
    '"download_url":"https://raw.example/lumen-linux.zip"}')
  check("parse beta tag + channel", info and info.tag == "beta"
    and info.channel == "beta")
  check("parse beta fingerprint", info and info.id == "0123456789abcdef"
    and info.size == 2733136)
  check("parse beta download URL", info
    and info.download_url == "https://raw.example/lumen-linux.zip")
  check("parse beta rejects missing URL", about.parse_beta_info(
    '{"sha":"abc","size":1}') == nil)

  local fetched = about.fetch_beta_info(component, beta_http(200,
    '{"sha":"abc123","size":7,"download_url":"https://raw/x"}'))
  check("fetch beta artifact", fetched and fetched.id == "abc123")
  check("fetch beta missing branch", about.fetch_beta_info(component,
    beta_http(404, "{}")) == nil)
end

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
      or url:find("luatools-moon", 1, true) and "luatools-linux.zip"
      or "slsteam-moon-linux-2.6-lumen.zip"
    return '{"tag_name":"v2.6","assets":[{"name":"' .. name ..
      '","id":100,"created_at":"2026-06-21T03:15:25Z","size":100}]}'
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
  check("gv plugin shows latest asset id", by.plugin.latestAsset == "#100")
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

do
  -- Only Lumen publishes a beta artifact. A legacy mixed preference becomes
  -- global Beta, while components without a Beta artifact remain effectively
  -- Stable through the existing fallback.
  local function release_body(url)
    local name = url:find("/lumen/", 1, true) and "lumen-linux.zip"
      or url:find("luatools-moon", 1, true) and "luatools-linux.zip"
      or "slsteam-moon-linux-2.7-lumen.zip"
    return '{"tag_name":"v2.7","assets":[{"name":"' .. name ..
      '","id":700,"created_at":"2026-07-15T00:00:00Z","size":100}]} '
  end
  local http = { get = function(url)
    if url:find("/contents/", 1, true) then
      if url:find("/swwayps/lumen/", 1, true) then
        return { status = 200, body =
          '{"sha":"beta-lumen-sha","size":200,"download_url":"https://raw/beta"}' }
      end
      return { status = 404, body = "{}" }
    end
    return { status = 200, body = release_body(url) }
  end }
  local res = about.get_versions({
    http = http,
    versions_path = "/versions",
    channels_path = "/channels",
    read_file = function(path)
      if path == "/channels" then
        return '{"slsteam_moon":"beta","plugin":"stable","lumen":"beta"}'
      end
      return '{"lumen":{"tag":"v2.7","id":700,"channel":"stable"}}'
    end,
  })
  local by = {}
  for _, c in ipairs(res.components) do by[c.key] = c end
  check("gv exposes requested global channel", res.channel == "beta")
  check("gv beta available only for Lumen", by.lumen.betaAvailable == true
    and by.slsteam_moon.betaAvailable == false and by.plugin.betaAvailable == false)
  check("gv selected Lumen beta", by.lumen.channel == "beta"
    and by.lumen.latest == "beta" and by.lumen.latestAsset:find("beta%-lumen") ~= nil)
  check("gv stable fallback when selected beta unavailable",
    by.slsteam_moon.channel == "stable" and by.slsteam_moon.latest == "v2.7")
  check("gv stable install differs from selected beta", by.lumen.state == "update")
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
  check("script no flag by default", s:find("%-s %-%- ") == nil)
end


-- ── unified component channel flags ─────────────────────────────────────────
local flags_ready = type(about.channel_flags) == "function"
check("exports channel flags", flags_ready)
if flags_ready then
  local flags = about.channel_flags({
    slsteam_moon = "stable", plugin = "beta", lumen = "beta",
  }, false)
  check("channel flags use one global beta", table.concat(flags, " ") ==
    "--slsteam-channel beta --plugin-channel beta --lumen-channel beta")
  local np = about.channel_flags({
    slsteam_moon = "beta", plugin = "beta", lumen = "stable",
  }, true)
  check("noplugin keeps global beta", table.concat(np, " ") ==
    "--slsteam-channel beta --lumen-channel beta --noplugin")
  local script = about.update_script(about.INSTALL_URL, flags)
  check("update script forwards the global channel", script:find(
    "| bash %-s %-%- %-%-slsteam%-channel beta %-%-plugin%-channel beta %-%-lumen%-channel beta") ~= nil)
end

-- ── channel RPC registration ────────────────────────────────────────────────
do
  local registry, wrote = {}, nil
  about.register(registry, {
    channels_path = "/channels",
    read_file = function() return '{"lumen":"stable"}' end,
    channel_deps = {
      write_file = function(_, body) wrote = body; return true end,
      rename = function() return true end,
    },
  })
  check("register exposes SetAboutChannel", type(registry.SetAboutChannel) == "function")
  if type(registry.SetAboutChannel) == "function" then
    local good = json.decode(registry.SetAboutChannel('{"channel":"beta"}'))
    local saved = wrote and json.decode(wrote) or {}
    check("channel RPC saves global beta", good.success == true
      and saved.slsteam_moon == "beta" and saved.plugin == "beta"
      and saved.lumen == "beta")
    wrote = nil
    local stable = json.decode(registry.SetAboutChannel('{"channel":"stable"}'))
    saved = wrote and json.decode(wrote) or {}
    check("channel RPC saves global stable", stable.success == true
      and saved.slsteam_moon == "stable" and saved.plugin == "stable"
      and saved.lumen == "stable")
    local bad = json.decode(registry.SetAboutChannel(
      '{"channel":"preview"}'))
    check("channel RPC rejects unknown channel", bad.success == false)
  end
end

-- ── --noplugin behaviour ──────────────────────────────────────────────────────
do
  -- get_versions with include_plugin=false drops the LuaTools plugin row.
  local http = { get = function() return nil, "down" end }
  local res = about.get_versions({ http = http, include_plugin = false,
    read_file = reader_returning("{}") })
  check("noplugin: gv drops plugin", #res.components == 2)
  local by = {}
  for _, c in ipairs(res.components) do by[c.key] = c end
  check("noplugin: gv has no plugin key", by.plugin == nil)
  check("noplugin: gv keeps sls + lumen", by.slsteam_moon ~= nil and by.lumen ~= nil)
end
do
  -- include_plugin defaults true (standard install keeps all three).
  local http = { get = function() return nil, "down" end }
  local res = about.get_versions({ http = http, read_file = reader_returning("{}") })
  check("default: gv keeps all three", #res.components == 3)
end
do
  -- update_script forwards a flag after `bash -s --`.
  local s = about.update_script(about.INSTALL_URL, "--noplugin")
  check("flagged script runs bash -s -- --noplugin",
    s:find("| bash %-s %-%- %-%-noplugin") ~= nil)
end
do
  -- update_all forwards opts.flag into the written script.
  local wrote
  about.update_all({
    which = function() return true end,
    write_file = function(_, t) wrote = t; return true end,
    spawn = function() return true end,
    tmp_path = "/tmp/test-update-np.sh",
    flag = "--noplugin",
  })
  check("update_all writes flagged install", wrote
    and wrote:find("%-s %-%- %-%-noplugin") ~= nil)
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
