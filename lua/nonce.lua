-- Random token source. Used wherever Lumen needs an unguessable value: the
-- per-connection CDP binding token, the WebSocket handshake key, and temporary
-- file names.
--
-- /dev/urandom is the only source we trust. When it is unavailable (a hardened
-- container, a broken mount) we degrade to math.random rather than returning a
-- short or empty value: a caller comparing tokens must never end up comparing
-- "" == "", which would turn the check into a no-op.
local nonce = {}

local seeded = false
local counter = 0

local function weak_bytes(n)
  if not seeded then
    seeded = true
    math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
  end
  -- A per-draw counter keeps successive values distinct even when os.clock()
  -- has not advanced between two calls in the same tick.
  counter = counter + 1
  local t = {}
  for i = 1, n do
    t[i] = string.char((math.random(0, 255) + counter * i) % 256)
  end
  return table.concat(t)
end

-- bytes(n, read_urandom) -> n random bytes, or nil for an invalid length.
-- `read_urandom` is injectable for tests: it takes a byte count and returns a
-- string (possibly short or nil).
function nonce.bytes(n, read_urandom)
  if type(n) ~= "number" or n ~= math.floor(n) or n < 1 or n > 4096 then
    return nil
  end
  local out = ""
  if read_urandom == nil then
    local f = io.open("/dev/urandom", "rb")
    if f then
      local ok, chunk = pcall(f.read, f, n)
      if ok and type(chunk) == "string" then out = chunk end
      f:close()
    end
  else
    local ok, chunk = pcall(read_urandom, n)
    if ok and type(chunk) == "string" then out = chunk end
  end
  if #out > n then out = out:sub(1, n) end
  if #out < n then out = out .. weak_bytes(n - #out) end
  return out
end

-- hex(n, read_urandom) -> 2n lowercase hex characters from n random bytes.
function nonce.hex(n, read_urandom)
  local raw = nonce.bytes(n, read_urandom)
  if not raw then return nil end
  return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

return nonce
