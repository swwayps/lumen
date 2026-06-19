-- slsconfig: reader/writer for slsteam-moon's ~/.config/SLSsteam/config.yaml,
-- backing the Lumen settings menu ("slsteam-moon" tab).
--
-- Scope: the SCALAR keys slsteam-moon reads in src/config.cpp::loadSettings
-- (bools, the FakeEmail string, FakeWalletBalance int, LogLevel enum). The
-- list/map keys (AdditionalApps, DlcData, FakeAppIds, ...) are intentionally
-- out of scope here — they have their own editors / are managed elsewhere.
--
-- Writes are line-preserving: set_key edits exactly the one key's value and
-- keeps comments, ordering and unrelated keys intact (slsteam-moon's yaml-cpp
-- loader is whitespace tolerant; the human-authored comments must survive).
-- IO is split out (read/write_key) so the parsing + editing logic stays pure
-- and host-testable without a real config file.
local slsconfig = {}

-- Seed once so the per-write temp suffix differs across processes (two fresh
-- sidecars would otherwise draw the same unseeded sequence and collide).
math.randomseed((os.time() % 100000) * 1000 + math.floor((os.clock() * 1e6) % 1000))
local write_seq = 0

-- SCHEMA drives both parsing (defaults + types) and the frontend rendering.
-- type: "bool" | "int" | "string" | "enum". Defaults mirror config.cpp.
slsconfig.SCHEMA = {
  { key = "PlayNotOwnedGames",      type = "bool",   default = false, level = "info",
    label = "Play not-owned games" },
  { key = "DisableFamilyShareLock", type = "bool",   default = true,  level = "normal",
    label = "Disable Family Share lock" },
  { key = "AutoFilterList",         type = "bool",   default = true,  level = "advanced",
    label = "Auto-filter app list" },
  { key = "UseWhitelist",           type = "bool",   default = false, level = "danger",
    label = "Use whitelist (instead of blacklist)" },
  { key = "SafeMode",               type = "bool",   default = false, level = "advanced",
    label = "Safe mode (disable on unknown steamclient)" },
  { key = "Notifications",          type = "bool",   default = true,  level = "normal",
    label = "Notifications (notify-send)" },
  { key = "NotifyInit",             type = "bool",   default = true,  level = "normal",
    label = "Notify on init" },
  { key = "WarnHashMissmatch",      type = "bool",   default = false, level = "advanced",
    label = "Warn on steamclient hash mismatch" },
  { key = "API",                    type = "bool",   default = true,  level = "advanced",
    label = "Enable control API (/tmp/SLSsteam.API)" },
  { key = "DisableCloud",           type = "bool",   default = true,  level = "normal",
    label = "Disable Steam Cloud" },
  { key = "ExtendedLogging",        type = "bool",   default = false, level = "advanced",
    label = "Extended logging (verbose)" },
  { key = "FakeEmail",              type = "string", default = "",    level = "normal",
    label = "Fake account e-mail (blank = off)" },
  { key = "FakeWalletBalance",      type = "int",    default = 0,     level = "normal",
    label = "Fake wallet balance (0 = off)" },
  { key = "LogLevel",               type = "enum",   default = 2,     level = "advanced",
    label = "Log level",
    options = { 0, 1, 2, 3, 4, 5, 6 },
    option_labels = { "Once (0)", "Debug (1)", "Info (2)", "NotifyShort (3)",
                      "NotifyLong (4)", "Warn (5)", "None (6)" } },
}

local TRUE_TOKENS  = { y = true, yes = true, ["true"] = true, on = true }
local FALSE_TOKENS = { n = true, no = true, ["false"] = true, off = true }

