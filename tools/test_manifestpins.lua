-- Run: lua5.4 tools/test_manifestpins.lua
-- Tests the Lumen "Game Updates" backend (manifestpins.lua): manifest
-- creation_time parsing, LuaTools .lua parsing, ManifestPins config
-- parse/emit/splice round-trips, "as-of-date" build selection, pin-model
-- mutations, and the RPC get/set/clear round-trip on a temp config.
package.path = "lua/?.lua;" .. package.path
local mp = require("manifestpins")
local json = require("json")

local fails = 0
local function check(cond, msg)
  if cond then print("ok:   " .. msg)
  else print("FAIL: " .. msg); fails = fails + 1 end
end
local function eq(a, b, msg) check(a == b, msg .. " (got=" .. tostring(a) .. ")") end

-- varint encoder for building a synthetic manifest metadata block.
local function varint(n)
  local out = {}
  repeat
    local b = n & 0x7f
    n = n >> 7
    if n ~= 0 then b = b | 0x80 end
    out[#out + 1] = string.char(b)
  until n == 0
  return table.concat(out)
end

-- ── 1. creation_time parse (synthetic ContentManifestMetadata) ─────────────
do
  -- field1 depot=250902, field2 gid (low bits ok), field3 creation_time
  local pb = "\x08" .. varint(250902)
            .. "\x10" .. varint(4994611894646808503 & 0x7fffffffffff)
            .. "\x18" .. varint(1423617525)
  local block = "\xBE\x12\x48\x1F" .. string.pack("<I4", #pb) .. pb
  local payload_noise = string.rep("\xAB\xCD", 100) -- precedes metadata
  local ct = mp.creation_time_from_bytes(payload_noise .. block .. "\x17\xB8\x81\x1B")
  eq(ct, 1423617525, "creation_time: field 3 varint decoded")

  check(mp.creation_time_from_bytes("no magic here") == nil,
        "creation_time: missing magic -> nil")
end

-- ── 2. LuaTools .lua parse ─────────────────────────────────────────────────
do
  local lua = table.concat({
    "addappid(250900)",
    'addappid(250900,0,"basekey")',
    "addappid(401920)",
    "addappid(570660)",
    'addappid(250902,0,"k2")',
    'setManifestid(250902,"4994611894646808503")',
    'addappid(250903,0,"k3")',
    'setManifestid(250903,"367036646469636831")',
  }, "\n")
  local p = mp.parse_lua(lua)
  eq(p.base, 250900, "lua: base appid is first bare addappid")
  check(p.depots[250902] ~= nil and p.depots[250902].manifestid == "4994611894646808503",
        "lua: depot 250902 manifestid captured")
  check(p.depots[250903].manifestid == "367036646469636831", "lua: depot 250903 manifestid")
  check(p.depots[250900] ~= nil, "lua: keyed base depot 250900 present")
  -- dlc_appids = bare addappid excluding base
  local dlc = {}
  for _, id in ipairs(p.dlc_appids) do dlc[id] = true end
  check(dlc[401920] and dlc[570660], "lua: dlc appids 401920/570660")
  check(not dlc[250900], "lua: base not in dlc_appids")
  check(not dlc[250902], "lua: keyed depot not in dlc_appids")
end

-- ── 3. config pins parse ───────────────────────────────────────────────────
do
  local text = table.concat({
    "AdditionalApps:",
    "ManifestPins:",
    "  1054490:",
    "    locked: true",
    "    depots:",
    '      1054491: "4091695229428697509"',
    '      1054492: "6006800166866532891"',
    "  285900:",
    "    locked: false",
    "    depots:",
    '      285904: "123456789012345"',
    "LogLevel: 2",
  }, "\n")
  local pins = mp.parse_pins(text)
  eq(pins[1054490].locked, true, "parse: app locked")
  eq(pins[1054490].depots[1054491], "4091695229428697509", "parse: gid1 string")
  eq(pins[1054490].depots[1054492], "6006800166866532891", "parse: gid2 string")
  eq(pins[285900].locked, false, "parse: app unlocked")
  eq(pins[285900].depots[285904], "123456789012345", "parse: dlc gid")
end

-- ── 4. emit + parse round-trip ─────────────────────────────────────────────
do
  local pins = {
    [1054490] = { locked = true, depots = { [1054491] = "4091695229428697509" } },
  }
  local block = mp.emit_pins(pins)
  check(block:find("ManifestPins:", 1, true) ~= nil, "emit: has header")
  check(block:find('1054491: "4091695229428697509"', 1, true) ~= nil, "emit: quoted gid")
  local back = mp.parse_pins(block)
  eq(back[1054490].locked, true, "roundtrip: locked")
  eq(back[1054490].depots[1054491], "4091695229428697509", "roundtrip: gid")
end

-- ── 5. splice preserves the rest of the file ───────────────────────────────
do
  local text = "AdditionalApps:\nLogLevel: 2\n"
  local pins = { [42] = { locked = true, depots = { [43] = "999" } } }
  local out = mp.splice_pins(text, pins)
  check(out:find("AdditionalApps:", 1, true) ~= nil, "splice: keeps AdditionalApps")
  check(out:find("LogLevel: 2", 1, true) ~= nil, "splice: keeps LogLevel")
  check(out:find("ManifestPins:", 1, true) ~= nil, "splice: inserts block")
  -- replace existing block, then clear it
  local replaced = mp.splice_pins(out, { [42] = { locked = false, depots = { [43] = "111" } } })
  check(replaced:find('43: "111"', 1, true) ~= nil, "splice: replaces existing block")
  check(select(2, replaced:gsub("ManifestPins:", "")) == 1, "splice: exactly one block")
  local cleared = mp.splice_pins(replaced, {})
  check(cleared:find("ManifestPins:", 1, true) == nil, "splice: empty map removes block")
  check(cleared:find("LogLevel: 2", 1, true) ~= nil, "splice: rest survives removal")
end

-- ── 6. as-of-date selection (newest gid with date <= T per depot) ──────────
do
  local versions = {
    [100] = { { gid = "g3", date = 300 }, { gid = "g2", date = 200 }, { gid = "g1", date = 100 } },
    [101] = { { gid = "h2", date = 250 }, { gid = "h1", date = 150 } },
  }
  local sel = mp.select_as_of(versions, 200)
  eq(sel[100], "g2", "as-of: depot 100 newest <= 200")
  eq(sel[101], "h1", "as-of: depot 101 newest <= 200")
  local none = mp.select_as_of({ [100] = { { gid = "g1", date = 500 } } }, 200)
  check(none[100] == nil, "as-of: depot with nothing <= T is skipped")
end

-- ── 7b. end_of_day cutoff: a game pin must catch same-day sibling depots ────
do
  -- A game-level pin targets a DAY (the timeline is one row per day), so the
  -- cutoff has to include EVERY depot's build from that day. Sibling depots in
  -- the same release are packaged seconds apart (real case: Overcooked 2 depots
  -- 728882 @02:56:38 vs 728883 @02:57:44 UTC — 66s later, same 2020-09-09 day).
  local base = 1599620198  -- 2020-09-09 02:56:38 UTC
  local sib  = 1599620264  -- 2020-09-09 02:57:44 UTC
  local eod = mp.end_of_day(base)
  eq(eod % 86400, 86399, "end_of_day: lands on 23:59:59 UTC")
  check(eod >= sib, "end_of_day: covers a same-day sibling built later")
  local vbd = {
    [728882] = { { gid = "A", date = base } },
    [728883] = { { gid = "B", date = sib } },
  }
  check(mp.select_as_of(vbd, base)[728883] == nil,
    "as-of(raw ts): sibling 66s later is missed (the bug)")
  local fixed = mp.select_as_of(vbd, eod)
  check(fixed[728882] == "A" and fixed[728883] == "B",
    "as-of(end_of_day): both same-day depots pinned")
end

-- ── 7. pin-model mutations ─────────────────────────────────────────────────
do
  local pins = {}
  mp.set_game_pin(pins, 7, { [70] = "700", [71] = "710" })
  eq(pins[7].locked, true, "set_game_pin: locks the game")
  eq(pins[7].depots[70], "700", "set_game_pin: depot gid")

  mp.set_dlc_pin(pins, 7, 72, "720")
  eq(pins[7].depots[72], "720", "set_dlc_pin: adds depot")
  eq(pins[7].locked, true, "set_dlc_pin: leaves lock untouched")

  mp.set_dlc_pin(pins, 8, 80, "800")
  eq(pins[8].locked, false, "set_dlc_pin: new app unlocked by default")

  mp.clear_dlc_pin(pins, 7, 70)
  check(pins[7].depots[70] == nil, "clear_dlc_pin: removes one depot")
  check(pins[7].depots[71] ~= nil, "clear_dlc_pin: keeps other depots")

  mp.clear_game_pin(pins, 7)
  check(pins[7] == nil, "clear_game_pin: removes the app entry")

  mp.clear_dlc_pin(pins, 8, 80)
  check(pins[8] == nil, "clear_dlc_pin: drops app when last depot gone and unlocked")
end

-- ── 8. RPC round-trip on a temp config (set/clear via JSON) ────────────────
do
  local cfgpath = os.tmpname()
  local f = assert(io.open(cfgpath, "wb"))
  f:write("AdditionalApps:\n  - 555\nLogLevel: 2\n"); f:close()

  local ctx = { config_path = cfgpath }

  -- set a DLC pin
  local res = json.decode(mp.set_dlc_pin_rpc(ctx, json.encode({ appid = 555, depot = 556, gid = "12345" })))
  eq(res.success, true, "rpc set_dlc_pin: success")
  -- re-read config and confirm persisted
  local rf = io.open(cfgpath, "rb"); local body = rf:read("*a"); rf:close()
  check(body:find('556: "12345"', 1, true) ~= nil, "rpc set_dlc_pin: persisted to config")
  check(body:find("AdditionalApps:", 1, true) ~= nil, "rpc set_dlc_pin: config preserved")

  -- clear it
  local cres = json.decode(mp.clear_dlc_pin_rpc(ctx, json.encode({ appid = 555, depot = 556 })))
  eq(cres.success, true, "rpc clear_dlc_pin: success")
  local rf2 = io.open(cfgpath, "rb"); local body2 = rf2:read("*a"); rf2:close()
  check(body2:find("12345", 1, true) == nil, "rpc clear_dlc_pin: pin removed")
  check(body2:find("LogLevel: 2", 1, true) ~= nil, "rpc clear_dlc_pin: rest survives")
  os.remove(cfgpath)
end

-- ── 8b. workshop-depot detection (pure) ───────────────────────────────────
do
  -- The Workshop content depot has id == appid. It only counts as workshop when
  -- the app actually has workshop content on disk; otherwise a depot whose id
  -- happens to equal the appid is treated as normal game content.
  check(mp.is_workshop_depot(250900, 250900, true) == true,
    "workshop: depot==appid with workshop present -> true")
  check(mp.is_workshop_depot(250900, 250900, false) == false,
    "workshop: depot==appid but no workshop on disk -> false")
  check(mp.is_workshop_depot(250900, 250903, true) == false,
    "workshop: content depot (id != appid) -> false")
end

-- ── 8c. libraryfolders.vdf path parsing (pure) ────────────────────────────
do
  local vdf = table.concat({
    '"libraryfolders"', "{",
    '\t"0"', "\t{",
    '\t\t"path"\t\t"/home/u/.local/share/Steam"', "\t}",
    '\t"1"', "\t{",
    '\t\t"path"\t\t"/mnt/Games/SteamLibrary"', "\t}",
    "}",
  }, "\n")
  local paths = mp.parse_library_paths(vdf)
  eq(#paths, 2, "libpaths: two library paths parsed")
  eq(paths[1], "/home/u/.local/share/Steam", "libpaths: primary path")
  eq(paths[2], "/mnt/Games/SteamLibrary", "libpaths: secondary path")
  eq(#mp.parse_library_paths(""), 0, "libpaths: empty text -> none")
end

-- ── 8d. shared-runtime depot detection (pure) ─────────────────────────────
do
  -- Steamworks Common Redistributables (app 228980): fixed depot ids reused by
  -- every game; labelled as shared so their ancient manifest dates don't look
  -- like the game's own builds.
  check(mp.is_shared_depot(228990) == true, "shared: 228990 is a common redist")
  check(mp.is_shared_depot(228989) == true, "shared: 228989 is a common redist")
  check(mp.is_shared_depot(229007) == true, "shared: 229007 is a common redist")
  check(mp.is_shared_depot(2327721) == false, "shared: a game content depot is not shared")
end

-- ── 8e. Steam tools / runtimes / redistributables naming + detection ──────
do
  check(mp.is_tool(228980) == true, "tool: redistributables app is a tool")
  check(mp.is_tool(1493710) == true, "tool: Proton Experimental is a tool")
  check(mp.is_tool(1628350) == true, "tool: sniper runtime is a tool")
  check(mp.is_tool(238320) == false, "tool: a real game (Outlast) is not a tool")
  check(mp.tool_name(228990) == "Windows DirectX Jun 2010 Redist", "tool: DirectX depot name")
  check(mp.tool_name("1628350") == "Steam Linux Runtime 3.0 (sniper)", "tool: name accepts a string id")
  check(mp.tool_name(238320) == nil, "tool: a real game has no tool name")
end

-- ── 9. tree assembly from fixture .lua / .acf / manifests dir ──────────────
do
  -- Build a synthetic manifest file with a given depot + creation_time.
  local function write_manifest(dir, depot, gid, ct)
    local pb = "\x08" .. varint(depot) .. "\x18" .. varint(ct)
    local block = "\xBE\x12\x48\x1F" .. string.pack("<I4", #pb) .. pb
    local f = assert(io.open(dir .. "/" .. depot .. "_" .. gid .. ".manifest", "wb"))
    f:write(string.rep("\0", 64) .. block); f:close()
  end
  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end

  local root = os.tmpname(); os.remove(root); mkdir(root)
  local stplug = root .. "/stplug-in"
  local mans = root .. "/manifests"
  local steamapps = root .. "/steamapps"
  mkdir(stplug); mkdir(mans); mkdir(steamapps)

  local lf = assert(io.open(stplug .. "/638510.lua", "wb"))
  lf:write(table.concat({
    "addappid(638510)",
    'addappid(638510,0,"kw")',   -- workshop depot: id == appid
    'addappid(638511,0,"k")',
    'setManifestid(638511,"111")',
    "addappid(999)",
  }, "\n")); lf:close()

  write_manifest(mans, 638511, "111", 100)
  write_manifest(mans, 638511, "222", 200)
  write_manifest(mans, 638510, "777", 300)   -- a workshop snapshot manifest

  local af = assert(io.open(steamapps .. "/appmanifest_638510.acf", "wb"))
  af:write('"AppState"\n{\n\t"InstalledDepots"\n\t{\n\t\t"638511"\n\t\t{\n\t\t\t"manifest"\t\t"222"\n\t\t}\n\t}\n}\n')
  af:close()

  -- mark the app as having workshop content (presence of appworkshop_<appid>.acf)
  mkdir(steamapps .. "/workshop")
  local wf = assert(io.open(steamapps .. "/workshop/appworkshop_638510.acf", "wb"))
  wf:write('"AppWorkshop"\n{\n}\n'); wf:close()

  local cfg = root .. "/config.yaml"
  local cf = assert(io.open(cfg, "wb"))
  cf:write(table.concat({
    "ManifestPins:",
    "  638510:",
    "    locked: false",
    "    depots:",
    '      638511: "111"',
  }, "\n")); cf:close()

  local ctx = { config_path = cfg, stplug_dir = stplug, manifests_dir = mans, steam_root = root }
  local games = mp.build_games(ctx)
  eq(#games, 1, "build: one game")
  local g = games[1]
  eq(g.appid, 638510, "build: appid")
  eq(#g.depots, 2, "build: two depots with archived manifests")
  -- locate depots by id (sorted ascending: 638510 workshop, 638511 content)
  local byid = {}
  for _, dep in ipairs(g.depots) do byid[dep.depot] = dep end
  local ws = byid[638510]
  local d = byid[638511]
  check(ws ~= nil and ws.workshop == true, "build: depot==appid flagged as workshop")
  check(d ~= nil and (d.workshop == false or d.workshop == nil),
    "build: content depot not flagged workshop")
  eq(d.depot, 638511, "build: depot id")
  eq(#d.versions, 2, "build: two archived versions")
  eq(d.versions[1].gid, "222", "build: newest version first")
  eq(d.versions[1].date, 200, "build: newest date")
  eq(d.versions[1].installed, true, "build: 222 marked installed (from acf)")
  eq(d.versions[2].gid, "111", "build: older version second")
  eq(d.versions[2].fromLuaTools, true, "build: 111 marked fromLuaTools")
  eq(d.versions[2].pinned, true, "build: 111 marked pinned (config)")
  -- each version carries its manifest byte size (used to detect stub depots)
  local function fsize(p) local fh=io.open(p,"rb"); local s=fh:read("*a"); fh:close(); return #s end
  eq(d.versions[1].size, fsize(mans .. "/638511_222.manifest"), "build: version carries manifest size")
  check(d.versions[2].size > 0, "build: older version size > 0")
  local dlc = {}
  for _, id in ipairs(g.dlc_appids) do dlc[id] = true end
  check(dlc[999], "build: dlc appid surfaced")

  -- a game whose depots have NO archived manifests is omitted (nothing to pin;
  -- avoids an empty list serializing as {} and breaking the frontend)
  local lf2 = assert(io.open(stplug .. "/555.lua", "wb"))
  lf2:write('addappid(555)\naddappid(556,0,"k")\n'); lf2:close()
  local games2 = mp.build_games(ctx)
  local has555 = false
  for _, gg in ipairs(games2) do if gg.appid == 555 then has555 = true end end
  check(not has555, "build: game with no archived versions is omitted")

  -- Steam tools / runtimes / redistributables are NOT games: even with a .lua +
  -- an archived manifest they must be dropped from the main list (same as the
  -- Steamworks redistributables). Here the redistributables app (228980).
  local lf3 = assert(io.open(stplug .. "/228980.lua", "wb"))
  lf3:write('addappid(228980)\naddappid(228990,0,"k")\n'); lf3:close()
  write_manifest(mans, 228990, "abc123", 123)
  local games3 = mp.build_games(ctx)
  local hasTool = false
  for _, gg in ipairs(games3) do if gg.appid == 228980 then hasTool = true end end
  check(not hasTool, "build: a Steam tool app (228980) is omitted from the list")

  -- locking the game must pin only real content depots, NEVER the workshop depot
  -- (its snapshots aren't game builds — pinning it would downgrade workshop).
  local sg = json.decode(mp.set_game_pin_rpc(ctx, json.encode({ appid = 638510, date = 250 })))
  eq(sg.success, true, "set_game_pin: success")
  local rf = assert(io.open(cfg, "rb")); local cbody = rf:read("*a"); rf:close()
  local pa = mp.parse_pins(cbody)
  check(pa[638510] ~= nil and pa[638510].depots[638511] ~= nil,
    "set_game_pin: content depot pinned")
  check(pa[638510].depots[638510] == nil,
    "set_game_pin: workshop depot NOT pinned")
  os.execute("rm -rf '" .. root .. "'")
end

-- ── 10. installed detection across multiple Steam library folders ──────────
do
  local function write_manifest(dir, depot, gid, ct)
    local pb = "\x08" .. varint(depot) .. "\x18" .. varint(ct)
    local block = "\xBE\x12\x48\x1F" .. string.pack("<I4", #pb) .. pb
    local f = assert(io.open(dir .. "/" .. depot .. "_" .. gid .. ".manifest", "wb"))
    f:write(string.rep("\0", 64) .. block); f:close()
  end
  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end

  local root = os.tmpname(); os.remove(root); mkdir(root)
  local lib2 = os.tmpname(); os.remove(lib2); mkdir(lib2)
  local stplug = root .. "/stplug-in"
  local mans = root .. "/manifests"
  mkdir(stplug); mkdir(mans)
  mkdir(root .. "/steamapps"); mkdir(lib2 .. "/steamapps")

  -- The game is installed on the SECONDARY library only.
  local lf = assert(io.open(stplug .. "/700.lua", "wb"))
  lf:write("addappid(700)\naddappid(701,0,\"k\")\n"); lf:close()
  write_manifest(mans, 701, "900", 500)
  local af = assert(io.open(lib2 .. "/steamapps/appmanifest_700.acf", "wb"))
  af:write('"AppState"\n{\n\t"InstalledDepots"\n\t{\n\t\t"701"\n\t\t{\n\t\t\t"manifest"\t\t"900"\n\t\t}\n\t}\n}\n')
  af:close()

  -- libraryfolders.vdf in the primary root points at both libraries.
  local lv = assert(io.open(root .. "/steamapps/libraryfolders.vdf", "wb"))
  lv:write('"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"' .. root ..
           '"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"' .. lib2 .. '"\n\t}\n}\n')
  lv:close()

  local cfg = root .. "/config.yaml"
  local cf = assert(io.open(cfg, "wb")); cf:write("LogLevel: 2\n"); cf:close()

  local ctx = { config_path = cfg, stplug_dir = stplug, manifests_dir = mans, steam_root = root }
  local games = mp.build_games(ctx)
  eq(#games, 1, "multilib: one game")
  local d = games[1].depots[1]
  eq(d.installed, "900", "multilib: installed gid found in SECONDARY library")
  eq(d.versions[1].installed, true, "multilib: version flagged installed across libraries")
  os.execute("rm -rf '" .. root .. "' '" .. lib2 .. "'")
end

-- ── 11. delete_manifest / clear_manifests (storage management) ─────────────
do
  local function write_manifest(dir, depot, gid, ct)
    local pb = "\x08" .. varint(depot) .. "\x18" .. varint(ct)
    local block = "\xBE\x12\x48\x1F" .. string.pack("<I4", #pb) .. pb
    local f = assert(io.open(dir .. "/" .. depot .. "_" .. gid .. ".manifest", "wb"))
    f:write(string.rep("\0", 64) .. block); f:close()
  end
  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end
  local function exists(p) local h = io.open(p, "rb"); if h then h:close(); return true end return false end

  local root = os.tmpname(); os.remove(root); mkdir(root)
  local stplug, mans = root .. "/stplug-in", root .. "/manifests"
  mkdir(stplug); mkdir(mans); mkdir(root .. "/steamapps")

  -- one app, depot 800 with three versions: 100 (pinned), 200 (installed), 300 (spare)
  local lf = assert(io.open(stplug .. "/600.lua", "wb"))
  lf:write('addappid(600)\naddappid(800,0,"k")\n'); lf:close()
  write_manifest(mans, 800, "100", 1000)
  write_manifest(mans, 800, "200", 2000)
  write_manifest(mans, 800, "300", 3000)
  write_manifest(mans, 999, "777", 1500)  -- orphan: no .lua references depot 999
  local af = assert(io.open(root .. "/steamapps/appmanifest_600.acf", "wb"))
  af:write('"AppState"\n{\n\t"InstalledDepots"\n\t{\n\t\t"800"\n\t\t{\n\t\t\t"manifest"\t\t"200"\n\t\t}\n\t}\n}\n')
  af:close()
  local cfg = root .. "/config.yaml"
  local cf = assert(io.open(cfg, "wb"))
  cf:write('AdditionalApps:\n  - 600\nManifestPins:\n  600:\n    locked: true\n    depots:\n      800: "100"\n')
  cf:close()
  local ctx = { config_path = cfg, stplug_dir = stplug, manifests_dir = mans, steam_root = root }

  -- delete_manifest: rejects path-traversal / non-numeric, removes a real file
  check(select(1, mp.delete_manifest(mans, 800, "../../etc/passwd")) == false,
    "delete: rejects non-numeric gid (no traversal)")
  check(exists(mans .. "/800_300.manifest"), "delete: spare present before")
  local ok = mp.delete_manifest(mans, 800, "300")
  check(ok == true, "delete: removes the spare version")
  check(not exists(mans .. "/800_300.manifest"), "delete: spare gone after")

  -- clear_manifests: keeps installed (200) + pinned (100), removes the rest
  --   (the orphan 999_777 and any other spares).
  write_manifest(mans, 800, "300", 3000)  -- re-add a spare to be cleared
  local removed = mp.clear_manifests(ctx)
  check(removed >= 2, "clear: removed spares + orphan (got " .. tostring(removed) .. ")")
  check(exists(mans .. "/800_100.manifest"), "clear: KEEPS pinned 100")
  check(exists(mans .. "/800_200.manifest"), "clear: KEEPS installed 200")
  check(not exists(mans .. "/800_300.manifest"), "clear: drops spare 300")
  check(not exists(mans .. "/999_777.manifest"), "clear: drops orphan 999")
  os.execute("rm -rf '" .. root .. "'")
end

-- ── 12. ImportLuaPin: pin a game to the gids in an uploaded lua.tools .lua ──
-- The lua.tools "Manifest" button hands the user a <appid>.lua whose
-- setManifestid(depot,"gid") lines name the exact build a crack/fix needs.
-- Importing it writes those depot gids as ManifestPins + locks the app, so the
-- redirect installs that build (online BYld fetches the manifest by request
-- code using the depot key already in the installed .lua).
do
  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local cfg = root .. "/config.yaml"
  local cf = assert(io.open(cfg, "wb"))
  cf:write("AdditionalApps:\n  - 3357650\nLogLevel: 2\n"); cf:close()
  local ctx = { config_path = cfg }

  -- a real lua.tools PRAGMATA manifest .lua (keys truncated for the fixture).
  local lua = table.concat({
    "-- PRAGMATA",
    "addappid(3357650)",
    "addappid(3859920)",
    "addappid(3859930)",
    'addappid(3357651, 1, "18e75bfb")',
    'addappid(3859920, 1, "1fb81184")',
    'addappid(3859930, 1, "14001799")',
    'setManifestid(3357651, "2417499809052404547")',
    'setManifestid(3859920, "4731286747379700304")',
    'setManifestid(3859930, "6714427611547107917")',
  }, "\n")

  local res = json.decode(mp.import_lua_pin_rpc(ctx, json.encode({ appid = 3357650, lua = lua })))
  eq(res.success, true, "import: success")
  eq(res.pinned, 3, "import: three depots pinned")

  local rf = assert(io.open(cfg, "rb")); local body = rf:read("*a"); rf:close()
  local pins = mp.parse_pins(body)
  check(pins[3357650] ~= nil, "import: app pinned")
  eq(pins[3357650].locked, true, "import: locks the app to the build")
  eq(pins[3357650].depots[3357651], "2417499809052404547", "import: base depot gid")
  eq(pins[3357650].depots[3859920], "4731286747379700304", "import: dlc depot gid")
  eq(pins[3357650].depots[3859930], "6714427611547107917", "import: dlc2 depot gid")
  check(body:find("AdditionalApps:", 1, true) ~= nil, "import: preserves rest of config")

  -- guard: appid passed by the card must match the .lua's base (wrong file)
  local bad = json.decode(mp.import_lua_pin_rpc(ctx, json.encode({ appid = 999999, lua = lua })))
  eq(bad.success, false, "import: rejects .lua whose base != selected game")

  -- guard: a .lua with no setManifestid lines has nothing to pin
  local nopins = json.decode(mp.import_lua_pin_rpc(ctx, json.encode({ lua = "addappid(42)\n" })))
  eq(nopins.success, false, "import: errors when no setManifestid present")

  os.execute("rm -rf '" .. root .. "'")
end

-- ── 13. add_additional_app (pure config-text edit) ────────────────────────
-- Mirrors the plugin's AdditionalApps block-list editor but as a pure
-- text->text transform so ImportLuaFull can register an appid in the SAME
-- atomic write that applies the pin (no second racing write to config.yaml).
do
  local t1 = "AdditionalApps:\n  - 111\nLogLevel: 2\n"
  local out, st = mp.add_additional_app(t1, 222)
  eq(st, "added", "add_app: reports added")
  check(out:find("- 222", 1, true) ~= nil, "add_app: appid inserted")
  check(out:find("- 111", 1, true) ~= nil, "add_app: existing entry kept")
  check(out:find("LogLevel: 2", 1, true) ~= nil, "add_app: rest preserved")

  local out2, st2 = mp.add_additional_app(out, 222)
  eq(st2, "already_present", "add_app: idempotent on duplicate")

  local out3, st3 = mp.add_additional_app("LogLevel: 2\n", 333)
  eq(st3, "added", "add_app: creates block when absent")
  check(out3:find("AdditionalApps:", 1, true) ~= nil, "add_app: block header created")
  check(out3:find("- 333", 1, true) ~= nil, "add_app: appid in new block")

  local _, st4 = mp.add_additional_app("AdditionalApps: [1, 2]\n", 444)
  eq(st4, "inline_refused", "add_app: refuses inline-list form")
end

-- ── 14. ImportLuaFull: load a .lua for a game NOT added via LuaTools ───────
-- Writes the .lua to stplug-in/<appid>.lua (depot keys), registers the appid
-- in AdditionalApps, and applies the setManifestid pins (if any) in ONE atomic
-- config write. appid comes from the .lua's base; a card appid must match it.
do
  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local stplug = root .. "/stplug-in"; mkdir(stplug)
  local cfg = root .. "/config.yaml"
  local cf = assert(io.open(cfg, "wb"))
  cf:write("AdditionalApps:\n  - 555\nLogLevel: 2\n"); cf:close()
  local ctx = { config_path = cfg, stplug_dir = stplug }

  local lua = table.concat({
    "addappid(3357650)",
    'addappid(3357651, 1, "key1")',
    'setManifestid(3357651, "2417499809052404547")',
  }, "\n")

  local res = json.decode(mp.import_lua_full_rpc(ctx, json.encode({ lua = lua })))
  eq(res.success, true, "full: success")
  eq(res.appid, 3357650, "full: base appid detected from .lua")
  eq(res.pinned, 1, "full: one depot pinned")

  local lf = io.open(stplug .. "/3357650.lua", "rb")
  check(lf ~= nil, "full: .lua written to stplug-in")
  if lf then local c = lf:read("*a"); lf:close()
    check(c:find("3357651", 1, true) ~= nil, "full: .lua content written verbatim") end

  local rf = assert(io.open(cfg, "rb")); local body = rf:read("*a"); rf:close()
  check(body:find("- 3357650", 1, true) ~= nil, "full: appid added to AdditionalApps")
  check(body:find("- 555", 1, true) ~= nil, "full: existing AdditionalApps kept")
  local pins = mp.parse_pins(body)
  check(pins[3357650] ~= nil and pins[3357650].locked == true, "full: app locked to build")
  eq(pins[3357650].depots[3357651], "2417499809052404547", "full: depot pinned")

  -- a .lua with NO setManifestid still imports the game (pinned=0, unlocked):
  -- the §3.3 "not installed yet" path installs at latest.
  local lua2 = "addappid(777)\naddappid(778,1,\"k\")\n"
  local res2 = json.decode(mp.import_lua_full_rpc(ctx, json.encode({ lua = lua2 })))
  eq(res2.success, true, "full: no-pin .lua still imports")
  eq(res2.pinned, 0, "full: zero pins reported")
  local rf2 = assert(io.open(cfg, "rb")); local body2 = rf2:read("*a"); rf2:close()
  check(body2:find("- 777", 1, true) ~= nil, "full: no-pin game added to AdditionalApps")
  check(mp.parse_pins(body2)[777] == nil, "full: no-pin game left unlocked")

  -- guard: a card-supplied appid must equal the .lua's base.
  local bad = json.decode(mp.import_lua_full_rpc(ctx, json.encode({ appid = 999999, lua = lua })))
  eq(bad.success, false, "full: rejects appid != .lua base")

  os.execute("rm -rf '" .. root .. "'")
end

-- ── 15. InspectLua: read-only pre-check for the Load-.lua flow ────────────
-- The top "Load .lua" button must decide between a plain import and the
-- reinstall-confirm modal BEFORE writing anything, so it needs the .lua's base
-- appid and whether the game is currently installed (appmanifest present).
do
  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end
  local root = os.tmpname(); os.remove(root); mkdir(root)
  mkdir(root .. "/steamapps")
  local cfg = root .. "/config.yaml"
  local cf = assert(io.open(cfg, "wb")); cf:write("AdditionalApps:\n  - 1\n"); cf:close()
  local ctx = { config_path = cfg, steam_root = root,
                stplug_dir = root .. "/stplug-in", manifests_dir = root .. "/manifests" }

  local lua = 'addappid(700)\naddappid(701,1,"k")\nsetManifestid(701,"900")\n'

  local r1 = json.decode(mp.inspect_lua_rpc(ctx, json.encode({ lua = lua })))
  eq(r1.success, true, "inspect: success")
  eq(r1.appid, 700, "inspect: appid from .lua base")
  eq(r1.installed, false, "inspect: not installed yet")
  eq(r1.pinned, 1, "inspect: pin count")
  eq(r1.alreadyOnBuild, false, "inspect: not-installed -> not alreadyOnBuild")

  -- installed at the SAME gid the .lua pins -> alreadyOnBuild
  local af = assert(io.open(root .. "/steamapps/appmanifest_700.acf", "wb"))
  af:write('"AppState"\n{\n\t"InstalledDepots"\n\t{\n\t\t"701"\n\t\t{\n\t\t\t"manifest"\t\t"900"\n\t\t}\n\t}\n}\n')
  af:close()
  local r2 = json.decode(mp.inspect_lua_rpc(ctx, json.encode({ lua = lua })))
  eq(r2.installed, true, "inspect: installed when appmanifest present")
  eq(r2.alreadyOnBuild, true, "inspect: installed gid matches the .lua pin -> alreadyOnBuild")

  -- installed at a DIFFERENT gid -> a real build change, not alreadyOnBuild
  local af2 = assert(io.open(root .. "/steamapps/appmanifest_700.acf", "wb"))
  af2:write('"AppState"\n{\n\t"InstalledDepots"\n\t{\n\t\t"701"\n\t\t{\n\t\t\t"manifest"\t\t"999"\n\t\t}\n\t}\n}\n')
  af2:close()
  local r3 = json.decode(mp.inspect_lua_rpc(ctx, json.encode({ lua = lua })))
  eq(r3.installed, true, "inspect: still installed (different gid)")
  eq(r3.alreadyOnBuild, false, "inspect: installed gid differs from pin -> build change")

  check(io.open(root .. "/stplug-in/700.lua", "rb") == nil, "inspect: read-only (no .lua written)")

  local rb = json.decode(mp.inspect_lua_rpc(ctx, json.encode({ lua = "-- nothing\n" })))
  eq(rb.success, false, "inspect: errors when no appid in .lua")

  os.execute("rm -rf '" .. root .. "'")
end

-- ── 16. drop_installed_depot (Approach A: pure appmanifest .acf transform) ──
-- Removing the base content depot from InstalledDepots makes Steam plan a FRESH
-- install of that depot at the pinned gid (the content mechanism a pin alone
-- can't provide, per HANDOFF v2 §8/§9). Pure text transform only; whether/how to
-- flip StateFlags and the live download behavior (delta vs full ~35 GB) are
-- validated separately on a real install — this never edits a live .acf itself.
do
  local acf = table.concat({
    '"AppState"', "{",
    '\t"appid"\t\t"3357650"',
    '\t"StateFlags"\t\t"4"',
    '\t"InstalledDepots"', "\t{",
    '\t\t"3357651"', "\t\t{",
    '\t\t\t"manifest"\t\t"6330832861176696160"',
    '\t\t\t"size"\t\t"123"', "\t\t}",
    '\t\t"3859920"', "\t\t{",
    '\t\t\t"manifest"\t\t"4731286747379700304"', "\t\t}",
    "\t}", "}",
  }, "\n") .. "\n"

  local out, removed = mp.drop_installed_depot(acf, 3357651)
  eq(removed, true, "drop: reports removed")
  check(out:find('"3357651"', 1, true) == nil, "drop: base depot gone")
  check(out:find('"3859920"', 1, true) ~= nil, "drop: sibling depot kept")
  check(out:find('"4731286747379700304"', 1, true) ~= nil, "drop: sibling manifest kept")
  check(out:find('"InstalledDepots"', 1, true) ~= nil, "drop: block header kept")
  local blk = out:match('"InstalledDepots"%s*(%b{})')
  check(blk ~= nil, "drop: InstalledDepots still brace-balanced")
  check(blk:match('"(%d+)"%s*%b{}') == "3859920", "drop: only sibling remains")

  local out2, removed2 = mp.drop_installed_depot(acf, 999999)
  eq(removed2, false, "drop: absent depot -> no-op")
  eq(out2, acf, "drop: text unchanged when depot absent")

  -- id quoting guards against a prefix collision (335765 vs 3357651)
  local out3, removed3 = mp.drop_installed_depot(acf, 335765)
  eq(removed3, false, "drop: prefix id does not match a longer depot")
end

-- ── 17. invalidate_appinfo_cache: a pin change drops the stale provisioned
-- appinfo buffer so SLSsteam re-renders it with the new pin on next start
-- (else the build-reconcile loop recurs). ──────────────────────
do
  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end
  local function exists(p) local h = io.open(p, "rb"); if h then h:close(); return true end return false end
  local function seed(cache, id)
    for _, ext in ipairs({ "bin", "yaml" }) do
      local f = assert(io.open(cache .. "/picsbuffer_" .. id .. "." .. ext, "wb")); f:write("x"); f:close()
    end
  end
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local cache = root .. "/cache"; mkdir(cache)
  local cfg = root .. "/config.yaml"
  local cf = assert(io.open(cfg, "wb")); cf:write("AdditionalApps:\n  - 700\n"); cf:close()
  local ctx = { config_path = cfg, cache_dir = cache }

  -- direct helper removes both buffer files
  seed(cache, 700)
  check(exists(cache .. "/picsbuffer_700.bin"), "cache: buffer present before")
  mp.invalidate_appinfo_cache(ctx, 700)
  check(not exists(cache .. "/picsbuffer_700.bin"), "cache: .bin removed")
  check(not exists(cache .. "/picsbuffer_700.yaml"), "cache: .yaml removed")

  -- a pin RPC invalidates the app's buffer as part of writing the pin
  seed(cache, 700)
  mp.set_dlc_pin_rpc(ctx, json.encode({ appid = 700, depot = 701, gid = "900" }))
  check(not exists(cache .. "/picsbuffer_700.bin"), "rpc set_dlc_pin: invalidates appinfo cache")

  -- guards: nil appid / absent cache_dir are safe no-ops (no crash)
  mp.invalidate_appinfo_cache(ctx, nil)
  mp.invalidate_appinfo_cache({}, 700)
  check(true, "cache: nil appid / absent cache_dir is a safe no-op")

  os.execute("rm -rf '" .. root .. "'")
end

if fails == 0 then print("\ntest_manifestpins: ALL PASS") else
  print("\ntest_manifestpins: " .. fails .. " FAILED"); os.exit(1)
end
