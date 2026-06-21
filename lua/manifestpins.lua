-- manifestpins: backend for the Lumen settings menu's "Game Updates" tab
-- (game-updates-pinning design §5).
--
-- Assembles the per-game version tree from on-disk data ONLY (no PICS / binary
-- product-info parsing) and reads/writes the `ManifestPins:` map in
-- slsteam-moon's ~/.config/SLSsteam/config.yaml:
--   * LuaTools .lua  (~/.steam/steam/config/stplug-in/<appid>.lua) -> depots,
--     per-depot key, the commented setManifestid gid ("from LuaTools"), and the
--     child/DLC appids.
--   * archived manifests (~/.config/SLSsteam/manifests/<depot>_<gid>.manifest)
--     -> the selectable versions; build date from the manifest's
--     ContentManifestMetadata.creation_time (protobuf field 3, varint).
--   * appmanifest_<appid>.acf -> the currently-installed gid per depot.
-- Names/images are resolved in the FRONTEND via the Steam store APIs; the
-- backend never needs app names.
--
-- The pure pieces (creation_time parse, .lua parse, config parse/emit/splice,
-- as-of-date selection, pin-model mutations) are split from IO so they are
-- host-testable (tools/test_manifestpins.lua). gids are uint64 -> kept as
-- STRINGS everywhere (config + JSON) to avoid precision loss.
local json = require("json")

local mp = {}

