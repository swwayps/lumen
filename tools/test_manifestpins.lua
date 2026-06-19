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
    'addappid(638511,0,"k")',
    'setManifestid(638511,"111")',
    "addappid(999)",
  }, "\n")); lf:close()

  write_manifest(mans, 638511, "111", 100)
  write_manifest(mans, 638511, "222", 200)

  local af = assert(io.open(steamapps .. "/appmanifest_638510.acf", "wb"))
  af:write('"AppState"\n{\n\t"InstalledDepots"\n\t{\n\t\t"638511"\n\t\t{\n\t\t\t"manifest"\t\t"222"\n\t\t}\n\t}\n}\n')
  af:close()

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
  eq(#g.depots, 1, "build: one depot with archived manifests")
  local d = g.depots[1]
  eq(d.depot, 638511, "build: depot id")
  eq(#d.versions, 2, "build: two archived versions")
  eq(d.versions[1].gid, "222", "build: newest version first")
  eq(d.versions[1].date, 200, "build: newest date")
  eq(d.versions[1].installed, true, "build: 222 marked installed (from acf)")
  eq(d.versions[2].gid, "111", "build: older version second")
  eq(d.versions[2].fromLuaTools, true, "build: 111 marked fromLuaTools")
  eq(d.versions[2].pinned, true, "build: 111 marked pinned (config)")
  local dlc = {}
  for _, id in ipairs(g.dlc_appids) do dlc[id] = true end
  check(dlc[999], "build: dlc appid surfaced")
  os.execute("rm -rf '" .. root .. "'")
end

if fails == 0 then print("\ntest_manifestpins: ALL PASS") else
  print("\ntest_manifestpins: " .. fails .. " FAILED"); os.exit(1)
end
