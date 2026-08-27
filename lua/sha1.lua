-- SHA-1 (RFC 3174) in pure Lua 5.4 integer arithmetic.
--
-- Present for one reason: RFC 6455 defines Sec-WebSocket-Accept as
-- base64(sha1(key .. GUID)), so validating the CDP handshake requires SHA-1.
-- It is NOT used as a security primitive anywhere else; nothing here relies on
-- SHA-1 being collision resistant.
local sha1 = {}

local schar, sbyte = string.char, string.byte

local function rol32(v, n)
  v = v & 0xFFFFFFFF
  return ((v << n) | (v >> (32 - n))) & 0xFFFFFFFF
end

-- raw(msg) -> the 20-byte binary digest.
function sha1.raw(msg)
  msg = tostring(msg or "")
  local bitlen = #msg * 8
  -- Pad: 0x80, then zeros until length ≡ 56 (mod 64), then the 64-bit length.
  local pad = 56 - ((#msg + 1) % 64)
  if pad < 0 then pad = pad + 64 end
  local tail = {}
  for i = 8, 1, -1 do
    tail[#tail + 1] = schar((bitlen >> ((i - 1) * 8)) & 0xFF)
  end
  local data = msg .. "\128" .. string.rep("\0", pad) .. table.concat(tail)

  local h0, h1, h2, h3, h4 =
    0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local w = {}
  for block = 1, #data, 64 do
    for i = 0, 15 do
      local o = block + i * 4
      w[i] = (sbyte(data, o) << 24) | (sbyte(data, o + 1) << 16)
        | (sbyte(data, o + 2) << 8) | sbyte(data, o + 3)
    end
    for i = 16, 79 do
      w[i] = rol32(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = (b & c) | ((~b & 0xFFFFFFFF) & d); k = 0x5A827999
      elseif i < 40 then
        f = b ~ c ~ d; k = 0x6ED9EBA1
      elseif i < 60 then
        f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
      else
        f = b ~ c ~ d; k = 0xCA62C1D6
      end
      local temp = (rol32(a, 5) + (f & 0xFFFFFFFF) + e + k + w[i]) & 0xFFFFFFFF
      e = d; d = c; c = rol32(b, 30); b = a; a = temp
    end
    h0 = (h0 + a) & 0xFFFFFFFF
    h1 = (h1 + b) & 0xFFFFFFFF
    h2 = (h2 + c) & 0xFFFFFFFF
    h3 = (h3 + d) & 0xFFFFFFFF
    h4 = (h4 + e) & 0xFFFFFFFF
  end

  local out = {}
  for _, h in ipairs({ h0, h1, h2, h3, h4 }) do
    out[#out + 1] = schar((h >> 24) & 0xFF, (h >> 16) & 0xFF,
      (h >> 8) & 0xFF, h & 0xFF)
  end
  return table.concat(out)
end

-- hex(msg) -> the digest as 40 lowercase hex characters.
function sha1.hex(msg)
  return (sha1.raw(msg):gsub(".",
    function(ch) return string.format("%02x", ch:byte()) end))
end

return sha1