-- ── Steam library folders ────────────────────────────────────────────────
-- A Steam install can span several library folders (e.g. a second drive). The
-- appmanifest_<appid>.acf for a game lives in the steamapps/ of whichever
-- library it's installed on — not necessarily the primary root. parse the
-- "path" entries from libraryfolders.vdf so installed/workshop lookups search
-- every library. Pure parser, IO done by library_roots.
function mp.parse_library_paths(text)
  local paths = {}
  for p in (text or ""):gmatch('"path"%s*"([^"]+)"') do
    paths[#paths + 1] = (p:gsub("\\\\", "/"))
  end
  return paths
end

-- ── manifest creation_time ──────────────────────────────────────────────────
-- ContentManifestMetadata magic 0x1F4812BE, stored little-endian -> bytes
-- BE 12 48 1F, followed by a uint32 LE length and that many protobuf bytes.
-- The metadata block sits near EOF (after the big payload), so the LAST
-- occurrence of the magic in `bytes` is the one we want.
local META_MAGIC = "\xBE\x12\x48\x1F"

local function read_varint(s, pos)
  local shift, val = 0, 0
  while pos <= #s do
    local b = string.byte(s, pos)
    pos = pos + 1
    val = val | ((b & 0x7f) << shift)
    if (b & 0x80) == 0 then return val, pos end
    shift = shift + 7
  end
  return nil, pos
end

-- creation_time_from_bytes(bytes) -> unix int, or nil if the magic / field 3
-- can't be found. `bytes` may be the whole manifest or just its tail.
function mp.creation_time_from_bytes(bytes)
  if type(bytes) ~= "string" then return nil end
  -- find the last magic occurrence
  local idx
  local from = 1
  while true do
    local i = bytes:find(META_MAGIC, from, true)
    if not i then break end
    idx = i; from = i + 1
  end
  if not idx then return nil end
  local lenpos = idx + 4
  if lenpos + 3 > #bytes then return nil end
  local len = string.unpack("<I4", bytes, lenpos)
  local pbstart = lenpos + 4
  local pbend = math.min(pbstart + len - 1, #bytes)

  local pos = pbstart
  while pos <= pbend do
    local tag; tag, pos = read_varint(bytes, pos)
    if not tag then break end
    local field = tag >> 3
    local wire = tag & 7
    if field == 3 and wire == 0 then
      local v = read_varint(bytes, pos)
      return v
    elseif wire == 0 then
      _, pos = read_varint(bytes, pos)
    elseif wire == 2 then
      local l; l, pos = read_varint(bytes, pos)
      pos = pos + (l or 0)
    elseif wire == 5 then
      pos = pos + 4
    elseif wire == 1 then
      pos = pos + 8
    else
      break
    end
  end
  return nil
end

-- ── LuaTools .lua parse ──────────────────────────────────────────────────────
-- parse_lua(text) -> { base=<appid|nil>, depots={ [id]={key=, manifestid=} },
--                      dlc_appids={ <id>, ... } }
-- Rules (verified against a real LuaTools file):
--   * addappid(id, type, "key")  -> a keyed depot.
--   * addappid(id)               -> a bare appid; the FIRST is the base app,
--                                   the rest (minus base) are DLC/child appids.
--   * setManifestid(depot,"gid") -> the LuaTools-shipped gid for that depot.
function mp.parse_lua(text)
  local out = { base = nil, depots = {}, dlc_appids = {} }
  local bare = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    -- keyed depot: addappid(id, type, "key")
    local kid, kkey = line:match('addappid%s*%(%s*(%d+)%s*,%s*%d+%s*,%s*"([^"]*)"%s*%)')
    if kid then
      kid = math.tointeger(tonumber(kid))
      out.depots[kid] = out.depots[kid] or {}
      out.depots[kid].key = kkey
    else
      -- bare appid: addappid(id)   (no comma)
      local bid = line:match('addappid%s*%(%s*(%d+)%s*%)')
      if bid then bare[#bare + 1] = math.tointeger(tonumber(bid)) end
    end
    -- manifest id (may be commented with a leading --)
    local mdepot, mgid = line:match('setManifestid%s*%(%s*(%d+)%s*,%s*"([^"]*)"')
    if mdepot then
      mdepot = math.tointeger(tonumber(mdepot))
      out.depots[mdepot] = out.depots[mdepot] or {}
      out.depots[mdepot].manifestid = mgid
    end
  end
  if bare[1] then out.base = bare[1] end
  for i = 2, #bare do
    if bare[i] ~= out.base then out.dlc_appids[#out.dlc_appids + 1] = bare[i] end
  end
  return out
end

-- ── ManifestPins config parse / emit / splice ────────────────────────────────
-- parse_pins(text) -> { [appid]={ locked=bool, depots={ [depot]="gid" } } }
function mp.parse_pins(text)
  local pins = {}
  text = text or ""
  local in_block = false
  local cur_app, in_depots
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    if raw:match("^ManifestPins%s*:") then
      in_block = true; cur_app = nil; in_depots = false
    elseif in_block and raw:match("^%S") then
      -- next top-level key ends the block
      in_block = false
    elseif in_block then
      local app = raw:match("^  (%d+)%s*:%s*$")
      if app then
        cur_app = math.tointeger(tonumber(app))
        pins[cur_app] = { locked = false, depots = {} }
        in_depots = false
      elseif cur_app then
        local lock = raw:match("^    locked%s*:%s*(%a+)")
        if lock then
          pins[cur_app].locked = (lock:lower() == "true" or lock:lower() == "yes")
        elseif raw:match("^    depots%s*:%s*$") then
          in_depots = true
        elseif in_depots then
          local depot, gid = raw:match('^      (%d+)%s*:%s*"?([%d]+)"?%s*$')
          if depot then
            pins[cur_app].depots[math.tointeger(tonumber(depot))] = gid
          end
        end
      end
    end
  end
  return pins
end

local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

-- emit_pins(pins) -> YAML text for the ManifestPins block ("" if no apps).
function mp.emit_pins(pins)
  local apps = sorted_keys(pins)
  if #apps == 0 then return "" end
  local lines = { "ManifestPins:" }
  for _, app in ipairs(apps) do
    local a = pins[app]
    lines[#lines + 1] = "  " .. app .. ":"
    lines[#lines + 1] = "    locked: " .. (a.locked and "true" or "false")
    local depots = sorted_keys(a.depots or {})
    if #depots > 0 then
      lines[#lines + 1] = "    depots:"
      for _, d in ipairs(depots) do
        lines[#lines + 1] = "      " .. d .. ': "' .. tostring(a.depots[d]) .. '"'
      end
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

-- splice_pins(text, pins) -> text with the ManifestPins block replaced by the
-- freshly-emitted one (inserted at EOF if absent, removed if `pins` is empty).
-- Every other line/comment is preserved.
function mp.splice_pins(text, pins)
  text = text or ""
  local had_trailing_nl = (#text > 0 and text:sub(-1) == "\n")
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  if had_trailing_nl then lines[#lines] = nil end

  -- locate the existing block [first, last]
  local first, last
  for i, line in ipairs(lines) do
    if line:match("^ManifestPins%s*:") then
      first = i
      last = #lines
      for j = i + 1, #lines do
        if lines[j]:match("^%S") then last = j - 1; break end
      end
      break
    end
  end

  local block = mp.emit_pins(pins)
  local block_lines = {}
  if block ~= "" then
    for l in (block):gmatch("([^\n]*)\n") do block_lines[#block_lines + 1] = l end
  end

  local out = {}
  if first then
    for i = 1, first - 1 do out[#out + 1] = lines[i] end
    for _, l in ipairs(block_lines) do out[#out + 1] = l end
    for i = last + 1, #lines do out[#out + 1] = lines[i] end
  else
    for _, l in ipairs(lines) do out[#out + 1] = l end
    for _, l in ipairs(block_lines) do out[#out + 1] = l end
  end

  local body = table.concat(out, "\n")
  if #out > 0 then body = body .. "\n" end
  return body
end

-- add_additional_app(text, appid) -> new_text, status. Registers `appid` in the
-- AdditionalApps block-list (the id SLSsteam reads to treat a game as managed —
-- see slsteam.lua). Pure text transform so ImportLuaFull can fold it into the
-- SAME atomic write as the pin (no second racing write to config.yaml).
-- status: "added" | "already_present" | "inline_refused" (won't rewrite the
-- inline "[a, b]" form). Mirrors the plugin's register_app block editing.
function mp.add_additional_app(text, appid)
  appid = math.tointeger(tonumber(appid))
  text = text or ""
  if not appid then return text, "bad_appid" end

  local had_trailing_nl = (#text > 0 and text:sub(-1) == "\n")
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  if had_trailing_nl then lines[#lines] = nil end

  local header_idx
  for i, line in ipairs(lines) do
    if line:match("^AdditionalApps%s*:") then header_idx = i; break end
  end

  if header_idx then
    -- value after the colon (ignoring a trailing comment) => inline form
    local after = lines[header_idx]:match("^AdditionalApps%s*:%s*(.-)%s*$") or ""
    if after:gsub("#.*$", ""):gsub("%s+$", "") ~= "" then return text, "inline_refused" end
  else
    if #lines > 0 and lines[#lines] ~= "" then lines[#lines + 1] = "" end
    lines[#lines + 1] = "AdditionalApps:"
    header_idx = #lines
  end

  local last_entry_idx, indent = header_idx, "  "
  for i = header_idx + 1, #lines do
    local stripped = lines[i]:gsub("^%s+", "")
    if stripped == "" or stripped:match("^#") then
      -- comment/blank: belongs to whatever follows; skip
    else
      local entry_indent, rest = lines[i]:match("^(%s+)%-%s+(.*)$")
      if not entry_indent then break end  -- next top-level key ends the block
      indent = entry_indent
      last_entry_idx = i
      local id = math.tointeger(tonumber((rest:gsub("#.*$", ""):gsub("%s+$", ""))))
      if id == appid then return text, "already_present" end
    end
  end

  table.insert(lines, last_entry_idx + 1, indent .. "- " .. tostring(appid))
  local body = table.concat(lines, "\n")
  if #lines > 0 then body = body .. "\n" end
  return body, "added"
end

-- ── shared-runtime depot detection ───────────────────────────────────────
-- Steamworks Common Redistributables (app 228980) ship as shared depots with
-- FIXED ids reused by every game (DirectX, VC++, .NET, ...). They carry ancient
-- manifest dates and aren't part of the game, so the UI labels them as shared
-- instead of showing a bare id + a confusing old date.
local SHARED_DEPOTS = {}
for _, id in ipairs({
  228981, 228982, 228983, 228984, 228985, 228986, 228987, 228988, 228989, 228990,
  229000, 229001, 229002, 229003, 229004, 229005, 229006, 229007,
  229010, 229011, 229012, 229020, 229030, 229031, 229032, 229033,
}) do SHARED_DEPOTS[id] = true end

function mp.is_shared_depot(depot)
  return SHARED_DEPOTS[depot] == true
end

-- ── Steam tools / runtimes / redistributables (NOT games) ─────────────────
-- Steam ships many non-game "apps": Linux runtimes, Proton builds, anti-cheat
-- runtimes, Source SDK bases, the Steamworks Common Redistributables (app +
-- per-component depots), and internal platform files. They can carry a stplug
-- .lua + archived manifests, but they're not games — showing them as cards in
-- the Game Updates list is noise. This map gives each a friendly name (used to
-- label a depot row) and doubles as the "is this a tool, not a game?" set used
-- to drop them from the main list. Source: steam_tools_appids.txt (verified via
-- the Valve Developer wiki + SteamDB).
local STEAM_TOOL_NAMES = {
  -- Steam Linux runtimes
  [1070560] = "Steam Linux Runtime 1.0 (scout)",
  [1391110] = "Steam Linux Runtime 2.0 (soldier)",
  [1628350] = "Steam Linux Runtime 3.0 (sniper)",
  [4183110] = "Steam Linux Runtime 4.0 (steamrt4)",
  [4690330] = "Legacy Steam Runtime (scout)",
  -- Proton
  [1493710] = "Proton Experimental",
  [2180100] = "Proton Hotfix",
  [2230260] = "Proton Next",
  [4628710] = "Proton 11.0 (Beta)",
  [4628740] = "Proton 11.0 (ARM64) (Beta)",
  [3658110] = "Proton 10.0 (Beta)",
  [2805730] = "Proton 9.0 (Beta)",
  [2348590] = "Proton 8.0",
  [1887720] = "Proton 7.0",
  [1580130] = "Proton 6.3",
  [1420170] = "Proton 5.13",
  [1245040] = "Proton 5.0",
  [1113280] = "Proton 4.11",
  [1054830] = "Proton 4.2",
  [996510]  = "Proton 3.16 Beta",
  [961940]  = "Proton 3.16",
  [930400]  = "Proton 3.7 Beta",
  [858280]  = "Proton 3.7",
  -- Anti-cheat runtimes
  [1161040] = "Proton BattlEye Runtime",
  [1826330] = "Proton EasyAntiCheat Runtime",
  -- Source SDK bases / authoring tools
  [215]     = "Source SDK Base 2006",
  [218]     = "Source SDK Base 2007",
  [243730]  = "Source SDK Base 2013 - Singleplayer",
  [243750]  = "Source SDK Base 2013 - Multiplayer",
  [201890]  = "Nuclear Dawn Authoring Tools",
  -- Sound / media
  [3086180] = "Proton Voice Files",
  [910]     = "Steam Media Player",
  -- Steamworks Common Redistributables (app + per-component depots)
  [228980]  = "Steamworks Common Redistributables",
  [228981]  = "Steamworks Common Redistributable (Config)",
  [228988]  = "Windows VC 2019 Redist",
  [228989]  = "Windows VC 2022 Redist",
  [228990]  = "Windows DirectX Jun 2010 Redist",
  [229000]  = "Windows .NET 3.5 Redist",
  [229001]  = "Windows .NET 3.5 Client Profile Redist",
  [229002]  = "Windows .NET 4.0 Redist",
  [229003]  = "Windows .NET 4.0 Client Profile Redist",
  [229004]  = "Windows .NET 4.5.2 Redist",
  [229005]  = "Windows .NET 4.6 Redist",
  [229006]  = "Windows .NET 4.7 Redist",
  [229007]  = "Windows .NET 4.8 Redist",
  [229010]  = "Windows XNA 3.0 Redist",
  [229011]  = "Windows XNA 3.1 Redist",
  [229012]  = "Windows XNA 4.0 Redist",
  [229020]  = "Windows OpenAL 2.0.7.0 Redist",
  [229030]  = "Windows PhysX System Software 8.09.04",
  [229031]  = "Windows PhysX System Software 9.12.1031",
  [229032]  = "Windows PhysX System Software 9.13.1220",
  [229033]  = "Windows PhysX System Software 9.14.0702",
  -- Other Valve tools / platform files
  [891390]  = "SteamPlay 2.0 Manifests",
  [480]     = "Spacewar / SteamworksExample",
  [250820]  = "SteamVR",
  [221410]  = "Steam for Linux",
  [3]       = "Original Platform (Steam base)",
  [7]       = "Steam WinUI",
  [8]       = "Steam WinUI2",
}

-- tool_name(id) -> friendly name string, or nil if `id` isn't a known tool.
function mp.tool_name(id)
  return STEAM_TOOL_NAMES[math.tointeger(tonumber(id)) or -1]
end

-- is_tool(id) -> true when `id` is a Steam tool/runtime/redistributable, i.e.
-- NOT a real game; such apps are dropped from the main Game Updates list.
function mp.is_tool(id)
  return mp.tool_name(id) ~= nil
end

-- ── workshop-depot detection ─────────────────────────────────────────────
-- Steam's Workshop content depot has id == appid and lives under
-- steamapps/workshop/content/<appid>, separate from the game's content depots
-- (which are listed in appmanifest InstalledDepots). Its archived manifests are
-- workshop snapshots, NOT game builds, so the frontend hides them from a game's
-- version timeline. Pure decision; the workshop-presence check is done via IO.
function mp.is_workshop_depot(appid, depot, app_has_workshop)
  return depot == appid and app_has_workshop == true
end

-- ── as-of-date selection ──────────────────────────────────────────────────
-- end_of_day(ts) -> the last second (23:59:59 UTC) of the calendar day holding
-- ts. A game-level pin targets a DAY (the build timeline shows one row per
-- day), so the cutoff must include every depot's build from that day — sibling
-- depots of the same release are commonly packaged seconds/minutes apart, and a
-- raw exact-timestamp cutoff would drop the ones built just after the base depot.
function mp.end_of_day(ts)
  ts = math.floor(tonumber(ts) or 0)
  return ts - (ts % 86400) + 86399
end

-- select_as_of(versions_by_depot, T) -> { [depot]="gid" } picking, per depot,
-- the newest archived gid whose date <= T. Depots with nothing <= T are omitted.
function mp.select_as_of(versions_by_depot, T)
  local sel = {}
  for depot, versions in pairs(versions_by_depot) do
    local best_gid, best_date
    for _, v in ipairs(versions) do
      if v.date and v.date <= T and (not best_date or v.date > best_date) then
        best_date = v.date; best_gid = v.gid
      end
    end
    if best_gid then sel[depot] = best_gid end
  end
  return sel
end

-- ── pin-model mutations (pure; operate on a parsed pinmap) ──────────────────
function mp.set_game_pin(pins, appid, depot_gids)
  local depots = {}
  for d, g in pairs(depot_gids) do depots[d] = tostring(g) end
  pins[appid] = { locked = true, depots = depots }
end

function mp.set_dlc_pin(pins, appid, depot, gid)
  pins[appid] = pins[appid] or { locked = false, depots = {} }
  pins[appid].depots[depot] = tostring(gid)
end

function mp.clear_game_pin(pins, appid)
  pins[appid] = nil
end

function mp.clear_dlc_pin(pins, appid, depot)
  local a = pins[appid]
  if not a then return end
  if a.depots then a.depots[depot] = nil end
  -- drop the app entry entirely if nothing pins it anymore
  if not a.locked and (not a.depots or next(a.depots) == nil) then
    pins[appid] = nil
  end
end

-- drop_installed_depot(acf_text, depot) -> new_text, removed_bool. Removes the
-- "<depot>" { ... } entry from an appmanifest's InstalledDepots block so Steam
-- replans a FRESH install of that depot at the pinned gid (Approach A). Pure,
-- brace-balanced VDF edit; no-op (text unchanged, false) when the depot isn't
-- listed. The id is matched quoted so a shorter id can't match a longer one.
-- Callers must only apply this with Steam closed (editing a live .acf is racy).
function mp.drop_installed_depot(acf_text, depot)
  acf_text = acf_text or ""
  local d = math.tointeger(tonumber(depot))
  if not d then return acf_text, false end
  local blk = acf_text:match('"InstalledDepots"%s*(%b{})')
  if not blk then return acf_text, false end
  local s, e = blk:find('%s*"' .. d .. '"%s*%b{}')
  if not s then return acf_text, false end
  local new_blk = blk:sub(1, s - 1) .. blk:sub(e + 1)
  local i = acf_text:find(blk, 1, true)
  if not i then return acf_text, false end
  return acf_text:sub(1, i - 1) .. new_blk .. acf_text:sub(i + #blk), true
end

-- ── IO layer ────────────────────────────────────────────────────────────────
local function home() return os.getenv("HOME") or "" end

local function steam_root_guess()
  local h = home()
  if h == "" then return nil end
  local candidates = {
    h .. "/.steam/steam",
    h .. "/.steam/debian-installation",
    h .. "/.local/share/Steam",
  }
  for _, c in ipairs(candidates) do
    local f = io.open(c .. "/steam.sh", "rb")
    if f then f:close(); return c end
  end
  return h .. "/.steam/steam"
end

-- default_ctx() -> resolved paths for the real install.
function mp.default_ctx()
  local h = home()
  local root = steam_root_guess()
  return {
    config_path = (h ~= "" and (h .. "/.config/SLSsteam/config.yaml")) or nil,
    stplug_dir = root and (root .. "/config/stplug-in") or nil,
    manifests_dir = (h ~= "" and (h .. "/.config/SLSsteam/manifests")) or nil,
    cache_dir = (h ~= "" and (h .. "/.config/SLSsteam/cache")) or nil,
    steam_root = root,
  }
end

-- invalidate_appinfo_cache(ctx, appid): drop the provisioned appinfo buffers for
-- an app (<cache>/picsbuffer_<appid>.{bin,yaml}) so SLSsteam re-renders them with
-- the CURRENT pins on its next start. Without this, a pin set after the buffer
-- was last rendered leaves a stale public gid in appinfo, which loops the build
-- reconcile. Safe no-op on a nil appid or when
-- the ctx carries no cache_dir (host tests that don't exercise it).
function mp.invalidate_appinfo_cache(ctx, appid)
  ctx = ctx or {}
  local dir = ctx.cache_dir
  local id = math.tointeger(tonumber(appid))
  if not dir or not id then return end
  for _, ext in ipairs({ "bin", "yaml" }) do
    os.remove(dir .. "/picsbuffer_" .. id .. "." .. ext)
  end
end

local function read_file(path)
  if not path then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a"); f:close()
  return d
end

-- All Steam library roots: the primary steam_root plus every "path" listed in
-- its libraryfolders.vdf (deduped, primary first). Games on a second drive
-- have their appmanifest there, not under the primary root.
local function library_roots(steam_root)
  local roots, seen = {}, {}
  local function add(r) if r and r ~= "" and not seen[r] then seen[r] = true; roots[#roots + 1] = r end end
  add(steam_root)
  if steam_root then
    for _, vdf in ipairs({ steam_root .. "/steamapps/libraryfolders.vdf",
                           steam_root .. "/config/libraryfolders.vdf" }) do
      local t = read_file(vdf)
      if t then
        for _, p in ipairs(mp.parse_library_paths(t)) do add(p) end
        break
      end
    end
  end
  return roots
end

-- Count ManifestPins-irrelevant known keys so we never clobber a config we
-- failed to read (mirror slsconfig's no-clobber guard).
local function looks_like_config(text)
  if not text or text == "" then return false end
  local n = 0
  for _, k in ipairs({ "AdditionalApps", "LogLevel", "DisableCloud",
                       "PlayNotOwnedGames", "ManifestPins" }) do
    if ("\n" .. text):find("\n" .. k .. "%s*:") then n = n + 1 end
  end
  return n >= 1
end

local write_seq = 0
math.randomseed((os.time() % 100000) * 1000 + math.floor((os.clock() * 1e6) % 1000))

-- write_pins(config_path, pins) -> ok, err. Splices the ManifestPins block into
-- the existing config via an atomic temp-file rename (one inotify event).
local function write_pins(config_path, pins)
  if not config_path then return false, "no path" end
  local data = read_file(config_path)
  if not data then return false, "config.yaml not found" end
  if not looks_like_config(data) then
    return false, "config does not look valid; refusing to write"
  end
  local out = mp.splice_pins(data, pins)
  local tmp = string.format("%s.tmp.lumen.%d.%d.%d", config_path,
    os.time(), write_seq, math.random(100000, 999999))
  write_seq = write_seq + 1
  local w, werr = io.open(tmp, "wb")
  if not w then return false, werr or "open failed" end
  w:write(out); w:close()
  local ok, rerr = os.rename(tmp, config_path)
  if not ok then os.remove(tmp); return false, rerr or "rename failed" end
  return true
end

-- write_config_raw(config_path, text) -> ok, err. Atomic write of a full config
-- body (ImportLuaFull edits AdditionalApps + pins together). Same no-clobber
-- guard + temp-rename as write_pins.
local function write_config_raw(config_path, text)
  if not config_path then return false, "no path" end
  if not looks_like_config(text) then
    return false, "config does not look valid; refusing to write"
  end
  local tmp = string.format("%s.tmp.lumen.%d.%d.%d", config_path,
    os.time(), write_seq, math.random(100000, 999999))
  write_seq = write_seq + 1
  local w, werr = io.open(tmp, "wb")
  if not w then return false, werr or "open failed" end
  w:write(text); w:close()
  local ok, rerr = os.rename(tmp, config_path)
  if not ok then os.remove(tmp); return false, rerr or "rename failed" end
  return true
end

-- write_lua_file(stplug_dir, appid, text) -> ok, err. Atomic write of the
-- LuaTools <appid>.lua (the depot keys SLSsteam needs) into config/stplug-in.
local function write_lua_file(stplug_dir, appid, text)
  if not stplug_dir then return false, "no stplug-in dir" end
  os.execute("mkdir -p '" .. stplug_dir .. "' 2>/dev/null")
  local path = stplug_dir .. "/" .. tostring(appid) .. ".lua"
  local tmp = string.format("%s.tmp.lumen.%d.%d", path, os.time(), math.random(100000, 999999))
  local w, werr = io.open(tmp, "wb")
  if not w then return false, werr or "open failed" end
  w:write(text); w:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then os.remove(tmp); return false, rerr or "rename failed" end
  return true
end

-- Currently-installed gid per depot for an app, from appmanifest_<appid>.acf.
-- Searches every Steam library folder (the game may be on a second drive).
local function installed_gids(steam_root, appid)
  local out = {}
  local acf
  for _, root in ipairs(library_roots(steam_root)) do
    acf = read_file(root .. "/steamapps/appmanifest_" .. appid .. ".acf")
    if acf then break end
  end
  if not acf then return out end
  -- find the InstalledDepots block, then each "depot" { ... "manifest" "gid" }
  local block = acf:match('"InstalledDepots"%s*(%b{})')
  if not block then return out end
  for depot, body in block:gmatch('"(%d+)"%s*(%b{})') do
    local gid = body:match('"manifest"%s*"(%d+)"')
    if gid then out[math.tointeger(tonumber(depot))] = gid end
  end
  return out
end

-- Does this app have Workshop content on disk? Presence of the app's
-- appworkshop_<appid>.acf (in any library's steamapps/workshop) is the signal.
local function app_has_workshop(steam_root, appid)
  for _, root in ipairs(library_roots(steam_root)) do
    local f = io.open(root .. "/steamapps/workshop/appworkshop_" .. appid .. ".acf", "rb")
    if f then f:close(); return true end
  end
  return false
end

-- Archived versions for a depot: scan manifests_dir for <depot>_<gid>.manifest.
local function archived_versions(manifests_dir, depot)
  local versions = {}
  if not manifests_dir then return versions end
  -- list dir via lfs if available, else a shell fallback (host tests have lfs).
  local names = {}
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs then
    for entry in lfs.dir(manifests_dir) do names[#names + 1] = entry end
  else
    local p = io.popen("ls -1 '" .. manifests_dir .. "' 2>/dev/null")
    if p then for line in p:lines() do names[#names + 1] = line end; p:close() end
  end
  local prefix = depot .. "_"
  for _, name in ipairs(names) do
    local gid = name:match("^" .. depot .. "_(%d+)%.manifest$")
    if gid then
      local bytes = read_file(manifests_dir .. "/" .. name)
      local ct = bytes and mp.creation_time_from_bytes(bytes) or nil
      versions[#versions + 1] = { gid = gid, date = ct or 0, size = bytes and #bytes or 0 }
    end
  end
  return versions
end

-- build_games(ctx) -> array of games (design §5 GetGameUpdates payload).
-- ctx: { config_path, stplug_dir, manifests_dir, steam_root }.
function mp.build_games(ctx)
  ctx = ctx or mp.default_ctx()
  local pins = mp.parse_pins(read_file(ctx.config_path) or "")

  -- enumerate <appid>.lua in stplug-in
  local lua_files = {}
  local ok_lfs, lfs = pcall(require, "lfs")
  if ctx.stplug_dir then
    if ok_lfs then
      for entry in lfs.dir(ctx.stplug_dir) do lua_files[#lua_files + 1] = entry end
    else
      local p = io.popen("ls -1 '" .. ctx.stplug_dir .. "' 2>/dev/null")
      if p then for line in p:lines() do lua_files[#lua_files + 1] = line end; p:close() end
    end
  end

  local games = {}
  table.sort(lua_files)
  for _, name in ipairs(lua_files) do
    local appid = name:match("^(%d+)%.lua$")
    if appid then
      appid = math.tointeger(tonumber(appid))
    end
    -- Skip Steam tools / runtimes / redistributables outright: they're not
    -- games, so they shouldn't appear as cards in the main list (same reason as
    -- the Steamworks redistributables).
    if appid and not mp.is_tool(appid) then
      local lua = read_file(ctx.stplug_dir .. "/" .. name) or ""
      local parsed = mp.parse_lua(lua)
      local installed = installed_gids(ctx.steam_root, appid)
      local appPins = pins[appid] or { locked = false, depots = {} }
      local has_workshop = app_has_workshop(ctx.steam_root, appid)

      local depots = {}
      for depot, info in pairs(parsed.depots) do
        local versions = archived_versions(ctx.manifests_dir, depot)
        if #versions > 0 then
          for _, v in ipairs(versions) do
            v.fromLuaTools = (info.manifestid ~= nil and v.gid == info.manifestid)
            v.installed = (installed[depot] ~= nil and v.gid == installed[depot])
            v.pinned = (appPins.depots[depot] ~= nil and v.gid == appPins.depots[depot])
          end
          table.sort(versions, function(a, b) return (a.date or 0) > (b.date or 0) end)
          depots[#depots + 1] = {
            depot = depot,
            name = mp.tool_name(depot),
            fromLuaTools = info.manifestid,
            installed = installed[depot],
            workshop = mp.is_workshop_depot(appid, depot, has_workshop),
            shared = mp.is_shared_depot(depot),
            versions = versions,
          }
        end
      end
      table.sort(depots, function(a, b) return a.depot < b.depot end)

      -- The Steamworks Common Redistributables app (and any pure-runtime entry)
      -- has a .lua too, so it surfaces here — but every one of its depots is a
      -- shared runtime depot. It's not a real game (a single ancient "build",
      -- nothing meaningful to pin), so showing it as a top-level card is
      -- inconsistent. Drop a game whose depots are ALL shared; a real game always
      -- has at least one non-shared content depot.
      local all_shared = #depots > 0
      for _, d in ipairs(depots) do
        if not d.shared then all_shared = false; break end
      end

      -- Skip games with no archived versions at all: there's nothing to show or
      -- pin, and an empty depot list would serialize as `{}` (not `[]`) and trip
      -- the frontend. (Also keeps the list clean after a manifest purge.)
      if #depots > 0 and not all_shared then
        games[#games + 1] = {
          appid = appid,
          locked = appPins.locked or false,
          depots = depots,
          dlc_appids = parsed.dlc_appids,
        }
      end
    end
  end
  return games
end

-- ── manifest storage management ──────────────────────────────────────────
-- delete_manifest(dir, depot, gid) -> ok, err. Removes a single archived
-- <depot>_<gid>.manifest. depot/gid must be all-digits (guards against path
-- traversal — the values flow in from the frontend).
function mp.delete_manifest(manifests_dir, depot, gid)
  if not manifests_dir then return false, "no manifests dir" end
  local d = math.tointeger(tonumber(depot))
  gid = tostring(gid)
  if not d or not gid:match("^%d+$") then return false, "bad depot/gid" end
  local path = manifests_dir .. "/" .. d .. "_" .. gid .. ".manifest"
  local ok, err = os.remove(path)
  if not ok then return false, err or "remove failed" end
  return true
end

-- clear_manifests(ctx) -> removed_count, freed_bytes. Deletes every archived
-- manifest EXCEPT the ones currently installed or pinned (those are still
-- needed: the pinned one backs the redirect, and we keep installed defensively).
-- Frees the rollback history without breaking the current state.
function mp.clear_manifests(ctx)
  ctx = ctx or mp.default_ctx()
  if not ctx.manifests_dir then return 0, 0 end

  local keep = {}
  local games = mp.build_games(ctx)
  for _, g in ipairs(games) do
    for _, dep in ipairs(g.depots) do
      for _, v in ipairs(dep.versions) do
        if v.installed or v.pinned then keep[dep.depot .. "_" .. v.gid] = true end
      end
    end
  end

  local names = {}
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs then
    for entry in lfs.dir(ctx.manifests_dir) do names[#names + 1] = entry end
  else
    local p = io.popen("ls -1 '" .. ctx.manifests_dir .. "' 2>/dev/null")
    if p then for line in p:lines() do names[#names + 1] = line end; p:close() end
  end

  local removed, freed = 0, 0
  for _, name in ipairs(names) do
    local depot, gid = name:match("^(%d+)_(%d+)%.manifest$")
    if depot and not keep[depot .. "_" .. gid] then
      local path = ctx.manifests_dir .. "/" .. name
      local data = read_file(path)
      if os.remove(path) then
        removed = removed + 1
        freed = freed + (data and #data or 0)
      end
    end
  end
  return removed, freed
end

-- ── RPC methods (each returns a JSON string) ────────────────────────────────
local function err(msg) return json.encode({ success = false, error = tostring(msg) }) end
local function as_int(v) return math.tointeger(tonumber(v)) end

function mp.get_game_updates(ctx)
  ctx = ctx or mp.default_ctx()
  local ok, games = pcall(mp.build_games, ctx)
  if not ok then return err(games) end
  return json.encode({ success = true, games = games })
end

-- SetGamePin{appid, gid|date}: pin every depot of the app to its newest
-- archived gid whose creation_time <= T (T = creation_time of the chosen gid,
-- or the explicit `date`), and lock the game.
function mp.set_game_pin_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or not req.appid then return err("bad request") end
  local appid = as_int(req.appid)

  -- assemble per-depot versions for this app
  local games = mp.build_games(ctx)
  local game
  for _, g in ipairs(games) do if g.appid == appid then game = g; break end end
  if not game then return err("unknown app") end

  local versions_by_depot = {}
  local gid_date = {}
  for _, d in ipairs(game.depots) do
    -- Skip the workshop depot: its snapshots aren't game builds, and locking the
    -- game version must not downgrade the user's workshop content.
    if not d.workshop then
      versions_by_depot[d.depot] = d.versions
      for _, v in ipairs(d.versions) do gid_date[v.gid] = v.date end
    end
  end

  local T = req.date and as_int(req.date) or (req.gid and gid_date[tostring(req.gid)])
  if not T then return err("could not resolve build date") end

  -- Expand the cutoff to the end of the selected day so every depot's build from
  -- that day is pinned, not just the base depot's exact second (sibling depots
  -- in a release are packaged a little later — see end_of_day).
  local depot_gids = mp.select_as_of(versions_by_depot, mp.end_of_day(T))
  if next(depot_gids) == nil then return err("no archived build at or before that date") end

  local pins = mp.parse_pins(read_file(ctx.config_path) or "")
  mp.set_game_pin(pins, appid, depot_gids)
  local wok, werr = write_pins(ctx.config_path, pins)
  if not wok then return err(werr) end
  mp.invalidate_appinfo_cache(ctx, appid)
  return json.encode({ success = true, appid = appid })
end

function mp.set_dlc_pin_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or not req.appid or not req.depot or not req.gid then
    return err("bad request")
  end
  local pins = mp.parse_pins(read_file(ctx.config_path) or "")
  mp.set_dlc_pin(pins, as_int(req.appid), as_int(req.depot), tostring(req.gid))
  local wok, werr = write_pins(ctx.config_path, pins)
  if not wok then return err(werr) end
  mp.invalidate_appinfo_cache(ctx, as_int(req.appid))
  return json.encode({ success = true })
end

function mp.clear_game_pin_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or not req.appid then return err("bad request") end
  local pins = mp.parse_pins(read_file(ctx.config_path) or "")
  mp.clear_game_pin(pins, as_int(req.appid))
  local wok, werr = write_pins(ctx.config_path, pins)
  if not wok then return err(werr) end
  mp.invalidate_appinfo_cache(ctx, as_int(req.appid))
  return json.encode({ success = true })
end

function mp.clear_dlc_pin_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or not req.appid or not req.depot then
    return err("bad request")
  end
  local pins = mp.parse_pins(read_file(ctx.config_path) or "")
  mp.clear_dlc_pin(pins, as_int(req.appid), as_int(req.depot))
  local wok, werr = write_pins(ctx.config_path, pins)
  if not wok then return err(werr) end
  mp.invalidate_appinfo_cache(ctx, as_int(req.appid))
  return json.encode({ success = true })
end

-- ImportLuaPin{appid, lua}: pin a game to the exact build named by a lua.tools
-- manifest .lua (the file its "Manifest" button hands out). Its
-- setManifestid(depot,"gid") lines name the build a crack/fix targets; we write
-- those depot gids as ManifestPins + lock the app, so the manifestbind redirect
-- installs that build unconditionally (online, BYld fetches each manifest by
-- request code using the depot key already present in the installed .lua).
-- `lua` is the file's full text (uploaded from the frontend). When `appid` is
-- given (the card's game) it must equal the .lua's base appid, guarding against
-- importing the wrong game's file.
function mp.import_lua_pin_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or type(req.lua) ~= "string" then
    return err("bad request")
  end
  local parsed = mp.parse_lua(req.lua)
  local appid = as_int(req.appid) or parsed.base
  if not appid then return err("could not determine app id from .lua") end
  if parsed.base and as_int(req.appid) and parsed.base ~= as_int(req.appid) then
    return err("this .lua is for app " .. parsed.base .. ", not " .. as_int(req.appid))
  end

  local depot_gids = {}
  local count = 0
  for depot, info in pairs(parsed.depots) do
    if info.manifestid then depot_gids[depot] = info.manifestid; count = count + 1 end
  end
  if count == 0 then return err("no setManifestid pins found in .lua") end

  local pins = mp.parse_pins(read_file(ctx.config_path) or "")
  mp.set_game_pin(pins, appid, depot_gids)
  local wok, werr = write_pins(ctx.config_path, pins)
  if not wok then return err(werr) end
  mp.invalidate_appinfo_cache(ctx, appid)
  return json.encode({ success = true, appid = appid, pinned = count })
end

-- ImportLuaFull{appid?, lua}: import a LuaTools .lua for a game NOT yet added
-- via the LuaTools plugin. Writes the .lua to stplug-in/<appid>.lua (depot
-- keys), registers the appid in AdditionalApps, and applies the setManifestid
-- pins (locking the build) when the file carries any — all config edits in ONE
-- atomic write. The appid is the .lua's base (first bare addappid); a
-- card-supplied appid must match it. A .lua with no setManifestid still imports
-- (pinned=0): the game installs at the latest build. SLSsteam only provisions a
-- brand-new appid on its next start, so the frontend prompts a Steam restart.
function mp.import_lua_full_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or type(req.lua) ~= "string" then
    return err("bad request")
  end
  local parsed = mp.parse_lua(req.lua)
  local appid = as_int(req.appid) or parsed.base
  if not appid then return err("could not determine app id from .lua") end
  if parsed.base and as_int(req.appid) and parsed.base ~= as_int(req.appid) then
    return err("this .lua is for app " .. parsed.base .. ", not " .. as_int(req.appid))
  end

  -- 1) write the .lua (depot keys) to stplug-in.
  local lok, lerr = write_lua_file(ctx.stplug_dir, appid, req.lua)
  if not lok then return err(lerr) end

  -- 2) collect setManifestid pins (optional — a keys-only .lua is valid).
  local depot_gids, count = {}, 0
  for depot, info in pairs(parsed.depots) do
    if info.manifestid then depot_gids[depot] = info.manifestid; count = count + 1 end
  end

  -- 3) register the appid in AdditionalApps + apply pins in one atomic write.
  local cfg = read_file(ctx.config_path)
  if not cfg then return err("config.yaml not found") end
  local newcfg, status = mp.add_additional_app(cfg, appid)
  if status == "inline_refused" then
    return err("AdditionalApps uses an inline list; refusing to edit")
  end
  if count > 0 then
    local pins = mp.parse_pins(newcfg)
    mp.set_game_pin(pins, appid, depot_gids)
    newcfg = mp.splice_pins(newcfg, pins)
  end
  local cwok, cwerr = write_config_raw(ctx.config_path, newcfg)
  if not cwok then return err(cwerr) end
  mp.invalidate_appinfo_cache(ctx, appid)

  return json.encode({ success = true, appid = appid, pinned = count, added = status })
end

-- InspectLua{appid?, lua}: read-only pre-check for the "Load .lua" flow.
-- Returns the .lua's base appid, whether the game is currently installed (an
-- appmanifest exists in any library), and how many setManifestid pins it
-- carries — so the frontend can choose between a plain import and the
-- reinstall-confirm modal WITHOUT writing anything yet.
function mp.inspect_lua_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or type(req.lua) ~= "string" then
    return err("bad request")
  end
  local parsed = mp.parse_lua(req.lua)
  local appid = as_int(req.appid) or parsed.base
  if not appid then return err("could not determine app id from .lua") end
  if parsed.base and as_int(req.appid) and parsed.base ~= as_int(req.appid) then
    return err("this .lua is for app " .. parsed.base .. ", not " .. as_int(req.appid))
  end
  local count = 0
  for _, info in pairs(parsed.depots) do if info.manifestid then count = count + 1 end end
  -- alreadyOnBuild: the game is installed AND every depot the .lua pins is
  -- already installed at that exact gid -> nothing to change (the frontend then
  -- only offers a force "apply anyway", never a silent re-validate).
  local inst = installed_gids(ctx.steam_root, appid)
  local installed = (next(inst) ~= nil)
  local matched = 0
  for depot, info in pairs(parsed.depots) do
    if info.manifestid and inst[depot] ~= nil and inst[depot] == info.manifestid then
      matched = matched + 1
    end
  end
  local already_on_build = installed and count > 0 and matched == count
  return json.encode({ success = true, appid = appid,
    installed = installed, pinned = count, alreadyOnBuild = already_on_build })
end

-- DeleteManifest{depot, gid}: remove a single archived version's manifest.
function mp.delete_manifest_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or not req.depot or not req.gid then
    return err("bad request")
  end
  local dok, derr = mp.delete_manifest(ctx.manifests_dir, req.depot, req.gid)
  if not dok then return err(derr) end
  return json.encode({ success = true })
end

-- ClearManifests{}: drop all archived manifests except installed/pinned ones.
function mp.clear_manifests_rpc(ctx)
  ctx = ctx or mp.default_ctx()
  local ok, removed, freed = pcall(mp.clear_manifests, ctx)
  if not ok then return err(removed) end
  return json.encode({ success = true, removed = removed, freed = freed })
end

-- register(registry): install the five Game Updates RPCs bound to the real ctx.
function mp.register(registry)
  registry.GetGameUpdates = function() return mp.get_game_updates(mp.default_ctx()) end
  registry.SetGamePin = function(j) return mp.set_game_pin_rpc(mp.default_ctx(), j) end
  registry.SetDlcPin = function(j) return mp.set_dlc_pin_rpc(mp.default_ctx(), j) end
  registry.ClearGamePin = function(j) return mp.clear_game_pin_rpc(mp.default_ctx(), j) end
  registry.ClearDlcPin = function(j) return mp.clear_dlc_pin_rpc(mp.default_ctx(), j) end
  registry.ImportLuaPin = function(j) return mp.import_lua_pin_rpc(mp.default_ctx(), j) end
  registry.ImportLuaFull = function(j) return mp.import_lua_full_rpc(mp.default_ctx(), j) end
  registry.InspectLua = function(j) return mp.inspect_lua_rpc(mp.default_ctx(), j) end
  registry.DeleteManifest = function(j) return mp.delete_manifest_rpc(mp.default_ctx(), j) end
  registry.ClearManifests = function() return mp.clear_manifests_rpc(mp.default_ctx()) end
  return registry
end

return mp
