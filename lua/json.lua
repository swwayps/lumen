-- json shim. Prefers cjson (bundled in the shipped binary); falls back to a
-- tiny pure encoder/decoder sufficient for CDP messages and host tests.
local ok, cjson = pcall(require, "cjson")
if ok then
  -- cjson decodes ALL JSON numbers as Lua floats (lua_pushnumber), so an appid
  -- like 285900 becomes 285900.0 and tostring() yields "285900.0" -> broken URLs.
  -- Millennium's bridge delivered integers, so the backend assumes integers.
  -- Restore that contract: recursively convert integer-valued floats to ints.
  local mtype = math.type
  local function normalize(v)
    local t = type(v)
    if t == "number" then
      if mtype(v) == "float" and v == math.floor(v) and
         v >= -9.2e18 and v <= 9.2e18 then
        return math.tointeger(v) or v
      end
      return v
    elseif t == "table" then
      for k, val in pairs(v) do v[k] = normalize(val) end
      return v
    end
    return v
  end
  return {
    encode = cjson.encode,
    decode = function(s) return normalize(cjson.decode(s)) end,
  }
end

-- Minimal pure fallback (objects, arrays, strings, numbers, bool, null).
local json = {}

local function esc(s)
  return (s:gsub('[%z\1-\31\\"]', function(c)
    local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                  ['\r'] = '\\r', ['\t'] = '\\t' }
    return map[c] or string.format("\\u%04x", c:byte())
  end))
end

local function encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then return tostring(v)
  elseif t == "string" then return '"' .. esc(v) .. '"'
  elseif t == "table" then
    -- array if keys are 1..n
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    local is_arr = (#v == n)
    local parts = {}
    if is_arr then
      for i = 1, #v do parts[i] = encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, val in pairs(v) do
        parts[#parts + 1] = '"' .. esc(tostring(k)) .. '":' .. encode(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  error("cannot encode " .. t)
end

-- Decoder: small recursive-descent parser.
local function decode(str)
  local pos = 1
  local parse_value
  local function skip_ws() pos = str:find("[^ \t\r\n]", pos) or (#str + 1) end
  local function parse_string()
    pos = pos + 1 -- opening quote
    local out = {}
    while true do
      local c = str:sub(pos, pos)
      if c == '"' then pos = pos + 1; break
      elseif c == "\\" then
        local n = str:sub(pos + 1, pos + 1)
        local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if n == "u" then
          local hex = str:sub(pos + 2, pos + 5)
          out[#out + 1] = string.char(tonumber(hex, 16) % 256)
          pos = pos + 6
        else
          out[#out + 1] = map[n] or n
          pos = pos + 2
        end
      else out[#out + 1] = c; pos = pos + 1 end
    end
    return table.concat(out)
  end
  local function parse_number()
    local s, e = str:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    local num = tonumber(str:sub(s, e)); pos = e + 1; return num
  end
  parse_value = function()
    skip_ws()
    local c = str:sub(pos, pos)
    if c == "{" then
      pos = pos + 1; local obj = {}
      skip_ws()
      if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        skip_ws(); local key = parse_string()
        skip_ws(); pos = pos + 1 -- colon
        obj[key] = parse_value()
        skip_ws()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "}" then break end
      end
      return obj
    elseif c == "[" then
      pos = pos + 1; local arr = {}
      skip_ws()
      if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parse_value()
        skip_ws()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "]" then break end
      end
      return arr
    elseif c == '"' then return parse_string()
    elseif c == "t" then pos = pos + 4; return true
    elseif c == "f" then pos = pos + 5; return false
    elseif c == "n" then pos = pos + 4; return nil
    else return parse_number() end
  end
  return parse_value()
end

json.encode = encode
json.decode = decode
return json
