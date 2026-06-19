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

if fails == 0 then print("\ntest_manifestpins: ALL PASS") else
  print("\ntest_manifestpins: " .. fails .. " FAILED"); os.exit(1)
end
