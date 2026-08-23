-- manifestpins: backend for the Lumen settings menu's "Game Updates" tab
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
local function new_lua_parse()
  return {
    base = nil, depots = {}, dlc_appids = {}, bare_appids = {},
    keyed_appids = {}, declarations = {},
  }
end

local function record_lua_declaration(out, kind, id)
  out.declarations[#out.declarations + 1] = { kind = kind, id = id }
  if kind == "bare" then out.bare_appids[#out.bare_appids + 1] = id
  else out.keyed_appids[#out.keyed_appids + 1] = id end
end

local function finish_legacy_lua_parse(out)
  if out.bare_appids[1] then out.base = out.bare_appids[1] end
  local seen = {}
  for _, id in ipairs(out.bare_appids) do
    if id ~= out.base and not seen[id] then
      out.dlc_appids[#out.dlc_appids + 1] = id
      seen[id] = true
    end
  end
  return out
end

-- parse_lua(text) -> declarations plus the legacy first-bare base guess.
function mp.parse_lua(text)
  local out = new_lua_parse()
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local kid, kkey = line:match('addappid%s*%(%s*(%d+)%s*,%s*%d+%s*,%s*"([^"]*)"%s*%)')
    if kid then
      kid = math.tointeger(tonumber(kid))
      record_lua_declaration(out, "keyed", kid)
      out.depots[kid] = out.depots[kid] or {}
      out.depots[kid].key = kkey
    else
      local bid = line:match('addappid%s*%(%s*(%d+)%s*%)')
      if bid then record_lua_declaration(out, "bare", math.tointeger(tonumber(bid))) end
    end
    local mdepot, mgid = line:match('setManifestid%s*%(%s*(%d+)%s*,%s*"([^"]*)"')
    if mdepot then
      mdepot = math.tointeger(tonumber(mdepot))
      out.depots[mdepot] = out.depots[mdepot] or {}
      out.depots[mdepot].manifestid = mgid
    end
  end
  return finish_legacy_lua_parse(out)
end

local function lua_long_open(line, pos)
  local equals = line:sub(pos):match("^%[(=*)%[")
  if equals == nil then return nil end
  return "]" .. equals .. "]", #equals + 2
end

-- Removes comments and long bracket strings while preserving ordinary quoted
-- arguments. The returned state carries a multiline block across input lines.
local function strip_lua_non_code(line, long_close)
  local out, pos, line_comment = {}, 1, nil
  while pos <= #line do
    if long_close then
      local first, last = line:find(long_close, pos, true)
      if not first then return table.concat(out), long_close, line_comment end
      out[#out + 1] = " "
      pos, long_close = last + 1, nil
    else
      local ch = line:sub(pos, pos)
      if ch == '"' or ch == "'" then
        local quote, escaped = ch, false
        out[#out + 1] = ch
        pos = pos + 1
        while pos <= #line do
          ch = line:sub(pos, pos)
          out[#out + 1] = ch
          pos = pos + 1
          if escaped then escaped = false
          elseif ch == "\\" then escaped = true
          elseif ch == quote then break end
        end
      elseif line:sub(pos, pos + 1) == "--" then
        local close, width = lua_long_open(line, pos + 2)
        if not close then
          line_comment = line:sub(pos + 2)
          break
        end
        out[#out + 1] = " "
        long_close, pos = close, pos + 2 + width
      else
        local close, width = lua_long_open(line, pos)
        if close then
          out[#out + 1] = " "
          long_close, pos = close, pos + width
        else
          out[#out + 1] = ch
          pos = pos + 1
        end
      end
    end
  end
  return table.concat(out), long_close, line_comment
end

-- Strict data parser for files crossing an import boundary. Unlike parse_lua,
-- this never treats comments or calls embedded in strings/other expressions as
-- declarations. parse_lua remains intentionally permissive for reading legacy
-- installed LuaTools files whose build marker may be commented out.
function mp.parse_lua_strict(text)
  local out = new_lua_parse()
  local long_close = nil
  for raw in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local cleaned
    cleaned, long_close = strip_lua_non_code(raw:gsub("\r$", ""), long_close)
    local line = cleaned:match("^%s*(.-)%s*$")
    local bid = line:match("^addappid%s*%(%s*(%d+)%s*%)%s*;?%s*$")
    if bid then
      record_lua_declaration(out, "bare", math.tointeger(tonumber(bid)))
    else
      local kid, _, quote, kkey = line:match(
        "^addappid%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(['\"])([^'\"]*)%3%s*%)%s*;?%s*$")
      if kid then
        kid = math.tointeger(tonumber(kid))
        record_lua_declaration(out, "keyed", kid)
        out.depots[kid] = out.depots[kid] or {}
        out.depots[kid].key = kkey
      else
        local mdepot, mquote, mgid, tail = line:match(
          "^setManifestid%s*%(%s*(%d+)%s*,%s*(['\"])(%d+)%2%s*(.-)%)%s*;?%s*$")
        if mdepot and (tail == "" or tail:match("^,%s*%d+%s*$")) then
          mdepot = math.tointeger(tonumber(mdepot))
          out.depots[mdepot] = out.depots[mdepot] or {}
          out.depots[mdepot].manifestid = mgid
        end
      end
    end
  end
  return finish_legacy_lua_parse(out)
end

local function positive_id(value)
  local text = tostring(value or "")
  if not text:match("^%d+$") then return nil end
  local n = math.tointeger(tonumber(text))
  if not n or n <= 0 then return nil end
  return n
end

local function decimal_id(value)
  local text = tostring(value or "")
  if not text:match("^%d+$") then return nil end
  text = text:gsub("^0+", "")
  if text == "" then return nil end
  local maximum = "18446744073709551615"
  if #text > #maximum or (#text == #maximum and text > maximum) then return nil end
  return text
end

local function valid_depot_key(value)
  return type(value) == "string" and #value == 64
    and value:match("^[0-9A-Fa-f]+$") ~= nil
end

local function lua_filename_appid(filename)
  local basename = tostring(filename or ""):gsub("\\\\", "/"):match("([^/]+)$")
  if not basename then return nil end
  local id = basename:match("^(%d+)%s*%(%s*%d+%s*%)%.lua$")
  if not id then id = basename:match("^(%d+)%.lua$") end
  return positive_id(id)
end

local function lua_header_appid(text)
  local long_close = nil
  for raw in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local _, next_close, comment = strip_lua_non_code(raw:gsub("\r$", ""), long_close)
    long_close = next_close
    local id = comment and comment:match("^%s*(%d+)%s*%-%s*")
    if id then return positive_id(id) end
  end
  return nil
end

local function unique_ids(values)
  local result, seen = {}, {}
  for _, value in ipairs(values or {}) do
    if value and not seen[value] then
      result[#result + 1], seen[value] = value, true
    end
  end
  return result
end

local function identity_result(parsed, appid, source, confidence)
  parsed.base = appid
  parsed.source = source
  parsed.confidence = confidence
  parsed.identity_source = source
  parsed.identity_confidence = confidence
  parsed.dlc_appids = {}
  local seen = {}
  for _, id in ipairs(parsed.bare_appids or {}) do
    if id ~= appid and not seen[id] then
      parsed.dlc_appids[#parsed.dlc_appids + 1], seen[id] = id, true
    end
  end
  return parsed
end

-- Resolve the game identity without allowing the first bare DLC declaration to
-- become the base app. Strong hints are ordered but mutually checked; a
-- conflict is an error rather than a silent repair. With no strong hint, one
-- keyed declaration is safe, and multiple keyed declarations are safe only
-- when the first structural declaration is keyed. A bare-only file keeps the
-- old first-bare fallback for compatibility and is marked low confidence.
function mp.resolve_lua_identity(text, hint)
  if type(hint) ~= "table" then hint = { appid = hint } end
  local parsed = mp.parse_lua_strict(text)
  if #parsed.declarations == 0 then return nil, "Lua has no recognized declarations" end

  local strong = {}
  local function add_strong(source, value)
    value = positive_id(value)
    if value then strong[#strong + 1] = { source = source, id = value } end
  end
  add_strong("filename", lua_filename_appid(hint.filename or hint.name))
  add_strong("header", lua_header_appid(text))
  add_strong("explicit", hint.appid)
  local selected
  for _, candidate in ipairs(strong) do
    if selected and selected.id ~= candidate.id then
      return nil, string.format("conflicting Lua identity hints: %s=%d, %s=%d",
        selected.source, selected.id, candidate.source, candidate.id)
    end
    selected = selected or candidate
  end
  if selected then return identity_result(parsed, selected.id, selected.source, "high") end

  local keyed = unique_ids(parsed.keyed_appids)
  local bare = unique_ids(parsed.bare_appids)
  if #keyed == 1 then
    if parsed.declarations[1] and parsed.declarations[1].kind == "bare" and bare[1] then
      return identity_result(parsed, bare[1], "bare", "medium")
    end
    return identity_result(parsed, keyed[1], "keyed", "medium")
  end
  if #keyed > 1 then
    local first = parsed.declarations[1]
    if first and first.kind == "keyed" then
      return identity_result(parsed, keyed[1], "keyed", "medium")
    end
    return nil, "ambiguous Lua identity: multiple keyed app candidates"
  end
  if #bare > 0 then return identity_result(parsed, bare[1], "bare", "low") end
  return nil, "Lua has no app identity"
end

-- A manifest pin is valid when it has a real 64-hex depot key or when the
-- corresponding binary manifest is already available locally/uploaded. The
-- latter is required for keyless legacy files because there is no safe remote
-- lookup identity to reconstruct from the Lua text alone.
function mp.validate_import_pins(parsed, available_manifests)
  local errors = {}
  for depot, info in pairs(parsed and parsed.depots or {}) do
    local gid = info and info.manifestid
    if gid then
      local normalized = decimal_id(gid)
      if not normalized then
        errors[#errors + 1] = "invalid manifest gid for depot " .. tostring(depot)
      elseif not valid_depot_key(info.key) then
        local token = tostring(depot) .. "_" .. normalized
        if not (available_manifests and available_manifests[token]) then
          errors[#errors + 1] = "manifest pin " .. token .. " has no key or available manifest"
        end
      end
    end
  end
  return #errors == 0, errors
end

-- Validate depot ownership across one import batch and already-installed Lua
-- registrations. Shared runtime depots are intentionally exempt because Steam
-- reuses those fixed ids across unrelated apps.
function mp.validate_import_ownership(apps, existing)
  local owners = {}
  for depot, appid in pairs(existing or {}) do
    owners[depot] = appid
  end
  for _, app in ipairs(apps or {}) do
    for depot in pairs(app.parsed and app.parsed.depots or app.depots or {}) do
      if not mp.is_shared_depot(depot) then
        local previous = owners[depot]
        if previous and previous ~= app.appid then
          return false, string.format("depot %d is declared by apps %d and %d",
            depot, previous, app.appid)
        end
        owners[depot] = app.appid
      end
    end
  end
  return true, owners
end

local function sorted_numeric_keys(map)
  local keys = {}
  for key in pairs(map or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

-- Merge recognized data declarations into canonical Lua. `replace_pins` keeps
-- declarations and keys from the existing file but takes the manifest set only
-- from the newly imported text, so omitted old pins cannot survive a reimport.
local function merge_lua_text_impl(appid, replace_pins, ...)
  appid = positive_id(appid)
  if not appid then return nil, "invalid appid" end
  local bare, keys, manifests = { [appid] = true }, {}, {}
  local texts = { ... }
  for index, text in ipairs(texts) do
    if type(text) == "string" and text ~= "" then
      local parsed, identity_err = mp.resolve_lua_identity(text, { appid = appid })
      if not parsed then return nil, identity_err end
      local mentions_app = false
      for _, declaration in ipairs(parsed.declarations or {}) do
        if declaration.id == appid then mentions_app = true; break end
      end
      if not mentions_app and #parsed.bare_appids > 0 then
        return nil, "Lua declares app " .. tostring(parsed.bare_appids[1])
          .. ", expected " .. appid
      end
      for _, id in ipairs(parsed.bare_appids or {}) do
        if id ~= appid then bare[id] = true end
      end
      for depot, info in pairs(parsed.depots or {}) do
        if info.key then
          if not valid_depot_key(info.key) then
            return nil, "invalid key for depot " .. depot
          end
          local normalized = info.key:lower()
          if keys[depot] and keys[depot] ~= normalized then
            return nil, "conflicting keys for depot " .. depot
          end
          keys[depot] = normalized
        end
        if info.manifestid and (not replace_pins or index > 1) then
          local gid = decimal_id(info.manifestid)
          if not gid then return nil, "invalid manifest gid for depot " .. depot end
          manifests[depot] = gid
        end
      end
    end
  end
  local lines = { "addappid(" .. appid .. ")" }
  for _, id in ipairs(sorted_numeric_keys(bare)) do
    if id ~= appid then lines[#lines + 1] = "addappid(" .. id .. ")" end
  end
  for _, depot in ipairs(sorted_numeric_keys(keys)) do
    lines[#lines + 1] = string.format('addappid(%d,1,"%s")', depot, keys[depot])
  end
  for _, depot in ipairs(sorted_numeric_keys(manifests)) do
    lines[#lines + 1] = string.format('setManifestid(%d,"%s")', depot, manifests[depot])
  end
  return table.concat(lines, "\n") .. "\n"
end

function mp.merge_lua_text(appid, ...)
  return merge_lua_text_impl(appid, false, ...)
end

function mp.merge_lua_text_replacing_pins(appid, ...)
  return merge_lua_text_impl(appid, true, ...)
end

-- build_draft_lua(request) -> canonical Lua, err. Blank manifest GIDs are an
-- intentional "Latest" selection and therefore emit no setManifestid line.
function mp.build_draft_lua(request)
  if type(request) ~= "table" then return nil, "bad request" end
  local appid = positive_id(request.appid)
  if not appid then return nil, "invalid appid" end
  local lines = { "addappid(" .. appid .. ")" }
  local dlcs = {}
  for _, value in ipairs(type(request.dlc_appids) == "table" and request.dlc_appids or {}) do
    local id = positive_id(value)
    if not id then return nil, "invalid DLC appid" end
    if id ~= appid then dlcs[id] = true end
  end
  for _, id in ipairs(sorted_numeric_keys(dlcs)) do
    lines[#lines + 1] = "addappid(" .. id .. ")"
  end
  local pins = {}
  for _, pin in ipairs(type(request.pins) == "table" and request.pins or {}) do
    if type(pin) ~= "table" then return nil, "invalid pin" end
    local raw_depot = tostring(pin.depot or ""):match("^%s*(.-)%s*$")
    local raw_gid = tostring(pin.gid or ""):match("^%s*(.-)%s*$")
    if raw_depot ~= "" or raw_gid ~= "" then
      local depot = positive_id(raw_depot)
      if not depot then return nil, "invalid depot id" end
      if raw_gid ~= "" then
        local gid = decimal_id(raw_gid)
        if not gid then return nil, "invalid manifest gid" end
        pins[depot] = gid
      end
    end
  end
  for _, depot in ipairs(sorted_numeric_keys(pins)) do
    lines[#lines + 1] = string.format('setManifestid(%d,"%s")', depot, pins[depot])
  end
  return table.concat(lines, "\n") .. "\n"
end

local function manifest_u32le(bytes, pos)
  local a, b, c, d = bytes:byte(pos, pos + 3)
  if not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function decimal_mul_add(text, multiplier, addend)
  local reversed, carry = {}, addend
  for i = #text, 1, -1 do
    local value = tonumber(text:sub(i, i)) * multiplier + carry
    reversed[#reversed + 1] = tostring(value % 10)
    carry = math.floor(value / 10)
  end
  while carry > 0 do
    reversed[#reversed + 1] = tostring(carry % 10)
    carry = math.floor(carry / 10)
  end
  local forward = {}
  for i = #reversed, 1, -1 do forward[#forward + 1] = reversed[i] end
  return table.concat(forward):gsub("^0+", ""):gsub("^$", "0")
end

local function read_decimal_varint(bytes, pos, limit)
  local chunks = {}
  for _ = 1, 10 do
    if pos > limit then return nil, pos end
    local byte = bytes:byte(pos); pos = pos + 1
    chunks[#chunks + 1] = byte & 0x7f
    if byte < 0x80 then
      local decimal = "0"
      for i = #chunks, 1, -1 do
        decimal = decimal_mul_add(decimal, 128, chunks[i])
      end
      return decimal, pos
    end
  end
  return nil, pos
end

local function parse_manifest_metadata(bytes, first, last)
  local metadata, pos = {}, first
  while pos <= last do
    local tag_text; tag_text, pos = read_decimal_varint(bytes, pos, last)
    local tag = tonumber(tag_text)
    if not tag then return nil, "invalid protobuf tag" end
    local field, wire = math.floor(tag / 8), tag % 8
    if wire == 0 then
      local value; value, pos = read_decimal_varint(bytes, pos, last)
      if not value then return nil, "truncated protobuf varint" end
      if field == 1 then metadata.depot = positive_id(value)
      elseif field == 2 then metadata.gid = decimal_id(value)
      elseif field == 3 then metadata.creation_time = tonumber(value) end
    elseif wire == 1 then pos = pos + 8
    elseif wire == 2 then
      local length; length, pos = read_decimal_varint(bytes, pos, last)
      length = tonumber(length)
      if not length then return nil, "invalid protobuf length" end
      pos = pos + length
    elseif wire == 5 then pos = pos + 4
    else return nil, "unsupported protobuf wire type" end
    if pos > last + 1 then return nil, "truncated protobuf field" end
  end
  return metadata
end

-- parse_manifest(bytes [, expected_depot, expected_gid]) -> metadata, err.
-- Unlike creation_time_from_bytes, this validates the complete section stream
-- and payload marker before imported bytes can be archived. Steam manifests may
-- omit the otherwise-common terminal marker, so a clean section boundary at EOF
-- is accepted too.
function mp.parse_manifest(bytes, expected_depot, expected_gid)
  if type(bytes) ~= "string" then return nil, "manifest is not binary data" end
  local pos, saw_payload, metadata = 1, false, nil
  while pos <= #bytes do
    local magic = manifest_u32le(bytes, pos)
    if not magic then return nil, "truncated manifest section" end
    if magic == 0x32C415AB then
      if pos + 3 ~= #bytes then return nil, "terminal marker is not final" end
      pos = pos + 4; break
    end
    local length = manifest_u32le(bytes, pos + 4)
    if not length then return nil, "truncated manifest section" end
    local first, last = pos + 8, pos + 7 + length
    if last > #bytes then return nil, "manifest section exceeds file" end
    if magic == 0x71F617D0 then saw_payload = true
    elseif magic == 0x1F4812BE then
      local perr; metadata, perr = parse_manifest_metadata(bytes, first, last)
      if not metadata then return nil, perr end
    end
    pos = last + 1
  end
  if not saw_payload then return nil, "missing payload section" end
  if not metadata or not metadata.depot or not metadata.gid then
    return nil, "missing manifest metadata"
  end
  local depot = expected_depot ~= nil and positive_id(expected_depot) or nil
  local gid = expected_gid ~= nil and decimal_id(expected_gid) or nil
  if expected_depot ~= nil and not depot then return nil, "invalid expected depot" end
  if expected_gid ~= nil and not gid then return nil, "invalid expected gid" end
  if depot and metadata.depot ~= depot then return nil, "depot mismatch" end
  if gid and metadata.gid ~= gid then return nil, "gid mismatch" end
  return metadata
end

-- Read-only inspection used by both tests and the transactional importer.
function mp.inspect_import_entries(entries)
  local out = { luas = {}, manifests = {}, warnings = {} }
  local manifests_by_name = {}
  for _, entry in ipairs(type(entries) == "table" and entries or {}) do
    local name, data = tostring(entry.name or ""), entry.data
    local lower = name:lower()
    if lower:match("%.lua$") then
      local source = type(data) == "string" and data or ""
      local parsed, identity_err = mp.resolve_lua_identity(source, { filename = name })
      if not parsed then
        return nil, name .. ": " .. tostring(identity_err)
      end
      out.luas[#out.luas + 1] = {
        name = name, appid = parsed.base, data = data, parsed = parsed,
        identity_source = parsed.source, identity_confidence = parsed.confidence,
      }
    elseif lower:match("%.manifest$") then
      local meta, err = mp.parse_manifest(data)
      if not meta then return nil, name .. ": " .. tostring(err) end
      local canonical = meta.depot .. "_" .. meta.gid .. ".manifest"
      local previous = manifests_by_name[canonical]
      if previous and previous.data ~= data then
        return nil, "conflicting manifests for depot " .. meta.depot .. " gid " .. meta.gid
      elseif not previous then
        local item = {
        source_name = name,
        name = canonical,
        depot = meta.depot, gid = meta.gid,
        creation_time = meta.creation_time, data = data,
        }
        manifests_by_name[canonical] = item
        out.manifests[#out.manifests + 1] = item
      end
    else
      out.warnings[#out.warnings + 1] = "Ignored " .. name
    end
  end
  local owners = {}
  for _, item in ipairs(out.luas) do
    for depot in pairs(item.parsed.depots or {}) do
      if not mp.is_shared_depot(depot) then
        local owner = owners[depot]
        if owner and owner ~= item.appid then
          return nil, string.format("depot %d is declared by apps %d and %d",
            depot, owner, item.appid)
        end
        owners[depot] = item.appid
      end
    end
  end
  return out
end

-- ── Load-.lua import marker ───────────────────────────────────────────────
-- Games added through the menu's "Load .lua" button (vs the LuaTools database)
-- are recorded, one appid per line, in <SLSsteam>/lumen_lua_imports.txt. This is
-- the only signal that tells the two apart on disk (both write a stplug-in
-- <appid>.lua), and it drives the build badge text ("from .lua" vs "from
-- LuaTools"). parse_imports is the pure reader -> a set keyed by appid.
function mp.parse_imports(text)
  local set = {}
  for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local id = math.tointeger(tonumber(line:match("^%s*(%d+)%s*$") or ""))
    if id then set[id] = true end
  end
  return set
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

-- remove_additional_app(text, appid) -> new_text, status. Drops the
-- "- <appid>" entry from the AdditionalApps block (keeping the header even if
-- it becomes empty). Pure text transform so a full game removal can fold it
-- into the same atomic config write as the pin purge. We no longer ADD appids
-- to AdditionalApps (the stplug-in .lua stem is canonical), but full removal
-- still calls this to CLEAN UP any LEGACY entry left by an older version that
-- mirrored — otherwise the stale id keeps the game registered via config.yaml.
-- status: "removed" | "not_present" | "inline_refused" | "bad_appid".
function mp.remove_additional_app(text, appid)
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
  if not header_idx then return text, "not_present" end

  -- a value after the colon (ignoring a comment) => inline list; refuse to edit.
  local after = lines[header_idx]:match("^AdditionalApps%s*:%s*(.-)%s*$") or ""
  if after:gsub("#.*$", ""):gsub("%s+$", "") ~= "" then return text, "inline_refused" end

  local target_idx
  for i = header_idx + 1, #lines do
    local stripped = lines[i]:gsub("^%s+", "")
    if stripped == "" or stripped:match("^#") then
      -- comment/blank: belongs to whatever follows; skip
    else
      -- %s* (not %s+): match flush-left "- 123" items too (valid YAML). The
      -- old %s+ made a zero-indent list break the loop on its first item, so
      -- removal silently failed (reported not_present, left the id in place).
      local _, rest = lines[i]:match("^(%s*)%-%s+(.*)$")
      if not rest then break end  -- next top-level key ends the block
      local id = math.tointeger(tonumber((rest:gsub("#.*$", ""):gsub("%s+$", ""))))
      if id == appid then target_idx = i; break end
    end
  end

  if not target_idx then return text, "not_present" end
  table.remove(lines, target_idx)
  local body = table.concat(lines, "\n")
  if #lines > 0 then body = body .. "\n" end
  return body, "removed"
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
-- replans a FRESH install of that depot at the pinned gid. Pure,
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

local function is_providers_offline()
  local h = home()
  if h == "" then return false end
  local p = h .. "/.config/SLSsteam/offline"
  local f = io.open(p, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function is_game_offline(appid)
  local h = home()
  if h == "" then return false end
  local p = h .. "/.config/SLSsteam/offline_" .. tostring(appid)
  local f = io.open(p, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

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
    metadata_cache_dir = (h ~= "" and (h .. "/.local/share/Lumen/cache/game-updates")) or nil,
    imports_path = (h ~= "" and (h .. "/.config/SLSsteam/lumen_lua_imports.txt")) or nil,
    import_root = (h ~= "" and (h .. "/.local/share/Lumen/imports")) or nil,
    steam_root = root,
  }
end

local function read_file(path)
  if not path then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a"); f:close()
  return d
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function private_dir(path, create)
  if not path or path == "" then return false end
  local command = create and "mkdir -p -m 700 -- " or "chmod 700 -- "
  if os.execute(command .. shell_quote(path) .. " 2>/dev/null") ~= true then return false end
  -- `mkdir -p -m` does not tighten an already-existing directory.
  return os.execute("chmod 700 -- " .. shell_quote(path) .. " 2>/dev/null") == true
end

local function write_plain_atomic(path, data)
  local tmp = path .. ".tmp." .. tostring(os.time()) .. "." .. tostring(math.random(100000, 999999))
  local f, ferr = io.open(tmp, "wb")
  if not f then return false, ferr or "open failed" end
  if os.execute("chmod 600 -- " .. shell_quote(tmp) .. " 2>/dev/null") ~= true then
    f:close(); os.remove(tmp); return false, "could not protect temporary file"
  end
  local ok, werr = f:write(data); f:close()
  if not ok then os.remove(tmp); return false, werr or "write failed" end
  local renamed, rerr = os.rename(tmp, path)
  if not renamed then os.remove(tmp); return false, rerr or "rename failed" end
  return true
end

local function metadata_cache_path(ctx, appid)
  return ctx and ctx.metadata_cache_dir and appid
    and (ctx.metadata_cache_dir .. "/" .. tostring(appid) .. ".json") or nil
end

local function persist_appinfo_metadata(ctx, appid, metadata)
  local path = metadata_cache_path(ctx, appid)
  if not path or type(metadata) ~= "table" or metadata.available ~= true then return false end
  if not private_dir(ctx.metadata_cache_dir, true) then return false end
  local depots = {}
  for id, info in pairs(type(metadata.depots) == "table" and metadata.depots or {}) do
    depots[tostring(id)] = {
      kind = info.kind,
      dlc_appid = info.dlc_appid,
      shared_appid = info.shared_appid,
      oslist = info.oslist,
      language = info.language,
      content_size = info.content_size,
    }
  end
  return write_plain_atomic(path, json.encode({
    version = 1, name = metadata.name, oslist = metadata.oslist, depots = depots,
  }))
end

local function read_persisted_appinfo_metadata(ctx, appid)
  local raw = read_file(metadata_cache_path(ctx, appid))
  if not raw then return nil end
  local ok, cached = pcall(json.decode, raw)
  if not ok or type(cached) ~= "table" or cached.version ~= 1
      or type(cached.depots) ~= "table" then return nil end
  local metadata = {
    available = true,
    name = type(cached.name) == "string" and cached.name or nil,
    oslist = type(cached.oslist) == "string" and cached.oslist or "",
    depots = {},
  }
  for raw_id, info in pairs(cached.depots) do
    local id = positive_id(raw_id)
    if id and type(info) == "table"
        and (info.kind == "base" or info.kind == "dlc" or info.kind == "shared") then
      metadata.depots[id] = {
        id = id,
        kind = info.kind,
        dlc_appid = positive_id(info.dlc_appid),
        shared_appid = positive_id(info.shared_appid),
        oslist = tostring(info.oslist or ""),
        language = tostring(info.language or ""),
        content_size = math.max(0, tonumber(info.content_size) or 0),
      }
    end
  end
  return metadata
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
  local current = mp.parse_appinfo_metadata(read_file(dir .. "/picsbuffer_" .. id .. ".bin") or "")
  persist_appinfo_metadata(ctx, id, current)
  for _, ext in ipairs({ "bin", "yaml" }) do
    os.remove(dir .. "/picsbuffer_" .. id .. "." .. ext)
  end
end

-- The provisioned picsbuffer is local KV1 text (`"appinfo" { ... }`). Parse
-- just enough of it to classify depots without making Game Updates depend on a
-- network request or on Steam's indexed appinfo.vdf format.
local function lex_vdf(text)
  local tokens, i = {}, 1
  text = tostring(text or "")
  while i <= #text do
    local ch = text:sub(i, i)
    if ch:match("%s") then i = i + 1
    elseif text:sub(i, i + 1) == "//" then
      local nl = text:find("\n", i + 2, true); i = nl and (nl + 1) or (#text + 1)
    elseif ch == "{" or ch == "}" then tokens[#tokens + 1] = ch; i = i + 1
    elseif ch == '"' then
      local out, escaped = {}, false
      i = i + 1
      while i <= #text do
        ch = text:sub(i, i)
        if escaped then out[#out + 1] = ch; escaped = false
        elseif ch == "\\" then escaped = true
        elseif ch == '"' then i = i + 1; break
        else out[#out + 1] = ch end
        i = i + 1
      end
      tokens[#tokens + 1] = table.concat(out)
    else i = i + 1 end
  end
  return tokens
end

local function parse_vdf_map(tokens, pos)
  local out = {}
  while pos <= #tokens and tokens[pos] ~= "}" do
    local key = tokens[pos]; pos = pos + 1
    if tokens[pos] == "{" then out[key], pos = parse_vdf_map(tokens, pos + 1)
    elseif tokens[pos] and tokens[pos] ~= "}" then out[key] = tokens[pos]; pos = pos + 1
    else return out, pos end
  end
  return out, pos + 1
end

local function parse_vdf_root(text)
  local tokens, root, pos = lex_vdf(text), {}, 1
  while pos <= #tokens do
    local key = tokens[pos]; pos = pos + 1
    if tokens[pos] == "{" then root[key], pos = parse_vdf_map(tokens, pos + 1)
    else pos = pos + 1 end
  end
  return root.appinfo or root
end

local function normalized_oslist(value)
  local out, seen = {}, {}
  for osname in tostring(value or ""):lower():gmatch("[^,%s]+") do
    if osname == "win" then osname = "windows" end
    if not seen[osname] then out[#out + 1], seen[osname] = osname, true end
  end
  return table.concat(out, ",")
end

-- parse_appinfo_metadata(text) -> {available,name,oslist,depots={...}}.
-- Numeric children under `depots` are content rows; branches and scalar flags
-- are intentionally ignored. Names are not invented: DLC rows expose their
-- associated AppID so the frontend can resolve the catalog name it already
-- knows how to cache.
function mp.parse_appinfo_metadata(text)
  if type(text) ~= "string" or text == "" then
    return { available = false, depots = {} }
  end
  local body = parse_vdf_root(text)
  local depot_nodes = type(body.depots) == "table" and body.depots or {}
  local out = {
    available = next(body) ~= nil,
    name = type(body.common) == "table" and body.common.name or nil,
    oslist = type(body.common) == "table" and normalized_oslist(body.common.oslist) or "",
    depots = {},
  }
  local common_oslist = out.oslist
  for key, node in pairs(depot_nodes) do
    local id = positive_id(key)
    if id and type(node) == "table" then
      local config = type(node.config) == "table" and node.config or {}
      local public = type(node.manifests) == "table"
        and type(node.manifests.public) == "table" and node.manifests.public or {}
      local dlc_appid = positive_id(node.dlcappid)
      local shared_appid = positive_id(node.depotfromapp)
      local kind = (node.sharedinstall == "1" or shared_appid) and "shared"
        or (dlc_appid and "dlc" or "base")
      out.depots[id] = {
        id = id, kind = kind, dlc_appid = dlc_appid,
        shared_appid = shared_appid,
        oslist = normalized_oslist(config.oslist) ~= ""
          and normalized_oslist(config.oslist) or common_oslist,
        language = tostring(config.language or ""),
        content_size = tonumber(public.size) or 0,
      }
    end
  end
  return out
end


local function load_appinfo_metadata(ctx, appid)
  local live = mp.parse_appinfo_metadata(read_file(
    ctx.cache_dir and (ctx.cache_dir .. "/picsbuffer_" .. appid .. ".bin") or nil) or "")
  if live.available then return live end
  return read_persisted_appinfo_metadata(ctx, appid) or live
end

local function supports_os(info, wanted)
  local oslist = tostring(info and info.oslist or "")
  if oslist == "" then return true end
  for item in oslist:gmatch("[^,]+") do if item == wanted then return true end end
  return false
end

-- The main timeline needs one release-bearing BASE depot. Installed content is
-- strongest evidence because it reflects Steam's actual OS choice. Before the
-- game is installed, Windows is preferred on Linux (Proton); native Linux is
-- the second choice. DLC/shared/macOS-only rows never create top-level builds.
function mp.select_history_depot(metadata, installed, available)
  local base = {}
  for id, info in pairs(metadata or {}) do
    if info.kind == "base" and (available == nil or available[id]) then
      base[#base + 1] = { id = id, info = info }
    end
  end
  if #base == 0 then return nil end
  table.sort(base, function(a, b)
    local ai, bi = installed and installed[a.id] ~= nil, installed and installed[b.id] ~= nil
    if ai ~= bi then return ai end
    local aw, bw = supports_os(a.info, "windows"), supports_os(b.info, "windows")
    if aw ~= bw then return aw end
    local al, bl = supports_os(a.info, "linux"), supports_os(b.info, "linux")
    if al ~= bl then return al end
    if a.info.content_size ~= b.info.content_size then return a.info.content_size > b.info.content_size end
    return a.id < b.id
  end)
  return base[1].id
end

-- read_imports(path) -> set of appids marked as "added via Load .lua".
local function read_imports(path)
  return mp.parse_imports(read_file(path) or "")
end

-- mark_import(path, appid) -> ok, err. Adds `appid` to the imports marker file
-- (sorted, one per line) via an atomic temp-rename. No-op success if already
-- present. The file lives next to config.yaml, so its dir exists by the time any
-- import runs (an import requires a readable config.yaml).
local function mark_import(path, appid)
  appid = math.tointeger(tonumber(appid))
  if not path or not appid then return false, "bad args" end
  local set = read_imports(path)
  if set[appid] then return true end
  set[appid] = true
  local ids = {}
  for k in pairs(set) do ids[#ids + 1] = k end
  table.sort(ids)
  local lines = {}
  for _, id in ipairs(ids) do lines[#lines + 1] = tostring(id) end
  local body = table.concat(lines, "\n") .. "\n"
  local tmp = string.format("%s.tmp.lumen.%d.%d", path, os.time(), math.random(100000, 999999))
  local w, werr = io.open(tmp, "wb")
  if not w then return false, werr or "open failed" end
  w:write(body); w:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then os.remove(tmp); return false, rerr or "rename failed" end
  return true
end

-- unmark_import(path, appid): drop `appid` from the imports marker (used by a
-- full game removal). Removes the file when it becomes empty. Best-effort.
local function unmark_import(path, appid)
  appid = math.tointeger(tonumber(appid))
  if not path or not appid then return end
  local set = read_imports(path)
  if not set[appid] then return end
  set[appid] = nil
  local ids = {}
  for k in pairs(set) do ids[#ids + 1] = k end
  table.sort(ids)
  if #ids == 0 then os.remove(path); return end
  local lines = {}
  for _, id in ipairs(ids) do lines[#lines + 1] = tostring(id) end
  local body = table.concat(lines, "\n") .. "\n"
  local tmp = string.format("%s.tmp.lumen.%d.%d", path, os.time(), math.random(100000, 999999))
  local w = io.open(tmp, "wb"); if not w then return end
  w:write(body); w:close()
  if not os.rename(tmp, path) then os.remove(tmp) end
end

-- list_dir(dir) -> array of entry names (lfs when present, else a shell ls).
local function list_dir(dir)
  local names = {}
  if not dir then return names end
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs then
    pcall(function() for e in lfs.dir(dir) do names[#names + 1] = e end end)
  else
    local p = io.popen("ls -1 '" .. dir .. "' 2>/dev/null")
    if p then for line in p:lines() do names[#names + 1] = line end; p:close() end
  end
  return names
end

local function referenced_depots(stplug_dir, excluded_appid)
  local referenced = {}
  for _, name in ipairs(list_dir(stplug_dir)) do
    local file_appid = name:match("^(%d+)%.lua$")
    if file_appid and math.tointeger(tonumber(file_appid)) ~= excluded_appid then
      local source = read_file(stplug_dir .. "/" .. name)
      local parsed = source and mp.parse_lua_strict(source)
      for depot in pairs(parsed and parsed.depots or {}) do referenced[depot] = true end
    end
  end
  return referenced
end

-- delete_manifests_for_ids(manifests_dir, ids [, protected]) -> removed_count.
-- Deletes every archived manifest whose depot belongs to `ids`, except shared
-- runtime depots and depots still referenced by another stplug-in Lua file.
local function delete_manifests_for_ids(manifests_dir, ids, protected)
  if not manifests_dir then return 0 end
  local removed = 0
  for _, name in ipairs(list_dir(manifests_dir)) do
    local depot = name:match("^(%d+)_%d+%.manifest$")
    local numeric_depot = depot and math.tointeger(tonumber(depot))
    if numeric_depot and ids[numeric_depot]
        and not mp.is_shared_depot(numeric_depot)
        and not (protected and protected[numeric_depot]) then
      if os.remove(manifests_dir .. "/" .. name) then removed = removed + 1 end
    end
  end
  return removed
end

-- remove_lua_files(stplug_dir, appid): delete the game's stplug-in <appid>.lua
-- (and a .disabled sibling). Best-effort.
local function remove_lua_files(stplug_dir, appid)
  if not stplug_dir then return end
  os.remove(stplug_dir .. "/" .. appid .. ".lua")
  os.remove(stplug_dir .. "/" .. appid .. ".lua.disabled")
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
local function installed_gids(steam_root, appid, roots)
  local out = {}
  local acf
  for _, root in ipairs(roots or library_roots(steam_root)) do
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
local function app_has_workshop(steam_root, appid, roots)
  for _, root in ipairs(roots or library_roots(steam_root)) do
    local f = io.open(root .. "/steamapps/workshop/appworkshop_" .. appid .. ".acf", "rb")
    if f then f:close(); return true end
  end
  return false
end

-- Group archived manifest filenames by depot. build_games creates this index
-- once so a directory with thousands of files is not traversed again for every
-- depot in every game.
function mp.index_manifest_names(names)
  local by_depot = {}
  for _, name in ipairs(names or {}) do
    local depot, gid = name:match("^(%d+)_(%d+)%.manifest$")
    depot = depot and math.tointeger(tonumber(depot)) or nil
    if depot and gid then
      local entries = by_depot[depot]
      if not entries then entries = {}; by_depot[depot] = entries end
      entries[#entries + 1] = { name = name, gid = gid }
    end
  end
  return by_depot
end

-- Read archived versions only for one requested depot. Directory enumeration
-- is supplied by the one-pass index above; manifest bytes stay lazy so files
-- belonging to unrelated games are never opened.
local function archived_versions(manifests_dir, depot, manifest_index)
  local versions = {}
  if not manifests_dir then return versions end
  for _, entry in ipairs((manifest_index and manifest_index[depot]) or {}) do
    local bytes = read_file(manifests_dir .. "/" .. entry.name)
    local ct = bytes and mp.creation_time_from_bytes(bytes) or nil
    versions[#versions + 1] = {
      gid = entry.gid, date = ct or 0, size = bytes and #bytes or 0,
    }
  end
  return versions
end

-- build_games(ctx) -> array of games.
-- ctx: { config_path, stplug_dir, manifests_dir, steam_root }.
function mp.build_games(ctx)
  ctx = ctx or mp.default_ctx()
  local pins = mp.parse_pins(read_file(ctx.config_path) or "")
  local imports = read_imports(ctx.imports_path)
  local roots = library_roots(ctx.steam_root)
  local manifest_names = ctx.list_manifest_names
    and ctx.list_manifest_names(ctx.manifests_dir) or list_dir(ctx.manifests_dir)
  local manifest_index = mp.index_manifest_names(manifest_names)

  -- enumerate <appid>.lua in stplug-in
  local lua_files = {}
  local ok_lfs, lfs = pcall(require, "lfs")
  if ctx.stplug_dir then
    if ok_lfs then
      -- lfs.dir THROWS if the directory doesn't exist yet (a fresh install with
      -- no games added has no config/stplug-in). Guard it so build_games returns
      -- an empty list and the tab shows its normal empty state, instead of the
      -- error bubbling up as "Failed to load game versions".
      pcall(function()
        for entry in lfs.dir(ctx.stplug_dir) do lua_files[#lua_files + 1] = entry end
      end)
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
      local parsed = mp.resolve_lua_identity(lua, { filename = name })
      if parsed then
        local installed = installed_gids(ctx.steam_root, appid, roots)
        local appinfo = load_appinfo_metadata(ctx, appid)
        local appPins = pins[appid] or { locked = false, depots = {} }
        local has_workshop = app_has_workshop(ctx.steam_root, appid, roots)

        local depots = {}
        for depot, info in pairs(parsed.depots) do
        local versions = archived_versions(ctx.manifests_dir, depot, manifest_index)
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
            kind = appinfo.depots[depot] and appinfo.depots[depot].kind or nil,
            dlcAppid = appinfo.depots[depot] and appinfo.depots[depot].dlc_appid or nil,
            oslist = appinfo.depots[depot] and appinfo.depots[depot].oslist or "",
            language = appinfo.depots[depot] and appinfo.depots[depot].language or "",
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
        local available_depots = {}
        for _, depot in ipairs(depots) do available_depots[depot.depot] = true end
        local is_synthetic = false
        if appid and ctx.cache_dir then
          local sf = io.open(ctx.cache_dir .. "/synthetic_" .. appid, "r")
          if sf then
            sf:close()
            is_synthetic = true
          end
        end

        games[#games + 1] = {
          appid = appid,
          name = appinfo.name,
          historyDepot = mp.select_history_depot(appinfo.depots, installed, available_depots),
          metadataAvailable = appinfo.available,
          locked = appPins.locked or false,
          offline = is_game_offline(appid),
          depots = depots,
          dlc_appids = parsed.dlc_appids,
          fromLuaFile = imports[appid] == true,
          synthetic = is_synthetic,
        }
      end
      end
    end
  end
  return games
end

-- ── manifest storage management ──────────────────────────────────────────
-- delete_manifest(dir, depot, gid) -> ok, err. Removes a single archived
-- <depot>_<gid>.manifest. depot/gid must be all-digits (guards against path
-- traversal — the values flow in from the frontend).
function mp.delete_manifest(manifests_dir, depot, gid, protected)
  if not manifests_dir then return false, "no manifests dir" end
  local d = math.tointeger(tonumber(depot))
  gid = tostring(gid)
  if not d or not gid:match("^%d+$") then return false, "bad depot/gid" end
  if mp.is_shared_depot(d) then return false, "shared depot is protected" end
  if protected and protected[d] then return false, "depot is referenced by another app" end
  local path = manifests_dir .. "/" .. d .. "_" .. gid .. ".manifest"
  local ok, err = os.remove(path)
  if not ok then return false, err or "remove failed" end
  return true
end

-- game_keep_set(g) -> set keyed "<depot>_<gid>" of versions to PRESERVE when
-- bulk-deleting a game's stored manifests: the installed build, any pinned
-- build, and the LuaTools build (the setManifestid gid) UNLESS the game was
-- added via Load .lua (then its .lua-named build isn't a LuaTools-managed one).
local function game_keep_set(g)
  local keep = {}
  for _, dep in ipairs(g.depots or {}) do
    for _, v in ipairs(dep.versions or {}) do
      if v.installed or v.pinned or (v.fromLuaTools and not g.fromLuaFile) then
        keep[dep.depot .. "_" .. v.gid] = true
      end
    end
  end
  return keep
end

-- clear_manifests(ctx) -> removed_count, freed_bytes. Deletes every archived
-- manifest EXCEPT the ones currently installed, pinned, or shipped by LuaTools
-- (the setManifestid build of a non-Load-.lua game). Those are still needed: the
-- pinned one backs the redirect, installed is defensive, and the LuaTools build
-- is the game's canonical version (removable only via the LuaTools menu).
-- Frees the rollback history without breaking the current state.
function mp.clear_manifests(ctx)
  ctx = ctx or mp.default_ctx()
  if not ctx.manifests_dir then return 0, 0 end

  local keep = {}
  local games = mp.build_games(ctx)
  for _, g in ipairs(games) do
    for _, dep in ipairs(g.depots) do
      for _, v in ipairs(dep.versions) do
        if v.installed or v.pinned or (v.fromLuaTools and not g.fromLuaFile) then
          keep[dep.depot .. "_" .. v.gid] = true
        end
      end
    end
  end

  -- A depot referenced by any installed Lua registration may still be needed
  -- by another app, even when none of its archived gids is currently marked
  -- installed or pinned. Shared runtime depots are protected for the same
  -- reason: their fixed IDs are reused across unrelated apps.
  local referenced = referenced_depots(ctx.stplug_dir, nil)
  local names = {}
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs then
    -- Guard: manifests_dir may not exist yet on a fresh install.
    pcall(function()
      for entry in lfs.dir(ctx.manifests_dir) do names[#names + 1] = entry end
    end)
  else
    local p = io.popen("ls -1 '" .. ctx.manifests_dir .. "' 2>/dev/null")
    if p then for line in p:lines() do names[#names + 1] = line end; p:close() end
  end

  local removed, freed = 0, 0
  for _, name in ipairs(names) do
    local depot, gid = name:match("^(%d+)_(%d+)%.manifest$")
    local numeric_depot = depot and math.tointeger(tonumber(depot)) or nil
    if numeric_depot and not keep[depot .. "_" .. gid]
        and not mp.is_shared_depot(numeric_depot)
        and not referenced[numeric_depot] then
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

local function disk_manifest_set(directory)
  local available = {}
  if not directory then return available end
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs then
    pcall(function()
      for name in lfs.dir(directory) do
        local depot, gid = name:match("^(%d+)_(%d+)%.manifest$")
        if depot then available[depot .. "_" .. gid] = true end
      end
    end)
  end
  return available
end

local function canonicalize_import_lua(ctx, text, requested_appid)
  local parsed, identity_err = mp.resolve_lua_identity(text, { appid = requested_appid })
  if not parsed then return nil, nil, identity_err end
  local pin_ok, pin_errors = mp.validate_import_pins(parsed, disk_manifest_set(ctx.manifests_dir))
  if not pin_ok then return nil, nil, table.concat(pin_errors, "; ") end
  local canonical, merge_err = mp.merge_lua_text(parsed.base, text)
  if not canonical then return nil, nil, merge_err end
  return canonical, parsed
end

-- ── Transactional multi-file importer ─────────────────────────────────────
-- Files cross the CDP binding as small base64 chunks. The backend stores each
-- upload in a private session, inspects every Lua/manifest/ZIP before writing
-- live state, then stages all destination files and rolls back on publication
-- failure. ZIP entries are streamed with `unzip -p`; paths are never extracted.
local IMPORT_MAX_FILES = 128
local IMPORT_MAX_FILE = 256 * 1024 * 1024
local IMPORT_MAX_TOTAL = 512 * 1024 * 1024
local IMPORT_MAX_CHUNK = 256 * 1024
local IMPORT_MAX_ENTRIES = 512

local function mkdir_p(path)
  if not path or path == "" then return false end
  return os.execute("mkdir -p -- " .. shell_quote(path) .. " 2>/dev/null") == true
end

local function import_session_dir(ctx, session)
  if type(session) ~= "string" or not session:match("^[a-z0-9]+$") then return nil end
  if not ctx.import_root then return nil end
  return ctx.import_root .. "/" .. session
end

local function import_state_path(ctx, session)
  local dir = import_session_dir(ctx, session)
  return dir and (dir .. "/state.json") or nil
end

local function read_import_state(ctx, session)
  local raw = read_file(import_state_path(ctx, session))
  if not raw then return nil, "unknown or expired import session" end
  local ok, state = pcall(json.decode, raw)
  if not ok or type(state) ~= "table" or type(state.files) ~= "table" then
    return nil, "corrupt import session"
  end
  return state
end

local function write_import_state(ctx, session, state)
  return write_plain_atomic(import_state_path(ctx, session), json.encode(state))
end

local function remove_tree(path)
  if not path then return end
  local ok_lfs, lfs = pcall(require, "lfs")
  if not ok_lfs then return end
  local mode = lfs.attributes(path, "mode")
  if mode == "directory" then
    for entry in lfs.dir(path) do
      if entry ~= "." and entry ~= ".." then remove_tree(path .. "/" .. entry) end
    end
    lfs.rmdir(path)
  elseif mode then os.remove(path) end
end

local function safe_import_name(name)
  name = tostring(name or ""):gsub("\\", "/")
  local base = name:match("([^/]+)$") or ""
  if base == "" or base == "." or base == ".." or base:find("[%z\r\n]") then return nil end
  local lower = base:lower()
  if not (lower:match("%.lua$") or lower:match("%.manifest$") or lower:match("%.zip$")) then
    return nil
  end
  return base
end

function mp.begin_game_import_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or type(req.files) ~= "table"
      or #req.files < 1 or #req.files > IMPORT_MAX_FILES then return err("invalid file list") end
  local files, total = {}, 0
  for index, item in ipairs(req.files) do
    local name = type(item) == "table" and safe_import_name(item.name) or nil
    local size = type(item) == "table" and as_int(item.size) or nil
    if not name then return err("unsupported file name at item " .. index) end
    if not size or size < 0 or size > IMPORT_MAX_FILE then return err("file is too large") end
    total = total + size
    if total > IMPORT_MAX_TOTAL then return err("selection is too large") end
    files[index] = { name = name, size = size, received = 0, next_chunk = 0, complete = false }
  end
  if not private_dir(ctx.import_root, true) then return err("could not create private import area") end
  local session
  for _ = 1, 10 do
    session = string.format("%x%x", os.time(), math.random(0x100000, 0xffffff))
    local dir = import_session_dir(ctx, session)
    -- The parent exists; plain mkdir succeeds only for a fresh name, which
    -- makes session allocation collision-safe without requiring lfs in host
    -- tests (the shipped runtime has it, but this primitive does not need it).
    if os.execute("mkdir -m 700 -- " .. shell_quote(dir) .. " 2>/dev/null") == true then break end
    session = nil
  end
  if not session then return err("could not allocate import session") end
  local state = { files = files, total = total, prepared = false }
  local wok, werr = write_import_state(ctx, session, state)
  if not wok then remove_tree(import_session_dir(ctx, session)); return err(werr) end
  return json.encode({ success = true, session = session })
end

function mp.upload_game_import_chunk_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" then return err("bad request") end
  local state, serr = read_import_state(ctx, req.session)
  if not state then return err(serr) end
  local index, chunk = as_int(req.file), as_int(req.chunk)
  local item = index and state.files[index] or nil
  if not item or item.complete then return err("invalid upload target") end
  if chunk ~= item.next_chunk then return err("out-of-order upload chunk") end
  local b64 = require("b64")
  local bytes = b64.decode(req.data)
  if not bytes or #bytes > IMPORT_MAX_CHUNK then return err("invalid upload chunk") end
  local previous_size = item.received
  local next_size = previous_size + #bytes
  if next_size > item.size then return err("upload exceeds declared size") end
  if req.final == true and next_size ~= item.size then return err("upload size mismatch") end
  if req.final ~= true and next_size == item.size then return err("final chunk flag missing") end
  local path = import_session_dir(ctx, req.session) .. "/file_" .. index
  local f, ferr = io.open(path, previous_size == 0 and "wb" or "ab")
  if not f then return err(ferr or "could not store upload") end
  if previous_size == 0
      and os.execute("chmod 600 -- " .. shell_quote(path) .. " 2>/dev/null") ~= true then
    f:close(); os.remove(path); return err("could not protect upload")
  end
  local wrote, werr = f:write(bytes); f:close()
  if not wrote then return err(werr or "could not store upload") end
  item.received = next_size
  item.next_chunk = item.next_chunk + 1
  item.complete = req.final == true
  state.prepared = false
  local sw, se = write_import_state(ctx, req.session, state)
  if not sw then
    os.execute("truncate -s " .. previous_size .. " -- " .. shell_quote(path) .. " 2>/dev/null")
    return err(se)
  end
  return json.encode({ success = true, received = item.received })
end

function mp.cancel_game_import_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" then return err("bad request") end
  local dir = import_session_dir(ctx, req.session)
  if not dir or not read_file(import_state_path(ctx, req.session)) then
    return err("unknown or expired import session")
  end
  remove_tree(dir)
  return json.encode({ success = true })
end

local function zip_entry_safe(name)
  if type(name) ~= "string" or name == "" or name:sub(1, 1) == "/"
      or name:find("\\", 1, true) or name:find("[%z\r\n]") then return false end
  for part in name:gmatch("[^/]+") do if part == ".." then return false end end
  return true
end

local function read_pipe_limited(command, limit)
  local p = io.popen(command, "r")
  if not p then return nil, "could not run unzip" end
  local data = p:read(limit + 1) or ""
  local ok = p:close()
  if #data > limit then return nil, "archive entry is too large" end
  if ok == nil or ok == false then return nil, "could not read archive entry" end
  return data
end

local function collect_import_entries(ctx, session, state)
  local entries, total, count = {}, 0, 0
  local dir = import_session_dir(ctx, session)
  for index, item in ipairs(state.files) do
    if not item.complete or item.received ~= item.size then return nil, "upload is incomplete" end
    local path = dir .. "/file_" .. index
    if item.name:lower():match("%.zip$") then
      local list = io.popen("unzip -Z1 -- " .. shell_quote(path) .. " 2>/dev/null", "r")
      if not list then return nil, "could not inspect ZIP" end
      local names, listed_count, too_many = {}, 0, false
      for name in list:lines() do
        listed_count = listed_count + 1
        if listed_count <= IMPORT_MAX_ENTRIES then names[#names + 1] = name
        else too_many = true end
      end
      local listed_ok = list:close()
      if listed_ok == nil or listed_ok == false then return nil, "invalid ZIP archive" end
      if too_many then return nil, "too many archive entries" end
      for _, name in ipairs(names) do
        if not zip_entry_safe(name) then return nil, "unsafe ZIP entry: " .. tostring(name) end
        local lower = name:lower()
        if not name:match("/$") and (lower:match("%.lua$") or lower:match("%.manifest$")) then
          count = count + 1
          if count > IMPORT_MAX_ENTRIES then return nil, "too many archive entries" end
          local data, zerr = read_pipe_limited(
            "unzip -p -- " .. shell_quote(path) .. " " .. shell_quote(name) .. " 2>/dev/null",
            IMPORT_MAX_FILE)
          if not data then return nil, zerr end
          total = total + #data
          if total > IMPORT_MAX_TOTAL then return nil, "expanded package is too large" end
          entries[#entries + 1] = { name = name, data = data }
        end
      end
    else
      local data = read_file(path)
      if not data or #data ~= item.size then return nil, "stored upload size mismatch" end
      total = total + #data; count = count + 1
      entries[#entries + 1] = { name = item.name, data = data }
    end
  end
  if #entries == 0 then return nil, "no .lua or .manifest files found" end
  return entries
end

local function available_import_manifests(ctx, inspected)
  local available = {}
  for _, manifest in ipairs(inspected.manifests or {}) do
    available[manifest.depot .. "_" .. manifest.gid] = true
  end
  if ctx.manifests_dir then
    local ok_lfs, lfs = pcall(require, "lfs")
    if ok_lfs then
      pcall(function()
        for name in lfs.dir(ctx.manifests_dir) do
          local depot, gid = name:match("^(%d+)_(%d+)%.manifest$")
          if depot then available[depot .. "_" .. gid] = true end
        end
      end)
    end
  end
  return available
end

local function existing_import_depot_owners(ctx)
  local owners = {}
  if not ctx.stplug_dir then return owners end
  local ok_lfs, lfs = pcall(require, "lfs")
  if not ok_lfs then return owners end
  pcall(function()
    for name in lfs.dir(ctx.stplug_dir) do
      local appid = name:match("^(%d+)%.lua$")
      if appid then
        local source = read_file(ctx.stplug_dir .. "/" .. name)
        local parsed = source and mp.resolve_lua_identity(source, { filename = name })
        if parsed then
          for depot in pairs(parsed.depots or {}) do
            if not owners[depot] then owners[depot] = parsed.base end
          end
        end
      end
    end
  end)
  return owners
end

local function build_import_plan(ctx, session, state)
  local entries, cerr = collect_import_entries(ctx, session, state)
  if not entries then return nil, cerr end
  local inspected, ierr = mp.inspect_import_entries(entries)
  if not inspected then return nil, ierr end
  local grouped = {}
  for _, item in ipairs(inspected.luas) do
    grouped[item.appid] = grouped[item.appid] or {}
    grouped[item.appid][#grouped[item.appid] + 1] = item.data
  end
  -- Source enrichment is stored as validated, data-only Lua in the private
  -- import session. Merge it first so uploaded declarations retain the final
  -- say on manifest pins while missing keys/DLC declarations are filled in.
  for appid_text, text in pairs(type(state.enrichment) == "table" and state.enrichment or {}) do
    local appid = positive_id(appid_text)
    if appid and grouped[appid] and type(text) == "string" then
      table.insert(grouped[appid], 1, text)
    end
  end

  local available = available_import_manifests(ctx, inspected)
  local apps = {}
  for appid, texts in pairs(grouped) do
    local merged, merr = mp.merge_lua_text(appid, table.unpack(texts))
    if not merged then return nil, merr end
    local parsed, identity_err = mp.resolve_lua_identity(merged, { appid = appid })
    if not parsed then return nil, identity_err end
    local pin_ok, pin_errors = mp.validate_import_pins(parsed, available)
    if not pin_ok then
      return nil, string.format("app %d: %s", appid, table.concat(pin_errors, "; "))
    end
    local pin_count = 0
    for _, info in pairs(parsed.depots) do
      if info.manifestid then pin_count = pin_count + 1 end
    end
    apps[#apps + 1] = {
      appid = appid, text = merged, parsed = parsed, pins = pin_count,
      identity_source = parsed.source, identity_confidence = parsed.confidence,
      installed = next(installed_gids(ctx.steam_root, appid)) ~= nil,
    }
  end
  local ownership_ok, ownership_err = mp.validate_import_ownership(
    apps, existing_import_depot_owners(ctx))
  if not ownership_ok then return nil, ownership_err end
  table.sort(apps, function(a, b) return a.appid < b.appid end)
  table.sort(inspected.manifests, function(a, b)
    return a.depot == b.depot and a.gid < b.gid or a.depot < b.depot
  end)
  return {
    apps = apps, manifests = inspected.manifests, warnings = inspected.warnings,
  }
end

-- EnrichGameImport{session, appid, lua}: attach the canonical source-generated
-- Lua to an uploaded app without publishing it. The next Prepare/Commit merges
-- source keys and DLCs under the user's uploaded manifest choices.
function mp.enrich_game_import_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or type(req.lua) ~= "string" then
    return err("bad request")
  end
  local appid = positive_id(req.appid)
  if not appid then return err("invalid appid") end
  local state, serr = read_import_state(ctx, req.session)
  if not state then return err(serr) end
  local entries, cerr = collect_import_entries(ctx, req.session, state)
  if not entries then return err(cerr) end
  local has_app = false
  for _, entry in ipairs(entries) do
    if tostring(entry.name):lower():match("%.lua$") then
      local parsed = mp.resolve_lua_identity(entry.data or "", { filename = entry.name })
      if parsed and parsed.base == appid then has_app = true; break end
    end
  end
  if not has_app then return err("import session does not contain app " .. appid) end
  local canonical, merr = mp.merge_lua_text(appid, req.lua)
  if not canonical then return err(merr) end
  state.enrichment = type(state.enrichment) == "table" and state.enrichment or {}
  state.enrichment[tostring(appid)] = canonical
  state.prepared = false
  local sw, se = write_import_state(ctx, req.session, state)
  if not sw then return err(se) end
  return json.encode({ success = true, appid = appid })
end

function mp.prepare_game_import_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" then return err("bad request") end
  local state, serr = read_import_state(ctx, req.session)
  if not state then return err(serr) end
  local plan, perr = build_import_plan(ctx, req.session, state)
  if not plan then return err(perr) end
  state.prepared = true
  local sw, se = write_import_state(ctx, req.session, state)
  if not sw then return err(se) end
  local apps, manifests = {}, {}
  for _, app in ipairs(plan.apps) do
    local parsed, keys = app.parsed or mp.resolve_lua_identity(app.text, { appid = app.appid }), 0
    for _, info in pairs(parsed.depots) do if info.key then keys = keys + 1 end end
    apps[#apps + 1] = {
      appid = app.appid, pins = app.pins, keys = keys, installed = app.installed,
      identitySource = app.identity_source, identityConfidence = app.identity_confidence,
      identity = { appid = app.appid, source = app.identity_source,
        confidence = app.identity_confidence },
    }
  end
  for _, man in ipairs(plan.manifests) do
    manifests[#manifests + 1] = {
      depot = man.depot, gid = man.gid, date = man.creation_time,
      name = man.name, source = man.source_name,
    }
  end
  return json.encode({ success = true, apps = json.array(apps),
    manifests = json.array(manifests), warnings = json.array(plan.warnings) })
end

-- BuildGameDraft{appid, dlc_appids, pins}: canonical data-only Lua for the
-- simple creator. Keys are intentionally absent here; the frontend asks the
-- existing LuaTools sources to enrich the draft before CommitGameImport.
function mp.build_game_draft_rpc(_, json_str)
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" then return err("bad request") end
  local text, berr = mp.build_draft_lua(req)
  if not text then return err(berr) end
  return json.encode({ success = true, appid = positive_id(req.appid), lua = text })
end

local function marker_with_apps(current, apps)
  local set = mp.parse_imports(current or "")
  for _, app in ipairs(apps) do set[app.appid] = true end
  local ids = sorted_numeric_keys(set)
  local lines = {}; for _, id in ipairs(ids) do lines[#lines + 1] = tostring(id) end
  return #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
end

local function publish_import(publications)
  local nonce = tostring(os.time()) .. "." .. tostring(math.random(100000, 999999))
  local snapshots, staged = {}, {}
  for i, pub in ipairs(publications) do
    local temp = pub.path .. ".tmp.lumen.import." .. nonce .. "." .. i
    local f, ferr = io.open(temp, "wb")
    if not f then for _, p in ipairs(staged) do os.remove(p) end; return false, ferr end
    if os.execute("chmod 600 -- " .. shell_quote(temp) .. " 2>/dev/null") ~= true then
      f:close(); os.remove(temp)
      for _, p in ipairs(staged) do os.remove(p) end
      return false, "could not protect staged publication"
    end
    local wrote, werr = f:write(pub.data); f:close()
    if not wrote then os.remove(temp); for _, p in ipairs(staged) do os.remove(p) end; return false, werr end
    staged[i] = temp
    snapshots[i] = { exists = read_file(pub.path) ~= nil, data = read_file(pub.path) }
  end
  for i, pub in ipairs(publications) do
    local ok, rerr = os.rename(staged[i], pub.path)
    if not ok then
      for j = i, #staged do os.remove(staged[j]) end
      for j = i - 1, 1, -1 do
        if snapshots[j].exists then write_plain_atomic(publications[j].path, snapshots[j].data)
        else os.remove(publications[j].path) end
      end
      return false, rerr or "publication failed"
    end
  end
  return true
end

function mp.commit_game_import_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" then return err("bad request") end
  local state, serr = read_import_state(ctx, req.session)
  if not state then return err(serr) end
  if state.prepared ~= true then return err("import must be prepared first") end
  local plan, perr = build_import_plan(ctx, req.session, state)
  if not plan then return err(perr) end
  if not mkdir_p(ctx.stplug_dir) or not mkdir_p(ctx.manifests_dir) then
    return err("could not create destination directories")
  end
  local cfg = read_file(ctx.config_path)
  if not looks_like_config(cfg) then return err("config.yaml not found or invalid") end
  local pins = mp.parse_pins(cfg)
  local publications = {}
  for _, man in ipairs(plan.manifests) do
    publications[#publications + 1] = { path = ctx.manifests_dir .. "/" .. man.name, data = man.data }
  end
  for _, app in ipairs(plan.apps) do
    -- Smart source enrichment may have completed after Prepare. Read it now and
    -- merge it first, preserving its keys while the uploaded Lua wins on pins.
    local target = ctx.stplug_dir .. "/" .. app.appid .. ".lua"
    local merged, merr = mp.merge_lua_text_replacing_pins(
      app.appid, read_file(target) or "", app.text)
    if not merged then return err(merr) end
    publications[#publications + 1] = { path = target, data = merged }
    local parsed, depot_gids = mp.parse_lua(merged), {}
    for depot, info in pairs(parsed.depots) do
      if info.manifestid then depot_gids[depot] = info.manifestid end
    end
    if next(depot_gids) then mp.set_game_pin(pins, app.appid, depot_gids)
    else mp.clear_game_pin(pins, app.appid) end
  end
  publications[#publications + 1] = { path = ctx.config_path, data = mp.splice_pins(cfg, pins) }
  if ctx.imports_path and #plan.apps > 0 then
    publications[#publications + 1] = {
      path = ctx.imports_path, data = marker_with_apps(read_file(ctx.imports_path), plan.apps),
    }
  end
  local pok, puberr = publish_import(publications)
  if not pok then return err(puberr) end
  for _, app in ipairs(plan.apps) do mp.invalidate_appinfo_cache(ctx, app.appid) end
  remove_tree(import_session_dir(ctx, req.session))
  return json.encode({ success = true, apps = #plan.apps, manifests = #plan.manifests })
end

function mp.get_game_updates(ctx)
  ctx = ctx or mp.default_ctx()
  local ok, games = pcall(mp.build_games, ctx)
  if not ok then return err(games) end
  local offline = is_providers_offline()
  return json.encode({ success = true, games = games, providers_offline = offline })
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
  local requested = positive_id(req.appid)
  local _, parsed, import_err = canonicalize_import_lua(ctx, req.lua, requested)
  if not parsed then return err(import_err) end
  local appid = parsed.base
  if not appid then return err("could not determine app id from .lua") end

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

-- SyncGamePins{appid, lua}: synchronize ManifestPins with an edited canonical
-- Lua. Unlike the legacy ImportLuaPin endpoint, zero setManifestid declarations
-- are meaningful here: they clear an older lock and restore Latest behavior.
function mp.sync_game_pins_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or type(req.lua) ~= "string" then
    return err("bad request")
  end
  local requested = positive_id(req.appid)
  local _, parsed, import_err = canonicalize_import_lua(ctx, req.lua, requested)
  if not parsed then return err(import_err) end
  local appid = parsed.base
  if not appid then return err("could not determine app id from .lua") end
  local depot_gids, count = {}, 0
  for depot, info in pairs(parsed.depots) do
    if info.manifestid then depot_gids[depot] = info.manifestid; count = count + 1 end
  end
  local cfg = read_file(ctx.config_path)
  if not cfg then return err("config.yaml not found") end
  local pins = mp.parse_pins(cfg)
  if count > 0 then mp.set_game_pin(pins, appid, depot_gids)
  else mp.clear_game_pin(pins, appid) end
  local wok, werr = write_pins(ctx.config_path, pins)
  if not wok then return err(werr) end
  mp.invalidate_appinfo_cache(ctx, appid)
  return json.encode({ success = true, appid = appid, pinned = count })
end

-- Atomically install an official LuaTools manifest and synchronize every
-- setManifestid declaration into the app-scoped ManifestPins map. This is the
-- backend contract used by the recommended-version Add flow: Steam must see
-- both the depot keys and the locked target gids before its next install plan.
-- Unlike ImportLuaFull, this does not mark the title as a manual file import.
function mp.install_luatools_manifest(ctx, requested_appid, text)
  ctx = ctx or mp.default_ctx()
  if type(text) ~= "string" then return false, "bad manifest" end
  local requested = positive_id(requested_appid)
  local _, parsed, import_err = canonicalize_import_lua(ctx, text, requested)
  if not parsed then return false, import_err end
  local appid = parsed.base
  if not appid then return false, "could not determine app id from .lua" end

  local depot_gids, count = {}, 0
  for depot, info in pairs(parsed.depots) do
    if info.manifestid then
      depot_gids[depot] = info.manifestid
      count = count + 1
    end
  end

  local cfg = read_file(ctx.config_path)
  if not looks_like_config(cfg) then
    return false, "config.yaml not found or invalid"
  end
  local pins = mp.parse_pins(cfg)
  if count > 0 then mp.set_game_pin(pins, appid, depot_gids)
  else mp.clear_game_pin(pins, appid) end
  if not mkdir_p(ctx.stplug_dir) then
    return false, "could not create stplug-in directory"
  end
  local published, publish_err = publish_import({
    { path = ctx.stplug_dir .. "/" .. tostring(appid) .. ".lua", data = text },
    { path = ctx.config_path, data = mp.splice_pins(cfg, pins) },
  })
  if not published then return false, publish_err end
  mp.invalidate_appinfo_cache(ctx, appid)
  return true, { appid = appid, pinned = count }
end

-- ImportLuaFull{appid?, lua}: import a LuaTools .lua for a game NOT yet added
-- via the LuaTools plugin. Writes the .lua to stplug-in/<appid>.lua (depot
-- keys) — the canonical registration slsteam-moon discovers from the filename
-- stem — and applies the setManifestid pins (locking the build) to config.yaml
-- when the file carries any. The appid is NOT mirrored into config.yaml
-- AdditionalApps. The appid is the .lua's base (first bare addappid); a
-- card-supplied appid must match it. A .lua with no setManifestid still imports
-- (pinned=0): the game installs at the latest build. SLSsteam only provisions a
-- brand-new appid on its next start, so the frontend prompts a Steam restart.
function mp.import_lua_full_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or type(req.lua) ~= "string" then
    return err("bad request")
  end
  local requested = positive_id(req.appid)
  local canonical, parsed, import_err = canonicalize_import_lua(ctx, req.lua, requested)
  if not parsed then return err(import_err) end
  local appid = parsed.base
  if not appid then return err("could not determine app id from .lua") end

  -- Collect setManifestid pins before publication (a keys-only .lua is valid).
  local depot_gids, count = {}, 0
  for depot, info in pairs(parsed.depots) do
    if info.manifestid then depot_gids[depot] = info.manifestid; count = count + 1 end
  end

  -- Validate and prepare the complete new state before replacing either live
  -- file. `publish_import` stages both files and restores their old contents if
  -- a later rename fails, so a rejected config can never leave a new Lua file
  -- paired with the old ManifestPins entry.
  local cfg = read_file(ctx.config_path)
  if not looks_like_config(cfg) then
    return err("config.yaml not found or invalid")
  end
  local pins = mp.parse_pins(cfg)
  if count > 0 then mp.set_game_pin(pins, appid, depot_gids)
  else mp.clear_game_pin(pins, appid) end
  local newcfg = mp.splice_pins(cfg, pins)
  if not mkdir_p(ctx.stplug_dir) then return err("could not create stplug-in directory") end
  local pok, perr = publish_import({
    { path = ctx.stplug_dir .. "/" .. tostring(appid) .. ".lua", data = canonical },
    { path = ctx.config_path, data = newcfg },
  })
  if not pok then return err(perr) end
  mp.invalidate_appinfo_cache(ctx, appid)
  -- Record that this game was added by loading a .lua (not the LuaTools DB) so
  -- its build badge reads "from .lua". Best-effort: a failed mark only costs the
  -- nicer label, never the import itself.
  mark_import(ctx.imports_path, appid)

  return json.encode({ success = true, appid = appid, pinned = count })
end

-- MarkLuaImport{appid}: record `appid` as added through the menu's "Load .lua"
-- button. Used by the from-source import path (where StartAddViaLuaToolsSmart,
-- not ImportLuaFull, adds the game, so the auto-mark there doesn't fire).
function mp.mark_lua_import_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or not req.appid then return err("bad request") end
  local appid = as_int(req.appid)
  if not appid then return err("bad appid") end
  local mok, merr = mark_import(ctx.imports_path, appid)
  if not mok then return err(merr) end
  return json.encode({ success = true, appid = appid })
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
  local requested = positive_id(req.appid)
  local _, parsed, import_err = canonicalize_import_lua(ctx, req.lua, requested)
  if not parsed then return err(import_err) end
  local appid = parsed.base
  if not appid then return err("could not determine app id from .lua") end
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
    source = parsed.source, confidence = parsed.confidence,
    installed = installed, pinned = count, alreadyOnBuild = already_on_build })
end

-- DeleteManifest{depot, gid}: remove a single archived version's manifest.
function mp.delete_manifest_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or not req.depot or not req.gid then
    return err("bad request")
  end
  local protected = nil
  if req.appid then
    local appid = positive_id(req.appid)
    if not appid then return err("bad appid") end
    protected = referenced_depots(ctx.stplug_dir, appid)
  end
  local dok, derr = mp.delete_manifest(ctx.manifests_dir, req.depot, req.gid, protected)
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

-- DeleteBuild{appid, date|gid}: remove every archived manifest of `appid` that
-- belongs to the same calendar day (UTC) as the selected build — i.e. all
-- depots packaged that day — EXCEPT installed/pinned/LuaTools versions. Backs
-- the per-build trash in the list and the advanced view. `date` is the build's
-- creation_time (the list groups by day); `gid` is accepted as an alternative.
function mp.delete_build_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or not req.appid then return err("bad request") end
  local appid = as_int(req.appid)
  local games = mp.build_games(ctx)
  local game
  for _, g in ipairs(games) do if g.appid == appid then game = g; break end end
  if not game then return err("unknown app") end

  local T = req.date and as_int(req.date)
  if not T and req.gid then
    local want = tostring(req.gid)
    for _, dep in ipairs(game.depots) do
      for _, v in ipairs(dep.versions) do if v.gid == want then T = v.date end end
    end
  end
  if not T then return err("could not resolve build date") end
  local lo = T - (T % 86400)        -- start of that UTC day (matches the list grouping)
  local hi = lo + 86399

  local keep = game_keep_set(game)
  local protected = referenced_depots(ctx.stplug_dir, appid)
  local removed = 0
  for _, dep in ipairs(game.depots) do
    for _, v in ipairs(dep.versions) do
      if v.date and v.date >= lo and v.date <= hi
         and not keep[dep.depot .. "_" .. v.gid] then
        if mp.delete_manifest(ctx.manifests_dir, dep.depot, v.gid, protected) then removed = removed + 1 end
      end
    end
  end
  return json.encode({ success = true, removed = removed })
end

-- DeleteAll{appid}: bulk-remove a game's stored versions from the Game Updates
-- tab.
--   * Load-.lua game  -> FULL removal: delete every stored manifest for the
--     game's depots, delete its stplug-in .lua, drop it from AdditionalApps,
--     purge its pins, clear the import marker, and invalidate its appinfo cache.
--     (Re-addable any time via Load .lua.)
--   * LuaTools game   -> delete every stored version EXCEPT installed/pinned and
--     the LuaTools build(s); those stay (removable only from the LuaTools menu).
-- Returns { success, fullRemoval, removed, kept }.
function mp.delete_all_rpc(ctx, json_str)
  ctx = ctx or mp.default_ctx()
  local ok, req = pcall(json.decode, json_str)
  if not ok or type(req) ~= "table" or not req.appid then return err("bad request") end
  local appid = as_int(req.appid)
  if not appid then return err("bad appid") end

  local imports = read_imports(ctx.imports_path)
  if imports[appid] then
    -- FULL removal of a Load-.lua game.
    local luatext = read_file((ctx.stplug_dir or "") .. "/" .. appid .. ".lua") or ""
    local parsed = mp.parse_lua(luatext)
    local ids = { [appid] = true }
    if parsed.base then ids[parsed.base] = true end
    for d in pairs(parsed.depots) do ids[d] = true end
    for _, d in ipairs(parsed.dlc_appids) do ids[d] = true end

    local protected = referenced_depots(ctx.stplug_dir, appid)
    local removed = delete_manifests_for_ids(ctx.manifests_dir, ids, protected)
    remove_lua_files(ctx.stplug_dir, appid)

    local cfg = read_file(ctx.config_path)
    if cfg then
      local newcfg = (mp.remove_additional_app(cfg, appid))
      local pins = mp.parse_pins(newcfg)
      mp.clear_game_pin(pins, appid)
      newcfg = mp.splice_pins(newcfg, pins)
      write_config_raw(ctx.config_path, newcfg)
    end
    unmark_import(ctx.imports_path, appid)
    mp.invalidate_appinfo_cache(ctx, appid)
    return json.encode({ success = true, fullRemoval = true, removed = removed, kept = 0 })
  end

  -- LuaTools game: delete everything except installed/pinned/LuaTools versions.
  local games = mp.build_games(ctx)
  local game
  for _, g in ipairs(games) do if g.appid == appid then game = g; break end end
  if not game then return err("unknown app") end
  local keep = game_keep_set(game)
  local protected = referenced_depots(ctx.stplug_dir, appid)
  local removed, kept = 0, 0
  for _, dep in ipairs(game.depots) do
    for _, v in ipairs(dep.versions) do
      if keep[dep.depot .. "_" .. v.gid] then
        kept = kept + 1
      elseif mp.delete_manifest(ctx.manifests_dir, dep.depot, v.gid, protected) then
        removed = removed + 1
      end
    end
  end
  return json.encode({ success = true, fullRemoval = false, removed = removed, kept = kept })
end

-- register(registry): install the five Game Updates RPCs bound to the real ctx.
function mp.register(registry)
  registry.GetGameUpdates = function() return mp.get_game_updates(mp.default_ctx()) end
  registry.SetGamePin = function(j) return mp.set_game_pin_rpc(mp.default_ctx(), j) end
  registry.SetDlcPin = function(j) return mp.set_dlc_pin_rpc(mp.default_ctx(), j) end
  registry.ClearGamePin = function(j) return mp.clear_game_pin_rpc(mp.default_ctx(), j) end
  registry.ClearDlcPin = function(j) return mp.clear_dlc_pin_rpc(mp.default_ctx(), j) end
  registry.ImportLuaPin = function(j) return mp.import_lua_pin_rpc(mp.default_ctx(), j) end
  registry.SyncGamePins = function(j) return mp.sync_game_pins_rpc(mp.default_ctx(), j) end
  registry.ImportLuaFull = function(j) return mp.import_lua_full_rpc(mp.default_ctx(), j) end
  registry.MarkLuaImport = function(j) return mp.mark_lua_import_rpc(mp.default_ctx(), j) end
  registry.InspectLua = function(j) return mp.inspect_lua_rpc(mp.default_ctx(), j) end
  registry.BuildGameDraft = function(j) return mp.build_game_draft_rpc(mp.default_ctx(), j) end
  registry.BeginGameImport = function(j) return mp.begin_game_import_rpc(mp.default_ctx(), j) end
  registry.UploadGameImportChunk = function(j) return mp.upload_game_import_chunk_rpc(mp.default_ctx(), j) end
  registry.CancelGameImport = function(j) return mp.cancel_game_import_rpc(mp.default_ctx(), j) end
  registry.PrepareGameImport = function(j) return mp.prepare_game_import_rpc(mp.default_ctx(), j) end
  registry.EnrichGameImport = function(j) return mp.enrich_game_import_rpc(mp.default_ctx(), j) end
  registry.CommitGameImport = function(j) return mp.commit_game_import_rpc(mp.default_ctx(), j) end
  registry.DeleteManifest = function(j) return mp.delete_manifest_rpc(mp.default_ctx(), j) end
  registry.DeleteBuild = function(j) return mp.delete_build_rpc(mp.default_ctx(), j) end
  registry.DeleteAll = function(j) return mp.delete_all_rpc(mp.default_ctx(), j) end
  registry.ClearManifests = function() return mp.clear_manifests_rpc(mp.default_ctx()) end
  return registry
end

return mp