-- Detect an installed CloudRedirect hook. Its presence flips the sane default
-- for DisableCloud: CloudRedirect can only intercept cloud saves while Steam
-- Cloud is ENABLED, so when it is installed we default DisableCloud to OFF
-- (false). Without it we mirror slsteam-moon's own default of disabling cloud
-- (true). `home`/`exists` are injectable so this stays host-testable.
function slsconfig.has_cloudredirect(home, exists)
  home = home or os.getenv("HOME") or ""
  if home == "" then return false end
  exists = exists or function(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
  end
  return exists(home .. "/.local/share/CloudRedirect/cloud_redirect.so") and true or false
end

-- Effective default for a SCHEMA key. Every key uses its static SCHEMA default
-- except DisableCloud, which is CloudRedirect-aware (see has_cloudredirect):
-- CR present -> false (don't disable cloud), CR absent -> true. `cr_present`
-- may be passed explicitly (tests); nil means "detect now".
function slsconfig.default_for(key, cr_present)
  if key == "DisableCloud" then
    if cr_present == nil then cr_present = slsconfig.has_cloudredirect() end
    return not cr_present
  end
  for _, e in ipairs(slsconfig.SCHEMA) do
    if e.key == key then return e.default end
  end
  return nil
end

-- Find a top-level key's raw value (text after the colon, comment stripped),
-- or nil if the key is absent. Keys are top-level (no indent) in config.yaml.
local function raw_value(text, key)
  local pat = "\n" .. key .. "%s*:([^\n]*)"
  -- Also match the very first line (no preceding newline).
  local val = ("\n" .. text):match(pat)
  if not val then return nil end
  return val
end

local function strip_comment(s)
  return (s:gsub("#.*$", ""))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function to_bool(raw, default)
  local t = trim(strip_comment(raw)):lower()
  if TRUE_TOKENS[t]  then return true  end
  if FALSE_TOKENS[t] then return false end
  return default
end

local function to_int(raw, default)
  return tonumber(trim(strip_comment(raw))) or default
end

local function to_string(raw)
  local s = trim(strip_comment(raw))
  -- Strip a single layer of surrounding single or double quotes.
  local inner = s:match('^"(.*)"$') or s:match("^'(.*)'$")
  return inner or s
end

-- parse(text[, cr_present]) -> { Key = typedValue } for every SCHEMA key
-- (defaults applied when the key is absent or unparseable). `cr_present` is
-- forwarded to default_for so the DisableCloud default is CloudRedirect-aware;
-- nil means "detect now".
function slsconfig.parse(text, cr_present)
  text = text or ""
  local out = {}
  for _, entry in ipairs(slsconfig.SCHEMA) do
    local dflt = slsconfig.default_for(entry.key, cr_present)
    local raw = raw_value(text, entry.key)
    if raw == nil then
      out[entry.key] = dflt
    elseif entry.type == "bool" then
      out[entry.key] = to_bool(raw, dflt)
    elseif entry.type == "int" or entry.type == "enum" then
      out[entry.key] = to_int(raw, dflt)
    else
      out[entry.key] = to_string(raw)
    end
  end
  return out
end

local function type_of(key)
  for _, e in ipairs(slsconfig.SCHEMA) do
    if e.key == key then return e.type end
  end
  return nil
end

-- Render a Lua value to its YAML token per the key's type.
local function format_value(key, value)
  local t = type_of(key)
  if t == "bool" then
    return value and "yes" or "no"
  elseif t == "string" then
    return '"' .. tostring(value) .. '"'
  else -- int / enum
    return tostring(math.floor(tonumber(value) or 0))
  end
end

-- set_key(text, key, value) -> new_text. Replaces the one key's value in place
-- (preserving any inline comment), or appends "Key: value" if the key is
-- absent. Pure: no IO.
function slsconfig.set_key(text, key, value)
  text = text or ""
  local token = format_value(key, value)
  local replaced = false

  local lines = {}
  local had_trailing_nl = (#text > 0 and text:sub(-1) == "\n")
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  if had_trailing_nl then lines[#lines] = nil end

  for i, line in ipairs(lines) do
    local prefix = line:match("^(" .. key .. "%s*:)")
    if prefix then
      local comment = line:match("(#.*)$")
      local new = prefix .. " " .. token
      if comment then new = new .. "   " .. comment end
      lines[i] = new
      replaced = true
      break
    end
  end

  if not replaced then
    lines[#lines + 1] = key .. ": " .. token
  end

  local body = table.concat(lines, "\n")
  if had_trailing_nl or not replaced then body = body .. "\n" end
  return body
end

-- ── IO layer ────────────────────────────────────────────────────────────────
-- Kept thin and separate from the pure parse/set_key logic above.

function slsconfig.default_path()
  local home = os.getenv("HOME") or ""
  if home == "" then return nil end
  return home .. "/.config/SLSsteam/config.yaml"
end

-- read(path[, cr_present]) -> values table. A missing/unreadable file yields
-- all defaults (slsteam-moon itself falls back to defaults on a missing
-- config). `cr_present` is forwarded to parse for the DisableCloud default.
function slsconfig.read(path, cr_present)
  if not path then return slsconfig.parse("", cr_present) end
  local f = io.open(path, "rb")
  if not f then return slsconfig.parse("", cr_present) end
  local data = f:read("*a") or ""
  f:close()
  return slsconfig.parse(data, cr_present)
end

-- Count how many SCHEMA keys appear in the text (a cheap "does this look like a
-- real config?" check) and whether a specific key is present.
local function count_known_keys(text)
  local n = 0
  for _, e in ipairs(slsconfig.SCHEMA) do
    if raw_value(text, e.key) ~= nil then n = n + 1 end
  end
  return n
end

-- write_key(path, key, value) -> ok, err. Edits one key in place via an atomic
-- temp-file rename so slsteam-moon's inotify watch fires once on a complete
-- file. The file must already exist (slsteam-moon creates it on first launch).
--
-- SAFETY: never clobber a config we failed to read. If the read is empty, or
-- looks nothing like a config (too few known keys) AND we'd be appending a new
-- key, refuse — otherwise a racy/empty read would let set_key "append" onto an
-- empty string and replace the whole file with two lines (data loss). The temp
-- file name is unique per call so concurrent writers can't share/clobber it.
function slsconfig.write_key(path, key, value)
  if not path then return false, "no path" end
  local f = io.open(path, "rb")
  if not f then return false, "config.yaml not found" end
  local data = f:read("*a") or ""
  f:close()

  if data == "" then
    return false, "config empty/unreadable; refusing to overwrite"
  end
  local key_present = raw_value(data, key) ~= nil
  if not key_present and count_known_keys(data) < 3 then
    return false, "config does not look valid; refusing to append"
  end

  local out = slsconfig.set_key(data, key, value)

  local tmp = string.format("%s.tmp.lumen.%d.%d.%d", path,
    os.time(), (write_seq), math.random(100000, 999999))
  write_seq = write_seq + 1
  local w, werr = io.open(tmp, "wb")
  if not w then return false, werr or "open failed" end
  w:write(out)
  w:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr or "rename failed"
  end
  return true
end

-- reset_to_defaults(path[, cr_present]) -> ok, err. Rewrites EVERY SCHEMA key
-- to its effective default in one atomic write, preserving comments, ordering
-- and unrelated keys (e.g. AdditionalApps). The DisableCloud default is
-- CloudRedirect-aware (default_for): OFF when CloudRedirect is installed, ON
-- otherwise. Same no-clobber guard as write_key: refuse on an empty/unreadable
-- file or one that doesn't look like a real config.
function slsconfig.reset_to_defaults(path, cr_present)
  if not path then return false, "no path" end
  local f = io.open(path, "rb")
  if not f then return false, "config.yaml not found" end
  local data = f:read("*a") or ""
  f:close()

  if data == "" then
    return false, "config empty/unreadable; refusing to overwrite"
  end
  if count_known_keys(data) < 3 then
    return false, "config does not look valid; refusing to reset"
  end

  if cr_present == nil then cr_present = slsconfig.has_cloudredirect() end
  local out = data
  for _, entry in ipairs(slsconfig.SCHEMA) do
    out = slsconfig.set_key(out, entry.key, slsconfig.default_for(entry.key, cr_present))
  end

  local tmp = string.format("%s.tmp.lumen.%d.%d.%d", path,
    os.time(), (write_seq), math.random(100000, 999999))
  write_seq = write_seq + 1
  local w, werr = io.open(tmp, "wb")
  if not w then return false, werr or "open failed" end
  w:write(out)
  w:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr or "rename failed"
  end
  return true
end

return slsconfig
