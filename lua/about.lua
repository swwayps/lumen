-- about: RPC layer for the Lumen settings menu's "About" tab.
--
-- Exposes two backend methods (registered into the CDP dispatch registry by
-- register()), each returning a JSON string per the callServerMethod convention
-- the polyfill resolves:
--   GetAboutVersions() -> {success, components=[{key,name,installed,latest,state}]}
--   UpdateAll()        -> {success[, error]}  (opens a terminal running install.sh)
--
-- Versions are sourced from the RELEASES, not local files: the plugin's bundled
-- version string is unreliable, so the canonical "installed" marker is the
-- release tag the installer stamps into versions.json at install time, compared
-- against each repo's latest published release tag (Codeberg Forgejo API). When
-- the stamp is absent (installs predating it) "installed" reads as unknown and
-- the tab still shows the latest + offers Update All.
--
-- The pure helpers (tag parse/normalize/compare, terminal detection, command
-- building) take their effects (http, fs, which) as injectable args so they are
-- host-testable without a network or a desktop (tools/test_about.lua).
local json = require("json")

local about = {}

-- The three stack components, in display order. `key` matches the versions.json
-- field the installer writes; `repo` is the Codeberg owner/name for the API;
-- `asset_pat` is a Lua pattern matching the release asset filename (so we can
-- read THAT asset's fingerprint, not just the tag).
about.COMPONENTS = {
  { key = "slsteam_moon", name = "slsteam-moon",    repo = "unplausible/slsteam-moon",
    asset_pat = "^slsteam%-moon%-linux%-.*%-lumen%.zip$" },
  { key = "plugin",       name = "LuaTools plugin", repo = "unplausible/slsteammoon-ltsteamplugin",
    asset_pat = "^luatools%-linux%.zip$" },
  { key = "lumen",        name = "Lumen",           repo = "unplausible/lumen",
    asset_pat = "^lumen%-linux%.zip$" },
}

-- The public one-liner the Update All button runs in a terminal. Raw-branch URL
-- (not a release asset) so installer fixes go live without a rebuild.
about.INSTALL_URL =
  "https://codeberg.org/unplausible/slsteammoon-ltsteamplugin/raw/branch/main/install.sh"

-- Where the installer stamps the installed release tags.
function about.versions_path()
  local home = os.getenv("HOME") or ""
  return home .. "/.local/share/Lumen/versions.json"
end

-- read_installed(path[, read_file]) -> table of key->tag (empty table on any
-- failure). `read_file` defaults to a plain io read so it's injectable in tests.
function about.read_installed(path, read_file)
  read_file = read_file or function(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
  end
  local raw = read_file(path)
  if not raw or raw == "" then return {} end
  local ok, data = pcall(json.decode, raw)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

-- installed_entry(installed, key) -> { tag, asset_at, size } for one component,
-- tolerating both the rich object shape the installer now writes
-- ({tag, asset_at, size}) and the legacy flat-string shape ("v2.6", tag only).
function about.installed_entry(installed, key)
  local v = installed and installed[key]
  if type(v) == "table" then
    return { tag = v.tag, asset_at = v.asset_at, size = v.size }
  elseif type(v) == "string" and v ~= "" then
    return { tag = v }  -- legacy: tag only, no asset fingerprint
  end
  return {}
end

-- Normalize a release tag for comparison: trim, drop a leading "v", lowercase.
-- "v2.5" and "2.5" compare equal; nil/"" -> nil.
function about.norm_tag(tag)
  if type(tag) ~= "string" then return nil end
  local t = tag:gsub("^%s+", ""):gsub("%s+$", "")
  if t == "" then return nil end
  t = t:gsub("^[vV]", "")
  return t:lower()
end

-- ISO timestamp ("2026-06-21T03:15:25+02:00") -> "dd/mm/yyyy". "" on nil/garbage.
-- A build date shown next to the tag so an asset-only update (same tag, newer
-- upload) reads clearly instead of looking like "v2.6 vs v2.6, why update?".
function about.fmt_date(iso)
  if type(iso) ~= "string" then return "" end
  local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then return "" end
  return d .. "/" .. m .. "/" .. y
end

-- compare_state(inst, latest) -> "current" | "update" | "unknown", where inst
-- and latest are { tag, asset_at, size } tables. An update is reported when
-- EITHER signal changed, so both release workflows are covered:
--   * tag bump (e.g. v2.6 -> v2.7)                                   -> update
--   * SAME tag, asset re-uploaded (different upload time/size)       -> update
-- When there's no asset fingerprint to compare (legacy tag-only stamp) it falls
-- back to a tag comparison. No latest, or no installed identity at all -> unknown.
function about.compare_state(inst, latest)
  inst = inst or {}
  latest = latest or {}
  local lt = about.norm_tag(latest.tag)
  if not lt then return "unknown" end
  local it = about.norm_tag(inst.tag)
  -- No installed identity (neither tag nor asset) -> can't tell.
  if not it and not inst.asset_at then return "unknown" end
  -- 1) Tag changed -> update (caught even if we can't compare assets).
  if it and it ~= lt then return "update" end
  -- 2) Same (or unknown) tag: compare the asset fingerprint so a re-upload under
  --    the same tag is still detected.
  if inst.asset_at and latest.asset_at then
    if inst.asset_at ~= latest.asset_at
        or tostring(inst.size or "") ~= tostring(latest.size or "") then
      return "update"
    end
    return "current"
  end
  -- 3) No asset fingerprint to compare (legacy stamp): tags match -> current.
  if it and it == lt then return "current" end
  return "unknown"
