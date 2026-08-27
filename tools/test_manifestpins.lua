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
local function test_manifest(depot, gid, created)
  local function section(magic, body)
    return string.pack("<I4I4", magic, #body) .. body
  end
  local metadata = "\x08" .. varint(depot) .. "\x10" .. varint(tonumber(gid))
    .. "\x18" .. varint(created)
  return section(0x71F617D0, "payload") .. section(0x1F4812BE, metadata)
    .. string.pack("<I4", 0x32C415AB)
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

-- ── 2a. Lua identity resolution ────────────────────────────────────────────
do
  local key = string.rep("a", 64)
  local luie = table.concat({
    "-- Generated with Luie",
    "-- 3321460 - Crimson Desert",
    'addappid(3321460, 1, "' .. key .. '")',
    'addappid(3321461, 1, "' .. string.rep("b", 64) .. '")',
    "setManifestid(3321461, \"3181503578355214830\")",
    "addappid(4024620)",
    "addappid(4572870)",
  }, "\n")
  local by_name, name_err = mp.resolve_lua_identity(luie, {
    filename = "3321460 (1).lua",
  })
  check(by_name ~= nil and name_err == nil, "identity: Luie file resolves")
  eq(by_name and by_name.base, 3321460, "identity: filename stem wins over bare DLCs")
  eq(by_name and by_name.source, "filename", "identity: filename is recorded as source")
  local dlcs = {}
  for _, id in ipairs(by_name and by_name.dlc_appids or {}) do dlcs[id] = true end
  check(dlcs[4024620] and dlcs[4572870],
    "identity: bare DLC apps remain children of the keyed base")

  local keyed, keyed_err = mp.resolve_lua_identity(
    'addappid(701, 1, "' .. key .. '")', {})
  check(keyed ~= nil and keyed_err == nil, "identity: single keyed depot is accepted")
  eq(keyed and keyed.base, 701, "identity: single keyed declaration is the safe base")
  eq(keyed and keyed.source, "keyed", "identity: keyed source is recorded")

  local mismatch, mismatch_err = mp.resolve_lua_identity(luie, {
    filename = "4024620.lua",
  })
  check(mismatch == nil and tostring(mismatch_err):find("conflicting", 1, true) ~= nil,
    "identity: conflicting filename cannot turn a DLC into the base")

  local ambiguous, ambiguous_err = mp.resolve_lua_identity(table.concat({
    "addappid(900)",
    'addappid(901, 1, "' .. key .. '")',
    'addappid(902, 1, "' .. string.rep("c", 64) .. '")',
  }, "\n"), {})
  check(ambiguous == nil and tostring(ambiguous_err):find("ambiguous", 1, true) ~= nil,
    "identity: multiple keyed candidates without a hint are rejected")
end

-- ── 2b. imported Lua merge + creator output ────────────────────────────────
do
  local existing = table.concat({
    "addappid(700)",
    "addappid(702)",
    'addappid(701,1,"' .. string.rep("a", 64) .. '")',
  }, "\n")
  local incoming = table.concat({
    "addappid(700)",
    "addappid(703)",
    'setManifestid(701,"9001")',
  }, "\n")
  local merged, merr = mp.merge_lua_text(700, existing, incoming)
  check(merged ~= nil and merr == nil, "merge lua: valid sources merge")
  local parsed = mp.parse_lua(merged or "")
  check(parsed.depots[701] and parsed.depots[701].key == string.rep("a", 64),
    "merge lua: source key survives")
  eq(parsed.depots[701].manifestid, "9001", "merge lua: imported pin survives")
  local dlc = {}; for _, id in ipairs(parsed.dlc_appids) do dlc[id] = true end
  check(dlc[702] and dlc[703], "merge lua: DLC declarations are unioned")

  local draft, derr = mp.build_draft_lua({
    appid = 700, dlc_appids = { 703, 702, 703 },
    pins = { { depot = 701, gid = "9001" }, { depot = 704, gid = "" } },
  })
  check(draft ~= nil and derr == nil, "draft: valid request emits Lua")
  local dp = mp.parse_lua(draft or "")
  eq(dp.base, 700, "draft: base app declared")
  eq(dp.depots[701].manifestid, "9001", "draft: non-empty manifest is pinned")
  check(dp.depots[704] == nil, "draft: empty manifest means latest, no pin emitted")
  local ordered = (draft or ""):find("addappid%(702%)") < (draft or ""):find("addappid%(703%)")
  check(ordered, "draft: DLC appids are deduplicated and sorted")
  local bad = mp.build_draft_lua({ appid = 700, pins = { { depot = "../1", gid = "2" } } })
  check(bad == nil, "draft: malformed depot is rejected")

  local inert_key = string.rep("f", 64)
  local strict, strict_err = mp.merge_lua_text(700, table.concat({
    "addappid(700)",
    '-- addappid(701,1,"' .. inert_key .. '")',
    'print("addappid(702)")',
    '-- setManifestid(701,"9002")',
  }, "\n"))
  check(strict ~= nil and strict_err == nil
    and not strict:find("701", 1, true) and not strict:find("702", 1, true)
    and not strict:find("9002", 1, true),
    "merge lua: comments and string contents remain inert")
  local comments_only = mp.merge_lua_text(700, '-- addappid(700)\nprint("addappid(700)")\n')
  check(comments_only == nil, "merge lua: commented or embedded base declaration is rejected")

  local long_blocks = mp.merge_lua_text(700, table.concat({
    "--[[",
    "addappid(700)",
    'addappid(701,1,"' .. inert_key .. '")',
    "]]",
    "[=[",
    "addappid(702)",
    'setManifestid(701,"9003")',
    "]=]",
  }, "\n"))
  check(long_blocks == nil,
    "merge lua: declarations inside multiline comments and strings remain inert")

  local code_after_blocks = mp.merge_lua_text(700, table.concat({
    "--[=[ ignored",
    "addappid(999)",
    "]=] addappid(700)",
    "[==[addappid(998)]==] addappid(703)",
  }, "\n"))
  check(code_after_blocks ~= nil
    and code_after_blocks:find("addappid(700)", 1, true)
    and code_after_blocks:find("addappid(703)", 1, true)
    and not code_after_blocks:find("999", 1, true)
    and not code_after_blocks:find("998", 1, true),
    "merge lua: parsing resumes after long-block terminators")

  local overflow_draft = mp.build_draft_lua({
    appid = 700, pins = { { depot = 701, gid = "18446744073709551616" } },
  })
  check(overflow_draft == nil, "draft: manifest gid above uint64 is rejected")
end

-- ── 2c. reimport pin replacement and ownership validation ─────────────────
do
  local key = string.rep("d", 64)
  local old = table.concat({
    "addappid(700)",
    'addappid(701,1,"' .. key .. '")',
    'setManifestid(701,"9000")',
    'setManifestid(702,"9002")',
  }, "\n")
  local incoming = table.concat({
    "addappid(700)",
    "addappid(703)",
    'setManifestid(701,"9001")',
  }, "\n")
  local replaced, replace_err = mp.merge_lua_text_replacing_pins(700, old, incoming)
  check(replaced ~= nil and replace_err == nil, "reimport: existing keys and DLCs merge")
  local rp = mp.parse_lua(replaced or "")
  eq(rp.depots[701] and rp.depots[701].manifestid, "9001",
    "reimport: incoming pin replaces the old gid")
  check(rp.depots[702] == nil or rp.depots[702].manifestid == nil,
    "reimport: omitted old pin does not survive")
  local rdlc = {}; for _, id in ipairs(rp.dlc_appids) do rdlc[id] = true end
  check(rdlc[703], "reimport: useful new DLC declaration survives")

  local collision = mp.inspect_import_entries({
    { name = "100.lua", data = 'addappid(100)\naddappid(900,1,"' .. key .. '")\n' },
    { name = "200.lua", data = 'addappid(200)\naddappid(900,1,"' .. string.rep("e", 64) .. '")\n' },
  })
  check(collision == nil, "ownership: one non-shared depot cannot belong to two apps")

  local shared = mp.inspect_import_entries({
    { name = "100.lua", data = 'addappid(100)\naddappid(228989,1,"' .. key .. '")\n' },
    { name = "200.lua", data = 'addappid(200)\naddappid(228989,1,"' .. key .. '")\n' },
  })
  check(shared ~= nil, "ownership: known Steam runtime depot can be shared")
  local conflicting_shared = mp.inspect_import_entries({
    { name = "100.lua", data = 'addappid(100)\naddappid(228989,1,"' .. key .. '")\n' },
    { name = "200.lua", data = 'addappid(200)\naddappid(228989,1,"'
      .. string.rep("e", 64) .. '")\n' },
  })
  check(conflicting_shared == nil,
    "ownership: even known shared depots reject incompatible keys")

  local compatible = mp.inspect_import_entries({
    { name = "212630.lua", data = 'addappid(212630)\naddappid(1716751,1,"' .. key .. '")\n' },
    { name = "233270.lua", data = 'addappid(233270)\naddappid(1716751,1,"' .. key .. '")\n' },
  })
  check(compatible ~= nil,
    "ownership: matching depot claims can be shared without a hardcoded id")
  local orphan = mp.parse_lua('addappid(800)\nsetManifestid(801,"9001")\n')
  local orphan_ok, orphan_errors = mp.validate_import_pins(orphan, {})
  check(orphan_ok == false and #orphan_errors > 0,
    "pins: an unkeyed, unarchived depot pin is rejected")
  local archived_ok = mp.validate_import_pins(orphan, { ["801_9001"] = true })
  check(archived_ok == true, "pins: an uploaded/archived manifest can authorize a keyless pin")
end

-- ── 2d. strict binary manifest metadata ────────────────────────────────────
do
  local function section(magic, body)
    return string.pack("<I4I4", magic, #body) .. body
  end
  local depot, gid, created = 311211, "18446744073709551610", 1700000000
  local function decimal_varint(text)
    local digits = {}; for c in text:gmatch(".") do digits[#digits + 1] = tonumber(c) end
    local out = {}
    repeat
      local next_digits, rem, started = {}, 0, false
      for _, digit in ipairs(digits) do
        local value = rem * 10 + digit
        local q = math.floor(value / 128); rem = value % 128
        if q ~= 0 or started then next_digits[#next_digits + 1] = q; started = true end
      end
      digits = next_digits
      out[#out + 1] = rem
    until #digits == 0
    for i = 1, #out - 1 do out[i] = out[i] | 0x80 end
    return string.char(table.unpack(out))
  end
  local metadata = "\x08" .. varint(depot)
    .. "\x10" .. decimal_varint(gid) .. "\x18" .. varint(created)
  local bytes = section(0x71F617D0, "payload")
    .. section(0x1F4812BE, metadata) .. string.pack("<I4", 0x32C415AB)
  local meta, err = mp.parse_manifest(bytes)
  check(meta ~= nil and err == nil, "manifest: valid Steam sections accepted")
  eq(meta.depot, depot, "manifest: depot comes from metadata")
  eq(meta.gid, gid, "manifest: uint64 gid stays exact decimal text")
  eq(meta.creation_time, created, "manifest: creation time parsed")
  local no_terminal = section(0x71F617D0, "payload") .. section(0x1F4812BE, metadata)
  check(mp.parse_manifest(no_terminal) ~= nil,
    "manifest: valid stream without optional terminal marker accepted")
  local mismatch = mp.parse_manifest(bytes, depot + 1, gid)
  check(mismatch == nil, "manifest: expected depot mismatch rejected")
  local named = mp.inspect_import_entries({ { name = "wrong-name.manifest", data = bytes } })
  check(named and named.manifests[1].name == depot .. "_" .. gid .. ".manifest",
    "import inspect: canonical manifest name is content-derived")

  local overflow_gid = "18446744073709551616"
  local overflow_metadata = "\x08" .. varint(depot)
    .. "\x10" .. decimal_varint(overflow_gid) .. "\x18" .. varint(created)
  local overflow_bytes = section(0x71F617D0, "payload")
    .. section(0x1F4812BE, overflow_metadata) .. string.pack("<I4", 0x32C415AB)
  check(mp.parse_manifest(overflow_bytes) == nil,
    "manifest: gid above uint64 is rejected")

  local conflicting = mp.inspect_import_entries({
    { name = "first.manifest", data = bytes },
    { name = "second.manifest", data = section(0x71F617D0, "different payload")
      .. section(0x1F4812BE, metadata) .. string.pack("<I4", 0x32C415AB) },
  })
  check(conflicting == nil,
    "import inspect: conflicting bytes for one depot and gid are rejected")
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

-- ── 8a. ImportLuaFull rollback before publication ──────────────────────────
do
  local root = os.tmpname(); os.remove(root)
  os.execute("mkdir -p '" .. root .. "/stplug-in'")
  local old_path = root .. "/stplug-in/812.lua"
  local old_lua = "addappid(812)\n"
  local old_file = assert(io.open(old_path, "wb")); old_file:write(old_lua); old_file:close()
  local ctx = {
    config_path = root .. "/missing/config.yaml",
    stplug_dir = root .. "/stplug-in",
    manifests_dir = root .. "/manifests",
  }
  local incoming = 'addappid(812,1,"' .. string.rep("a", 64) .. '")\n'
  local result = json.decode(mp.import_lua_full_rpc(ctx, json.encode({
    appid = 812, lua = incoming,
  })))
  check(result.success == false,
    "ImportLuaFull: missing config rejects the transaction")
  local after_handle = assert(io.open(old_path, "rb"))
  local after_file = after_handle:read("*a"); after_handle:close()
  check(after_file == old_lua,
    "ImportLuaFull: failed config validation leaves the old Lua untouched")
  os.remove(old_path); os.execute("rmdir '" .. root .. "/stplug-in' 2>/dev/null")
  os.execute("rmdir '" .. root .. "' 2>/dev/null")
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

-- ── 8f. local appinfo depot metadata + history-depot selection ───────────
do
  local pragmata = table.concat({
    '"appinfo"', '{',
    '  "appid" "3357650"',
    '  "common" { "name" "PRAGMATA" "oslist" "windows" }',
    '  "depots"', '  {',
    '    "228989" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }',
    '    "3357651" { "manifests" { "public" { "gid" "1" "size" "35948407599" } } }',
    '    "3357652" { "manifests" { "public" { "gid" "2" "size" "896136527" } } }',
    '    "3859920" { "dlcappid" "3859920" "manifests" { "public" { "gid" "3" "size" "90058268" } } }',
    '    "3859930" { "dlcappid" "3859930" "manifests" { "public" { "gid" "4" "size" "298857949" } } }',
    '    "branches" { "public" { "buildid" "23443442" } }',
    '  }',
    '}',
  }, "\n")
  local meta = mp.parse_appinfo_metadata(pragmata)
  eq(meta.name, "PRAGMATA", "appinfo: game name parsed")
  eq(meta.depots[3357651].kind, "base", "appinfo: main content is base")
  eq(meta.depots[3357651].oslist, "windows",
    "appinfo: depot without config inherits the game's platform")
  eq(meta.depots[3859930].kind, "dlc", "appinfo: DLC content classified")
  eq(meta.depots[3859930].dlc_appid, 3859930, "appinfo: associated DLC AppID exposed")
  eq(meta.depots[228989].kind, "shared", "appinfo: shared runtime classified")
  eq(mp.select_history_depot(meta.depots, { [3357651] = "installed" }), 3357651,
    "history: installed PRAGMATA base content selected")

  local multiplatform = mp.parse_appinfo_metadata(table.concat({
    '"appinfo" { "common" { "name" "Example" "oslist" "windows,linux" } "depots" {',
    '"701" { "config" { "oslist" "windows" } "manifests" { "public" { "size" "900" } } }',
    '"702" { "config" { "oslist" "linux" } "manifests" { "public" { "size" "800" } } }',
    '"799" { "config" { "oslist" "macos" } "manifests" { "public" { "size" "1200" } } }',
    '} }',
  }, "\n"))
  eq(mp.select_history_depot(multiplatform.depots, { [702] = "installed" }), 702,
    "history: installed native-Linux base wins")
  eq(mp.select_history_depot(multiplatform.depots, {}), 701,
    "history: Windows base is the Linux/Proton fallback when not installed")
  eq(mp.select_history_depot(multiplatform.depots, {}, { [702] = true }), 702,
    "history: only a base depot with archived manifests can represent builds")
  check(mp.select_history_depot(multiplatform.depots, {}, { [999] = true }) == nil,
    "history: DLC-only or unrelated archives never become the game timeline")
  check(mp.parse_appinfo_metadata("").available == false,
    "appinfo: missing cache produces an explicit unavailable fallback")
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
  local manifest_scans = 0
  local indexed_ctx = {}
  for k, v in pairs(ctx) do indexed_ctx[k] = v end
  indexed_ctx.list_manifest_names = function()
    manifest_scans = manifest_scans + 1
    return {
      "638510_900.manifest", "638511_111.manifest", "638511_222.manifest",
      "not-a-manifest", "638511_bad.manifest",
    }
  end
  mp.build_games(indexed_ctx)
  eq(manifest_scans, 1, "build: manifest directory is indexed once for all depots")
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

  -- Appinfo metadata enriches every row and identifies the single depot whose
  -- archived manifests represent the main game timeline.
  local cache = root .. "/cache"; mkdir(cache); ctx.cache_dir = cache
  local metadata_cache = root .. "/lumen-cache"; mkdir(metadata_cache)
  ctx.metadata_cache_dir = metadata_cache
  local appinfo = assert(io.open(cache .. "/picsbuffer_638510.bin", "wb"))
  appinfo:write(table.concat({
    '"appinfo" { "common" { "name" "dotAGE" "oslist" "windows" } "depots" {',
    '"638510" { "config" { "oslist" "windows" } "manifests" { "public" { "size" "10" } } }',
    '"638511" { "config" { "oslist" "windows" } "manifests" { "public" { "size" "1000" } } }',
    '} }',
  }, "\n")); appinfo:close()
  local enriched
  for _, game in ipairs(mp.build_games(ctx)) do if game.appid == 638510 then enriched = game end end
  eq(enriched.historyDepot, 638511, "build: backend exposes authoritative history depot")
  eq(enriched.name, "dotAGE", "build: cached appinfo game name surfaced")
  local enriched_by_id = {}
  for _, dep in ipairs(enriched.depots) do enriched_by_id[dep.depot] = dep end
  eq(enriched_by_id[638511].kind, "base", "build: content row carries base kind")
  eq(enriched_by_id[638511].oslist, "windows", "build: content row carries platform")
  check(io.open(metadata_cache .. "/638510.json", "rb") == nil,
    "build cache: read-only listing does not rewrite presentation metadata")

  -- Changing a pin intentionally removes picsbuffer_<appid>.bin so SLSsteam
  -- can regenerate it. Game Updates must still retain the presentation-only
  -- depot metadata when the tab is reopened before that regeneration.
  os.remove(metadata_cache .. "/638510.json")
  mp.invalidate_appinfo_cache(ctx, 638510)
  check(io.open(cache .. "/picsbuffer_638510.bin", "rb") == nil,
    "build cache: operational appinfo buffer was invalidated")
  local metadata_file = io.open(metadata_cache .. "/638510.json", "rb")
  local metadata_body = metadata_file and metadata_file:read("*a") or nil
  if metadata_file then metadata_file:close() end
  local metadata_json = metadata_body and json.decode(metadata_body) or nil
  eq(metadata_json and metadata_json.version, 1,
    "build cache: versioned presentation metadata is persisted")
  check(metadata_body and not metadata_body:find("manifest", 1, true)
      and not metadata_body:find("key", 1, true),
    "build cache: sidecar contains no manifest IDs or content keys")
  local reopened
  for _, game in ipairs(mp.build_games(ctx)) do if game.appid == 638510 then reopened = game end end
  eq(reopened.name, "dotAGE", "build cache: game name survives appinfo invalidation")
  eq(reopened.historyDepot, 638511,
    "build cache: authoritative history depot survives appinfo invalidation")
  local reopened_by_id = {}
  for _, dep in ipairs(reopened.depots) do reopened_by_id[dep.depot] = dep end
  eq(reopened_by_id[638511].kind, "base",
    "build cache: depot classification survives appinfo invalidation")

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

  -- Fresh install: no config/stplug-in dir at all. build_games must return an
  -- empty list (the tab shows its empty state), NOT throw "cannot open ...
  -- stplug-in: No such file or directory".
  local fresh = { config_path = cfg, stplug_dir = root .. "/does-not-exist",
                  manifests_dir = mans, steam_root = root }
  local ok_fresh, games_fresh = pcall(mp.build_games, fresh)
  check(ok_fresh, "build: missing stplug-in dir does not throw")
  check(ok_fresh and #games_fresh == 0, "build: missing stplug-in dir yields no games")

  -- Game added (stplug-in has .lua files) but nothing archived yet: the
  -- manifests dir doesn't exist. build_games must not throw; every game has no
  -- archived versions so the list is empty. clear_manifests must also be safe.
  local nomans = { config_path = cfg, stplug_dir = stplug,
                   manifests_dir = root .. "/no-manifests-here", steam_root = root }
  local ok_nm, games_nm = pcall(mp.build_games, nomans)
  check(ok_nm, "build: missing manifests dir does not throw")
  check(ok_nm and #games_nm == 0, "build: missing manifests dir yields no games")
  check(pcall(mp.clear_manifests_rpc, nomans), "clear: missing manifests dir does not throw")

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

  -- clear_manifests: keeps installed (200) + pinned (100), preserves every
  -- archive whose depot is referenced by any Lua registration, and removes
  -- unreferenced spares/orphans.
  write_manifest(mans, 800, "300", 3000)  -- referenced depot: must stay
  write_manifest(mans, 801, "300", 3000)  -- unreferenced spare: removable
  local removed = mp.clear_manifests(ctx)
  check(removed >= 2, "clear: removed unreferenced spare + orphan (got " .. tostring(removed) .. ")")
  check(exists(mans .. "/800_100.manifest"), "clear: KEEPS pinned 100")
  check(exists(mans .. "/800_200.manifest"), "clear: KEEPS installed 200")
  check(exists(mans .. "/800_300.manifest"), "clear: KEEPS referenced depot archives")
  check(not exists(mans .. "/801_300.manifest"), "clear: drops unreferenced spare")
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
    'addappid(3357651, 1, "' .. string.rep("a", 64) .. '")',
    'addappid(3859920, 1, "' .. string.rep("b", 64) .. '")',
    'addappid(3859930, 1, "' .. string.rep("c", 64) .. '")',
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

-- ── 14. ImportLuaFull: load a .lua for a game NOT added via LuaTools ───────
-- Writes the .lua to stplug-in/<appid>.lua (depot keys) — the CANONICAL
-- registration slsteam-moon discovers from the filename stem — and applies the
-- setManifestid pins (if any). The appid is NOT written to config.yaml
-- AdditionalApps anymore (no mirroring); config.yaml is touched ONLY to store
-- pins. appid comes from the .lua's base; a card appid must match it.
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
    'addappid(3357651, 1, "' .. string.rep("a", 64) .. '")',
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
  check(body:find("- 3357650", 1, true) == nil, "full: appid NOT mirrored into AdditionalApps")
  check(body:find("- 555", 1, true) ~= nil, "full: existing AdditionalApps untouched")
  local pins = mp.parse_pins(body)
  check(pins[3357650] ~= nil and pins[3357650].locked == true, "full: app locked to build")
  eq(pins[3357650].depots[3357651], "2417499809052404547", "full: depot pinned")

  -- a .lua with NO setManifestid still imports the game (pinned=0, unlocked):
  -- the fallback path installs at latest. With no pins there is nothing to
  -- write to config.yaml, so it is left completely untouched.
  local lua2 = "addappid(777)\naddappid(778,1,\"" .. string.rep("b", 64) .. "\")\n"
  local res2 = json.decode(mp.import_lua_full_rpc(ctx, json.encode({ lua = lua2 })))
  eq(res2.success, true, "full: no-pin .lua still imports")
  eq(res2.pinned, 0, "full: zero pins reported")
  local lf2 = io.open(stplug .. "/777.lua", "rb")
  check(lf2 ~= nil, "full: no-pin .lua written to stplug-in")
  if lf2 then lf2:close() end
  local rf2 = assert(io.open(cfg, "rb")); local body2 = rf2:read("*a"); rf2:close()
  check(body2:find("- 777", 1, true) == nil, "full: no-pin game NOT written to AdditionalApps")
  check(mp.parse_pins(body2)[777] == nil, "full: no-pin game left unlocked")

  -- guard: a card-supplied appid must equal the .lua's base.
  local bad = json.decode(mp.import_lua_full_rpc(ctx, json.encode({ appid = 999999, lua = lua })))
  eq(bad.success, false, "full: rejects appid != .lua base")

  os.execute("rm -rf '" .. root .. "'")
end

-- ── 15. InspectLua: read-only pre-check for the Load-.lua flow ────────────
-- Recommended LuaTools installs use the same app-scoped ManifestPins contract
-- as Game Updates, but must not be marked as a manual "Import games" title.
do
  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local stplug = root .. "/stplug-in"; mkdir(stplug)
  local cfg = root .. "/config.yaml"
  local imports = root .. "/imports.txt"
  local cf = assert(io.open(cfg, "wb"))
  cf:write("AdditionalApps:\n  - 3764200\nLogLevel: 2\n"); cf:close()
  local ctx = {
    config_path = cfg,
    stplug_dir = stplug,
    imports_path = imports,
    manifests_dir = root .. "/manifests",
    steam_root = root,
    offline_path = root .. "/offline",
  }
  mkdir(ctx.manifests_dir); mkdir(root .. "/steamapps")
  local recommended_lua = table.concat({
    "-- official LuaTools manifest",
    "addappid(3764200)",
    'addappid(3764201, 1, "' .. string.rep("a", 64) .. '")',
    'setManifestid(3764201, "9166256367562763038")',
  }, "\n") .. "\n"

  local availability = mp.recommended_manifest_availability(
    ctx, 3764200, recommended_lua, root)
  check(availability.ready == false and availability.offline == false,
    "recommended: a missing exact manifest is observable while providers are online")
  local offline = assert(io.open(ctx.offline_path, "wb")); offline:write("1\n"); offline:close()
  availability = mp.recommended_manifest_availability(
    ctx, 3764200, recommended_lua, root)
  check(availability.ready == false and availability.offline == true,
    "recommended: an offline provider with a missing exact manifest requests fallback")
  local exact = test_manifest(3764201, "9166256367562763038", 1700000200)
  local exact_file = assert(io.open(
    ctx.manifests_dir .. "/3764201_9166256367562763038.manifest", "wb"))
  exact_file:write(exact); exact_file:close()
  availability = mp.recommended_manifest_availability(
    ctx, 3764200, recommended_lua, root)
  check(availability.ready == true and availability.missing == 0,
    "recommended: an exact local manifest remains usable while providers are offline")

  local ok, result = mp.install_luatools_manifest(ctx, 3764200, recommended_lua)
  check(ok == true, "recommended: Lua and pins publish atomically")
  eq(result and result.pinned, 1, "recommended: reports one pinned depot")
  local installed = io.open(stplug .. "/3764200.lua", "rb")
  check(installed ~= nil, "recommended: official Lua is installed")
  if installed then
    local body = installed:read("*a"); installed:close()
    eq(body, recommended_lua, "recommended: official Lua body is preserved")
  end
  local rf = assert(io.open(cfg, "rb")); local body = rf:read("*a"); rf:close()
  local pins = mp.parse_pins(body)
  check(pins[3764200] and pins[3764200].locked == true,
    "recommended: app is locked before Steam plans installation")
  eq(pins[3764200] and pins[3764200].depots[3764201],
    "9166256367562763038", "recommended: setManifestid becomes ManifestPins")
  check(io.open(imports, "rb") == nil,
    "recommended: title is not marked as a manual Import games entry")

  check(mp.app_at_pinned_gids(ctx, 3764200) == false,
    "recommended: automatic fix waits until the pinned build is installed")
  local acf = assert(io.open(root .. "/steamapps/appmanifest_3764200.acf", "wb"))
  acf:write('"AppState"\n{\n"InstalledDepots"\n{\n"3764201"\n{\n'
    .. '"manifest" "9166256367562763038"\n}\n}\n}\n'); acf:close()
  check(mp.app_at_pinned_gids(ctx, 3764200) == true,
    "recommended: automatic fix may run only on the exact pinned build")

  os.execute("rm -rf '" .. root .. "'")
end

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

  local lua = 'addappid(700)\naddappid(701,1,"' .. string.rep("a", 64) .. '")\nsetManifestid(701,"900")\n'

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

-- ── 16. drop_installed_depot (pure appmanifest .acf transform) ──
-- Removing the base content depot from InstalledDepots makes Steam plan a FRESH
-- install of that depot at the pinned gid. Pure text transform only; whether/how to
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

-- ── 17. Load-.lua source marker (fromLuaFile) ─────────────────────────────
-- A game added through the menu's "Load .lua" button is recorded in an imports
-- marker file so its build badge reads "from .lua" instead of "from LuaTools".
-- parse_imports is the pure reader; import_lua_full_rpc auto-marks; build_games
-- surfaces game.fromLuaFile; MarkLuaImport is the explicit RPC (from-source path).
do
  -- parse_imports: one appid per line, ignores blanks/garbage.
  local set = mp.parse_imports("700\n\n  701  \nnotanid\n700\n")
  check(set[700] == true and set[701] == true, "imports: parses appid lines")
  check(set["notanid"] == nil, "imports: ignores non-numeric lines")

  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end
  local function write_manifest(dir, depot, gid, ct)
    local pb = "\x18" .. varint(ct)
    local block = "\xBE\x12\x48\x1F" .. string.pack("<I4", #pb) .. pb
    local f = assert(io.open(dir .. "/" .. depot .. "_" .. gid .. ".manifest", "wb"))
    f:write(string.rep("\0", 64) .. block); f:close()
  end
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local stplug = root .. "/stplug-in"; local mans = root .. "/manifests"
  mkdir(stplug); mkdir(mans); mkdir(root .. "/steamapps")
  local cfg = root .. "/config.yaml"
  local imports = root .. "/lumen_lua_imports.txt"
  local cf = assert(io.open(cfg, "wb")); cf:write("AdditionalApps:\n  - 1\nLogLevel: 2\n"); cf:close()
  local ctx = { config_path = cfg, stplug_dir = stplug, manifests_dir = mans,
                steam_root = root, imports_path = imports }

  -- An imported game (via import_lua_full_rpc) gets marked; a DB-added game
  -- (written straight to stplug-in) does not.
  local imported_lua = 'addappid(900)\naddappid(901,0,"' .. string.rep("a", 64) .. '")\nsetManifestid(901,"111")\n'
  local res = json.decode(mp.import_lua_full_rpc(ctx, json.encode({ lua = imported_lua })))
  eq(res.success, true, "imports: import_lua_full succeeds")
  write_manifest(mans, 901, "111", 1700000000)

  -- a DB-added game: just drop its .lua + manifest, never imported.
  local dbf = assert(io.open(stplug .. "/800.lua", "wb"))
  dbf:write('addappid(800)\naddappid(802,0,"k")\nsetManifestid(802,"222")\n'); dbf:close()
  write_manifest(mans, 802, "222", 1700000000)

  local imp_set = mp.parse_imports(io.open(imports, "rb"):read("*a"))
  check(imp_set[900] == true, "imports: import_lua_full marked appid 900")
  check(imp_set[800] == nil, "imports: DB-added appid 800 not marked")

  local games = mp.build_games(ctx)
  local g900, g800
  for _, g in ipairs(games) do
    if g.appid == 900 then g900 = g elseif g.appid == 800 then g800 = g end
  end
  check(g900 and g900.fromLuaFile == true, "build: imported game has fromLuaFile=true")
  check(g800 and g800.fromLuaFile == false, "build: DB-added game has fromLuaFile=false")

  -- MarkLuaImport RPC marks a from-source add (no ImportLuaFull involved).
  local mres = json.decode(mp.mark_lua_import_rpc(ctx, json.encode({ appid = 800 })))
  eq(mres.success, true, "imports: MarkLuaImport succeeds")
  local imp_set2 = mp.parse_imports(io.open(imports, "rb"):read("*a"))
  check(imp_set2[800] == true, "imports: MarkLuaImport marked appid 800")
  -- idempotent: marking again doesn't duplicate / error.
  eq(json.decode(mp.mark_lua_import_rpc(ctx, json.encode({ appid = 800 }))).success, true,
     "imports: MarkLuaImport is idempotent")

  os.execute("rm -rf '" .. root .. "'")
end

-- ── 18. transactional mixed-file / ZIP importer ───────────────────────────
do
  local function mkdir(path) assert(os.execute("mkdir -p '" .. path .. "'") == true) end
  local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local data = f:read("*a"); f:close(); return data
  end
  local function section(magic, body) return string.pack("<I4I4", magic, #body) .. body end
  local function manifest(depot, gid, created)
    local metadata = "\x08" .. varint(depot) .. "\x10" .. varint(tonumber(gid))
      .. "\x18" .. varint(created)
    return section(0x71F617D0, "payload") .. section(0x1F4812BE, metadata)
      .. string.pack("<I4", 0x32C415AB)
  end
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local ctx = {
    config_path = root .. "/config.yaml", stplug_dir = root .. "/stplug-in",
    manifests_dir = root .. "/manifests", cache_dir = root .. "/cache",
    imports_path = root .. "/imports.txt", steam_root = root,
    import_root = root .. "/uploads",
  }
  mkdir(ctx.stplug_dir); mkdir(ctx.manifests_dir); mkdir(ctx.cache_dir)
  local cfg = assert(io.open(ctx.config_path, "wb")); cfg:write("AdditionalApps:\nLogLevel: 2\n"); cfg:close()
  local current = assert(io.open(ctx.stplug_dir .. "/700.lua", "wb"))
  current:write('addappid(700)\naddappid(701,1,"' .. string.rep("a", 64) .. '")\n')
  current:close()

  local lua_data = 'addappid(700)\naddappid(702)\nsetManifestid(701,"9001")\n'
  local man_data = manifest(701, "9001", 1700000000)
  local begin = json.decode(mp.begin_game_import_rpc(ctx, json.encode({ files = {
    { name = "game.lua", size = #lua_data },
    { name = "renamed.manifest", size = #man_data },
  } })))
  check(begin.success and type(begin.session) == "string", "tx: begin allocates session")
  local session = begin.session
  local function mode(path)
    local p = io.popen("stat -c %a '" .. path .. "' 2>/dev/null")
    local value = p and p:read("*l") or nil
    if p then p:close() end
    return value
  end
  eq(mode(ctx.import_root .. "/" .. session), "700", "tx: session directory is private")
  local b64 = require("b64")
  local first = lua_data:sub(1, 17); local second = lua_data:sub(18)
  local u1 = json.decode(mp.upload_game_import_chunk_rpc(ctx, json.encode({
    session = session, file = 1, chunk = 0, data = b64.encode(first), final = false,
  })))
  check(u1.success, "tx: first ordered chunk accepted")
  eq(mode(ctx.import_root .. "/" .. session .. "/file_1"), "600",
    "tx: uploaded Lua is private")
  local wrong = json.decode(mp.upload_game_import_chunk_rpc(ctx, json.encode({
    session = session, file = 1, chunk = 2, data = b64.encode(second), final = true,
  })))
  check(not wrong.success, "tx: out-of-order chunk rejected")
  local premature = json.decode(mp.upload_game_import_chunk_rpc(ctx, json.encode({
    session = session, file = 1, chunk = 1,
    data = b64.encode(second:sub(1, 1)), final = true,
  })))
  check(not premature.success,
    "tx: premature final chunk is rejected without poisoning session")
  local u2 = json.decode(mp.upload_game_import_chunk_rpc(ctx, json.encode({
    session = session, file = 1, chunk = 1, data = b64.encode(second), final = true,
  })))
  local u3 = json.decode(mp.upload_game_import_chunk_rpc(ctx, json.encode({
    session = session, file = 2, chunk = 0, data = b64.encode(man_data), final = true,
  })))
  check(u2.success and u3.success, "tx: remaining chunks accepted")

  local prep = json.decode(mp.prepare_game_import_rpc(ctx, json.encode({ session = session })))
  check(prep.success and #prep.apps == 1 and #prep.manifests == 1,
    "tx: prepare inspects mixed Lua and manifest")
  eq(prep.apps[1].appid, 700, "tx: prepared appid")
  eq(prep.manifests[1].depot, 701, "tx: manifest metadata drives depot")
  check(read(ctx.manifests_dir .. "/701_9001.manifest") == nil,
    "tx: prepare publishes nothing")

  local committed = json.decode(mp.commit_game_import_rpc(ctx, json.encode({ session = session })))
  check(committed.success and committed.apps == 1 and committed.manifests == 1,
    "tx: commit publishes complete batch")
  check(read(ctx.manifests_dir .. "/701_9001.manifest") == man_data,
    "tx: manifest archived under canonical name")
  local installed_lua = read(ctx.stplug_dir .. "/700.lua") or ""
  check(installed_lua:find(string.rep("a", 64), 1, true) ~= nil,
    "tx: existing source key is preserved")
  check(installed_lua:find('setManifestid(701,"9001")', 1, true) ~= nil,
    "tx: imported pin is merged")
  local pins = mp.parse_pins(read(ctx.config_path) or "")
  eq(pins[700].depots[701], "9001", "tx: matching manifest pin persisted")

  -- A second, keys-incomplete Lua is enriched inside its private upload
  -- session. Prepare remains read-only and Commit publishes the source key
  -- under the uploaded manifest choice.
  local incomplete = 'addappid(750)\nsetManifestid(751,"7501")\n'
  local eb = json.decode(mp.begin_game_import_rpc(ctx, json.encode({ files = {
    { name = "750.lua", size = #incomplete },
  } })))
  local eu = json.decode(mp.upload_game_import_chunk_rpc(ctx, json.encode({
    session = eb.session, file = 1, chunk = 0, data = b64.encode(incomplete), final = true,
  })))
  check(eu.success, "enrich: incomplete Lua upload accepted")
  local source_lua = 'addappid(750)\naddappid(752)\naddappid(751,1,"'
    .. string.rep("c", 64) .. '")\n'
  local source_manifest = manifest(751, "7501", 1700000100)
  local enriched, enrich_result = mp.enrich_game_import_snapshot(
    ctx, eb.session, 750, {
      lua = source_lua,
      manifests = { { name = "source.manifest", data = source_manifest } },
    })
  check(enriched and enrich_result.manifests == 1,
    "enrich: validated source snapshot attached to private session")
  local ep = json.decode(mp.prepare_game_import_rpc(ctx, json.encode({ session = eb.session })))
  check(ep.success and ep.apps[1].keys == 1 and ep.apps[1].pins == 1
      and #ep.manifests == 1,
    "enrich: prepare sees source key, uploaded pin, and source manifest")
  check(read(ctx.stplug_dir .. "/750.lua") == nil,
    "enrich: source lookup publishes nothing before commit")
  local ec = json.decode(mp.commit_game_import_rpc(ctx, json.encode({ session = eb.session })))
  local enriched_lua = read(ctx.stplug_dir .. "/750.lua") or ""
  check(ec.success and enriched_lua:find(string.rep("c", 64), 1, true) ~= nil,
    "enrich: commit publishes missing source key")
  check(enriched_lua:find('setManifestid(751,"7501")', 1, true) ~= nil,
    "enrich: uploaded manifest choice wins")
  check(read(ctx.manifests_dir .. "/751_7501.manifest") == source_manifest,
    "enrich: commit preserves the source manifest bytes")

  -- The creator's blank GID means Latest even when the app was previously
  -- locked. SyncGamePins must remove that old YAML entry, not merely omit a new
  -- setManifestid line.
  local latest = json.decode(mp.sync_game_pins_rpc(ctx, json.encode({
    appid = 750, lua = 'addappid(750)\naddappid(751,1,"' .. string.rep("c", 64) .. '")\n',
  })))
  local latest_pins = mp.parse_pins(read(ctx.config_path) or "")
  check(latest.success and latest.pinned == 0 and latest_pins[750] == nil,
    "creator: blank manifests clear an older pin and restore Latest")

  local zip_src = root .. "/zip-src"; mkdir(zip_src .. "/nested")
  local zlua = assert(io.open(zip_src .. "/nested/800.lua", "wb"))
  zlua:write('addappid(800)\naddappid(801,1,"' .. string.rep("b", 64) .. '")\n'); zlua:close()
  local zman_data = manifest(801, "8001", 1800000000)
  local zman = assert(io.open(zip_src .. "/nested/anything.manifest", "wb")); zman:write(zman_data); zman:close()
  assert(os.execute("cd '" .. zip_src .. "' && zip -qr '" .. root .. "/bundle.zip' nested") == true)
  local zip_data = assert(read(root .. "/bundle.zip"))
  local zb = json.decode(mp.begin_game_import_rpc(ctx, json.encode({ files = {
    { name = "bundle.zip", size = #zip_data },
  } })))
  local zu = json.decode(mp.upload_game_import_chunk_rpc(ctx, json.encode({
    session = zb.session, file = 1, chunk = 0, data = b64.encode(zip_data), final = true,
  })))
  check(zu.success, "zip: archive upload accepted")
  local zp = json.decode(mp.prepare_game_import_rpc(ctx, json.encode({ session = zb.session })))
  check(zp.success and #zp.apps == 1 and #zp.manifests == 1,
    "zip: nested Lua and manifest are safely discovered")
  check(zp.apps[1].needsEnrichment == false,
    "zip: a Lua whose depot claims all have keys is already complete")
  local zc = json.decode(mp.commit_game_import_rpc(ctx, json.encode({ session = zb.session })))
  check(zc.success and read(ctx.stplug_dir .. "/800.lua") ~= nil
    and read(ctx.manifests_dir .. "/801_8001.manifest") == zman_data,
    "zip: inspected package commits")

  -- A library-sized package must be governed by byte and archive-safety
  -- limits, not the old 512-entry ceiling. Repeated compatible depot claims
  -- are common for publisher runtimes such as Ubisoft Connect.
  local bulk_src = root .. "/bulk-src"; mkdir(bulk_src)
  local bulk_key = string.rep("d", 64)
  for index = 1, 1000 do
    local appid = 900000 + index
    local file = assert(io.open(bulk_src .. "/" .. appid .. ".lua", "wb"))
    file:write("addappid(" .. appid .. ")\naddappid(1716751,1,\""
      .. bulk_key .. "\")\n")
    file:close()
  end
  assert(os.execute("cd '" .. bulk_src .. "' && zip -q '" .. root
    .. "/bulk.zip' ./*.lua") == true)
  local bulk_data = assert(read(root .. "/bulk.zip"))
  local bb = json.decode(mp.begin_game_import_rpc(ctx, json.encode({ files = {
    { name = "bulk.zip", size = #bulk_data },
  } })))
  check(bb.success, "bulk zip: private session accepts one archive")
  local offset, chunk = 1, 0
  while offset <= #bulk_data do
    local last = math.min(offset + 192 * 1024 - 1, #bulk_data)
    local upload = json.decode(mp.upload_game_import_chunk_rpc(ctx, json.encode({
      session = bb.session, file = 1, chunk = chunk,
      data = b64.encode(bulk_data:sub(offset, last)), final = last == #bulk_data,
    })))
    check(upload.success, "bulk zip: ordered archive chunk accepted")
    offset, chunk = last + 1, chunk + 1
  end
  local bp = json.decode(mp.prepare_game_import_rpc(ctx, json.encode({ session = bb.session })))
  check(bp.success and #bp.apps == 1000,
    "bulk zip: 1000 compatible Lua files are inspected as one batch")
  check(bp.success and bp.apps[1].needsEnrichment == false,
    "bulk zip: complete Lua files need no remote source enrichment")

  os.execute("rm -rf '" .. root .. "'")
end

-- ── 19. remove_additional_app (pure inverse of add_additional_app) ─────────
do
  local base = "AdditionalApps:\n  - 555\n  - 700\nLogLevel: 2\n"
  local out, st = mp.remove_additional_app(base, 555)
  eq(st, "removed", "remove_app: status removed")
  check(not out:find("%- 555"), "remove_app: 555 gone")
  check(out:find("%- 700") ~= nil, "remove_app: 700 kept")
  check(out:find("LogLevel: 2") ~= nil, "remove_app: other keys kept")

  local _, st2 = mp.remove_additional_app(base, 999)
  eq(st2, "not_present", "remove_app: absent appid -> not_present")

  local _, st3 = mp.remove_additional_app("AdditionalApps: [1, 2]\n", 1)
  eq(st3, "inline_refused", "remove_app: inline list refused")

  -- Regression: a ZERO-indent list ("- 555" flush-left) must still be
  -- editable. The old %s+ matcher broke the loop on the first item, so removal
  -- silently reported not_present and left the id in place.
  local zbase = "AdditionalApps:\n- 555\n- 700\nLogLevel: 2\n"
  local zout, zst = mp.remove_additional_app(zbase, 555)
  eq(zst, "removed", "remove_app(zero-indent): status removed")
  check(not zout:find("%- 555"), "remove_app(zero-indent): 555 gone")
  check(zout:find("\n- 700\n") ~= nil, "remove_app(zero-indent): sibling kept")
  check(zout:find("LogLevel: 2") ~= nil, "remove_app(zero-indent): other keys kept")
end

-- ── 20. DeleteBuild / DeleteAll / clear keeps LuaTools build ───────────────
do
  local function mkdir(p) os.execute("mkdir -p '" .. p .. "'") end
  local function exists(p) local h = io.open(p, "rb"); if h then h:close(); return true end return false end
  local function write_manifest(dir, depot, gid, ct)
    local pb = "\x18" .. varint(ct)
    local block = "\xBE\x12\x48\x1F" .. string.pack("<I4", #pb) .. pb
    local f = assert(io.open(dir .. "/" .. depot .. "_" .. gid .. ".manifest", "wb"))
    f:write(string.rep("\0", 64) .. block); f:close()
  end
  local D1 = 1000000  -- day 1 (UTC midnight-aligned-ish; exact value irrelevant)
  local D2 = 1000000 + 86400 * 3
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local stplug = root .. "/stplug-in"; local mans = root .. "/manifests"
  mkdir(stplug); mkdir(mans); mkdir(root .. "/steamapps")
  local cfg = root .. "/config.yaml"
  local imports = root .. "/lumen_lua_imports.txt"
  local ctx = { config_path = cfg, stplug_dir = stplug, manifests_dir = mans,
                steam_root = root, imports_path = imports }

  -- A LuaTools game (NOT load-.lua): depot 902 pins gid "100" via setManifestid.
  local lt = assert(io.open(stplug .. "/900.lua", "wb"))
  lt:write('addappid(900)\naddappid(902,0,"k")\nsetManifestid(902,"100")\n'); lt:close()
  write_manifest(mans, 902, "100", D1)   -- the LuaTools build (kept)
  write_manifest(mans, 902, "200", D2)   -- a later staged build (deletable)
  local cf = assert(io.open(cfg, "wb")); cf:write("AdditionalApps:\n  - 900\nLogLevel: 2\n"); cf:close()

  -- DeleteBuild on the LuaTools build's day is a no-op (it's protected).
  local r1 = json.decode(mp.delete_build_rpc(ctx, json.encode({ appid = 900, date = D1 })))
  eq(r1.removed, 0, "delbuild: LuaTools build is protected (0 removed)")
  check(exists(mans .. "/902_100.manifest"), "delbuild: LuaTools manifest still on disk")

  -- DeleteBuild on the later day removes that build.
  local r2 = json.decode(mp.delete_build_rpc(ctx, json.encode({ appid = 900, date = D2 })))
  eq(r2.removed, 1, "delbuild: later build removed")
  check(not exists(mans .. "/902_200.manifest"), "delbuild: later manifest gone")

  -- DeleteAll on a LuaTools game keeps the LuaTools build, deletes the rest.
  write_manifest(mans, 902, "300", D2)   -- re-add a spare
  local r3 = json.decode(mp.delete_all_rpc(ctx, json.encode({ appid = 900 })))
  eq(r3.fullRemoval, false, "delall(lt): not a full removal")
  eq(r3.kept, 1, "delall(lt): the LuaTools build is kept")
  check(exists(mans .. "/902_100.manifest"), "delall(lt): LuaTools manifest kept")
  check(not exists(mans .. "/902_300.manifest"), "delall(lt): spare removed")
  check(exists(stplug .. "/900.lua"), "delall(lt): .lua kept (game stays)")

  -- A Load-.lua game: full removal nukes manifests + .lua + AdditionalApps + marker.
  local lf = assert(io.open(stplug .. "/950.lua", "wb"))
  lf:write('addappid(950)\naddappid(951,0,"k")\naddappid(228989,0,"k")\nsetManifestid(951,"500")\n'); lf:close()
  write_manifest(mans, 951, "500", D1)
  write_manifest(mans, 951, "600", D2)
  write_manifest(mans, 228989, "700", D1)
  -- A second registered app references the shared runtime depot. Full removal
  -- of 950 must not delete that shared archive or data owned by the other app.
  local other = assert(io.open(stplug .. "/960.lua", "wb"))
  other:write('addappid(960)\naddappid(228989,0,"k")\n'); other:close()
  local cf2 = assert(io.open(cfg, "wb")); cf2:write("AdditionalApps:\n  - 900\n  - 950\nLogLevel: 2\n"); cf2:close()
  local imf = assert(io.open(imports, "wb")); imf:write("950\n"); imf:close()

  local r4 = json.decode(mp.delete_all_rpc(ctx, json.encode({ appid = 950 })))
  eq(r4.fullRemoval, true, "delall(lua): full removal")
  eq(r4.removed, 2, "delall(lua): only the target game's two content manifests removed")
  check(not exists(mans .. "/951_500.manifest"), "delall(lua): setManifestid manifest also removed")
  check(not exists(mans .. "/951_600.manifest"), "delall(lua): spare target manifest removed")
  check(exists(mans .. "/228989_700.manifest"),
    "delall(lua): shared runtime manifest is preserved")
  check(not exists(stplug .. "/950.lua"), "delall(lua): .lua deleted")
  local cfg_after = io.open(cfg, "rb"):read("*a")
  check(not cfg_after:find("%- 950"), "delall(lua): dropped from AdditionalApps")
  check(cfg_after:find("%- 900") ~= nil, "delall(lua): other app kept in AdditionalApps")
  check(not mp.parse_imports(io.open(imports, "rb") and io.open(imports, "rb"):read("*a") or "")[950],
        "delall(lua): import marker cleared")

  -- clear_manifests keeps the LuaTools build and protects every depot still
  -- referenced by a registered Lua file; an unrelated archive remains clearable.
  write_manifest(mans, 902, "700", D2)
  write_manifest(mans, 999, "700", D2)
  local removed = select(1, mp.clear_manifests(ctx))
  check(removed >= 1, "clear: removed an unreferenced spare")
  check(exists(mans .. "/902_100.manifest"), "clear: LuaTools build kept")
  check(exists(mans .. "/902_700.manifest"), "clear: referenced depot archive kept")
  check(not exists(mans .. "/999_700.manifest"), "clear: unrelated archive removed")

  os.execute("rm -rf '" .. root .. "'")
end

-- ── 21. review regressions: lexical identity, Game Updates, full reimport,
-- and global manifest cleanup protections ──────────────────────────────────
do
  local key = string.rep("a", 64)
  local fake_header = table.concat({
    "[=[",
    "-- 999999 - fake header inside a long-bracket string",
    "]=]",
    'addappid(701,1,"' .. key .. '")',
  }, "\n")
  local resolved, identity_err = mp.resolve_lua_identity(fake_header, {})
  check(resolved ~= nil and identity_err == nil and resolved.base == 701,
    "identity: header text inside long-bracket content is ignored")
end

do
  local key = string.rep("a", 64)
  local function mkdir(path) os.execute("mkdir -p '" .. path .. "'") end
  local function write_manifest(dir, depot, gid, created)
    local pb = "\x08" .. varint(depot) .. "\x18" .. varint(created)
    local block = "\xBE\x12\x48\x1F" .. string.pack("<I4", #pb) .. pb
    local f = assert(io.open(dir .. "/" .. depot .. "_" .. gid .. ".manifest", "wb"))
    f:write(string.rep("\0", 32) .. block); f:close()
  end
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local stplug, mans = root .. "/stplug-in", root .. "/manifests"
  mkdir(stplug); mkdir(mans); mkdir(root .. "/steamapps")
  local lf = assert(io.open(stplug .. "/3321460.lua", "wb"))
  lf:write(table.concat({
    'addappid(3321460,1,"' .. key .. '")',
    'addappid(3321461,1,"' .. string.rep("b", 64) .. '")',
    "addappid(4024620)",
    "addappid(4572870)",
  }, "\n")); lf:close()
  write_manifest(mans, 3321460, "1", 1700000000)
  local cfg = assert(io.open(root .. "/config.yaml", "wb")); cfg:write("LogLevel: 2\n"); cfg:close()
  local games = mp.build_games({
    config_path = root .. "/config.yaml", stplug_dir = stplug,
    manifests_dir = mans, steam_root = root,
  })
  local dlcs = {}
  for _, id in ipairs(games[1] and games[1].dlc_appids or {}) do dlcs[id] = true end
  check(#games == 1 and dlcs[4024620] and dlcs[4572870],
    "build: keyed base keeps all bare DLC apps in Game Updates")
  os.execute("rm -rf '" .. root .. "'")
end

do
  local function mkdir(path) os.execute("mkdir -p '" .. path .. "'") end
  local key = string.rep("c", 64)
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local stplug = root .. "/stplug-in"; mkdir(stplug)
  local cfg = root .. "/config.yaml"
  local cf = assert(io.open(cfg, "wb"))
  cf:write(table.concat({
    "AdditionalApps:", "  - 700", "ManifestPins:", "  700:",
    "    locked: true", "    depots:", '      701: "9000"', "LogLevel: 2",
  }, "\n")); cf:close()
  local ctx = { config_path = cfg, stplug_dir = stplug }
  local lua = 'addappid(700)\naddappid(701,1,"' .. key .. '")\n'
  local result = json.decode(mp.import_lua_full_rpc(ctx, json.encode({
    appid = 700, lua = lua,
  })))
  local pins = mp.parse_pins(io.open(cfg, "rb"):read("*a"))
  check(result.success and result.pinned == 0 and pins[700] == nil,
    "full reimport: omitted pins clear the previous app lock")
  os.execute("rm -rf '" .. root .. "'")
end

do
  local function mkdir(path) os.execute("mkdir -p '" .. path .. "'") end
  local function write_manifest(dir, depot, gid, created)
    local pb = "\x18" .. varint(created)
    local block = "\xBE\x12\x48\x1F" .. string.pack("<I4", #pb) .. pb
    local f = assert(io.open(dir .. "/" .. depot .. "_" .. gid .. ".manifest", "wb"))
    f:write(string.rep("\0", 16) .. block); f:close()
  end
  local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
  end
  local root = os.tmpname(); os.remove(root); mkdir(root)
  local stplug, mans = root .. "/stplug-in", root .. "/manifests"
  mkdir(stplug); mkdir(mans); mkdir(root .. "/steamapps")
  local function write_lua(name, text)
    local f = assert(io.open(stplug .. "/" .. name .. ".lua", "wb")); f:write(text); f:close()
  end
  write_lua(600, 'addappid(600)\naddappid(800,0,"k")\n')
  write_lua(601, 'addappid(601)\naddappid(1000,0,"k")\n')
  write_lua(602, 'addappid(602)\naddappid(228989,0,"k")\n')
  write_manifest(mans, 800, "1", 100)
  write_manifest(mans, 1000, "1", 100)
  write_manifest(mans, 228989, "1", 100)
  local cfg = assert(io.open(root .. "/config.yaml", "wb")); cfg:write("LogLevel: 2\n"); cfg:close()
  local ctx = { config_path = root .. "/config.yaml", stplug_dir = stplug,
                manifests_dir = mans, steam_root = root }
  mp.clear_manifests(ctx)
  check(exists(mans .. "/1000_1.manifest"),
    "clear: referenced depot archives are protected globally")
  check(exists(mans .. "/228989_1.manifest"),
    "clear: shared runtime archives are protected globally")
  os.execute("rm -rf '" .. root .. "'")
end

if fails == 0 then print("\ntest_manifestpins: ALL PASS") else
  print("\ntest_manifestpins: " .. fails .. " FAILED"); os.exit(1)
end