end

-- API URL for a repo's latest published (non-draft, non-prerelease) release.
function about.api_url(repo)
  return "https://codeberg.org/api/v1/repos/" .. repo .. "/releases/latest"
end

-- parse_latest_info(body, asset_pat) -> { tag, asset_at, size } or nil. Pure
-- (decode only). Finds the asset whose name matches `asset_pat` and returns its
-- upload fingerprint alongside the release tag.
function about.parse_latest_info(body, asset_pat)
  if type(body) ~= "string" or body == "" then return nil end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" then return nil end
  local tag = data.tag_name
  if type(tag) ~= "string" or tag == "" then return nil end
  local info = { tag = tag }
  local assets = data.assets
  if type(assets) == "table" then
    for _, a in ipairs(assets) do
      if type(a) == "table" and type(a.name) == "string"
          and a.name:match(asset_pat) then
        info.asset_at = a.created_at
        info.size = a.size
        break
      end
    end
  end
  return info
end

-- fetch_latest_info(component, http_mod) -> { tag, asset_at, size } or nil.
-- Short timeout so a slow/down forge doesn't stall the injector loop.
function about.fetch_latest_info(component, http_mod)
  local r, _ = http_mod.get(about.api_url(component.repo), {
    timeout = 6,
    headers = { ["Accept"] = "application/json", ["User-Agent"] = "lumen" },
  })
  if not r or r.status ~= 200 then return nil end
  return about.parse_latest_info(r.body, component.asset_pat)
end

-- get_versions(opts) -> table {success=true, components={...}}. opts (all
-- optional, injectable for tests):
--   http        : http module (defaults to require("http"))
--   read_file   : reader for the versions stamp
--   versions_path : override the stamp path
function about.get_versions(opts)
  opts = opts or {}
  local http_mod = opts.http or require("http")
  local installed = about.read_installed(
    opts.versions_path or about.versions_path(), opts.read_file)

  local out = {}
  for _, c in ipairs(about.COMPONENTS) do
    local inst = about.installed_entry(installed, c.key)
    local latest = about.fetch_latest_info(c, http_mod)
    out[#out + 1] = {
      key = c.key,
      name = c.name,
      installed = inst.tag or "",
      latest = (latest and latest.tag) or "",
      installedBuild = about.fmt_date(inst.asset_at),
      latestBuild = about.fmt_date(latest and latest.asset_at),
      state = about.compare_state(inst, latest),
    }
  end
  return { success = true, components = out }
end

-- ── Update All: open the user's terminal running the installer ──────────────

-- Known terminal emulators, in preference order, with how each runs a program:
--   dashe    : <bin> -e bash <script>      (xterm, konsole, x-terminal-emulator)
--   dashdash : <bin> -- bash <script>      (gnome-terminal, ptyxis)
--   x        : <bin> -x bash <script>      (xfce4-terminal: -x = exec the rest)
--   direct   : <bin> bash <script>         (kitty)
about.TERMINALS = {
  { bin = "x-terminal-emulator", mode = "dashe" },
  { bin = "gnome-terminal",      mode = "dashdash" },
  { bin = "ptyxis",              mode = "dashdash" },
  { bin = "konsole",             mode = "dashe" },
  { bin = "xfce4-terminal",      mode = "x" },
  { bin = "kitty",               mode = "direct" },
  { bin = "alacritty",           mode = "dashe" },
  { bin = "xterm",               mode = "dashe" },
}

-- detect_terminal(which) -> { bin=, mode= } or nil. `which(bin)` returns true if
-- the binary is on PATH; injectable so tests don't depend on the host.
function about.detect_terminal(which)
  for _, t in ipairs(about.TERMINALS) do
    if which(t.bin) then return t end
  end
  return nil
end

-- launch_argv(term, script) -> array of argv tokens to run `bash <script>` in
-- the given terminal. Pure; the caller quotes/spawns.
function about.launch_argv(term, script)
  if term.mode == "dashe" then
    return { term.bin, "-e", "bash", script }
  elseif term.mode == "dashdash" then
    return { term.bin, "--", "bash", script }
  elseif term.mode == "x" then
    return { term.bin, "-x", "bash", script }
  else -- direct
    return { term.bin, "bash", script }
  end
end

-- Single-quote a token for safe POSIX-shell interpolation.
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- The bash script the terminal runs: the installer one-liner, then a pause so
-- the window stays open for the user to read the result. No user-controlled
-- input is interpolated (the URL is a constant), so this is injection-safe.
function about.update_script(install_url)
  return table.concat({
    "#!/usr/bin/env bash",
    "set -u",
    'echo "Updating slsteam-moon / Lumen / LuaTools…"',
    "echo",
    "curl -fsSL " .. shq(install_url) .. " | bash",
    "status=$?",
    "echo",
    'if [ "$status" -eq 0 ]; then',
    '  echo "Done. Restart Steam to apply the updates."',
    "else",
    '  echo "Update exited with status $status."',
    "fi",
    'read -rp "Press Enter to close this window…" _',
    "",
  }, "\n")
end

-- build_command(argv) -> a detached shell command string (setsid+nohup, output
-- discarded, backgrounded) that survives the caller. argv tokens are quoted.
function about.build_command(argv)
  local parts = {}
  for _, tok in ipairs(argv) do parts[#parts + 1] = shq(tok) end
  return "setsid nohup " .. table.concat(parts, " ") .. " >/dev/null 2>&1 &"
end

-- update_all(opts) -> table {success[, error]}. opts (injectable for tests):
--   which      : PATH probe (defaults to `command -v`)
--   write_file : write the temp script (defaults to io)
--   spawn      : run the detached command (defaults to os.execute)
--   tmp_path   : override the temp script path
function about.update_all(opts)
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
      error = "No terminal emulator found. Run the installer manually: "
        .. "curl -fsSL " .. about.INSTALL_URL .. " | bash",
    }
  end

  local script = opts.tmp_path or ("/tmp/lumen-update-" .. tostring(os.time()) .. ".sh")
  if not write_file(script, about.update_script(about.INSTALL_URL)) then
    return { success = false, error = "Could not write the update script." }
  end

  local argv = about.launch_argv(term, script)
  spawn(about.build_command(argv))
  return { success = true, terminal = term.bin }
end

-- register(registry): install GetAboutVersions / UpdateAll, wrapping the
-- table-returning core in JSON encoding (the dispatch contract).
function about.register(registry)
  registry.GetAboutVersions = function() return json.encode(about.get_versions()) end
  registry.UpdateAll = function() return json.encode(about.update_all()) end
  return registry
end

return about
