-- Pure-Lua SHA-256 (FIPS 180-4). Compute-only, used once per cloud-save login
-- to build the PKCE S256 code challenge (base64url(sha256(code_verifier))).
-- Lumen ships no crypto lib; this keeps the OAuth flow self-contained with no
-- new dependency. Uses Lua 5.4 native 64-bit integer bit ops, masked to 32 bit.
local sha256 = {}

local MASK = 0xffffffff

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- 32-bit right-rotate.
local function rrotate(x, n)
  return ((x >> n) | (x << (32 - n))) & MASK
end

-- Pad the message per the spec and split into 512-bit (64-byte) blocks; returns
-- the padded string (length a multiple of 64).
local function pad(msg)
  local len = #msg
  local bitlen = len * 8
  -- append 0x80, then zeros until length ≡ 56 (mod 64), then 8-byte big-endian
  -- bit length.
  local pad_len = (56 - (len + 1) % 64) % 64
  local suffix = string.char(0x80) .. string.rep("\0", pad_len)
  -- 64-bit big-endian length. Message lengths here are tiny (<2^32 bytes), so
  -- the high 32 bits are zero; still emit all 8 bytes.
  local hi = math.floor(bitlen / 0x100000000)
  local lo = bitlen & MASK
  local function be32(n)
    return string.char((n >> 24) & 0xff, (n >> 16) & 0xff,
                       (n >> 8) & 0xff, n & 0xff)
  end
  return msg .. suffix .. be32(hi) .. be32(lo)
end

-- sha256.digest(msg) -> 32-byte raw binary digest.
function sha256.digest(msg)
  msg = msg or ""
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  local data = pad(msg)
  local w = {}
  for base = 1, #data, 64 do
    -- prepare message schedule
    for i = 0, 15 do
      local off = base + i * 4
      w[i + 1] = ((data:byte(off) << 24) | (data:byte(off + 1) << 16) |
                  (data:byte(off + 2) << 8) | data:byte(off + 3)) & MASK
    end
    for i = 17, 64 do
      local s15 = w[i - 15]
      local s2 = w[i - 2]
      local s0 = rrotate(s15, 7) ~ rrotate(s15, 18) ~ (s15 >> 3)
      local s1 = rrotate(s2, 17) ~ rrotate(s2, 19) ~ (s2 >> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & MASK
    end

    local a, b, c, d = h0, h1, h2, h3
    local e, f, g, h = h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = rrotate(e, 6) ~ rrotate(e, 11) ~ rrotate(e, 25)
      local ch = (e & f) ~ ((~e & MASK) & g)
      local t1 = (h + S1 + ch + K[i] + w[i]) & MASK
      local S0 = rrotate(a, 2) ~ rrotate(a, 13) ~ rrotate(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local t2 = (S0 + maj) & MASK
      h = g; g = f; f = e
      e = (d + t1) & MASK
      d = c; c = b; b = a
      a = (t1 + t2) & MASK
    end

    h0 = (h0 + a) & MASK; h1 = (h1 + b) & MASK
    h2 = (h2 + c) & MASK; h3 = (h3 + d) & MASK
    h4 = (h4 + e) & MASK; h5 = (h5 + f) & MASK
    h6 = (h6 + g) & MASK; h7 = (h7 + h) & MASK
  end

  local function be(n)
    return string.char((n >> 24) & 0xff, (n >> 16) & 0xff,
                       (n >> 8) & 0xff, n & 0xff)
  end
  return be(h0) .. be(h1) .. be(h2) .. be(h3) ..
         be(h4) .. be(h5) .. be(h6) .. be(h7)
end

-- sha256.hex(msg) -> 64-char lowercase hex digest.
function sha256.hex(msg)
  return (sha256.digest(msg):gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

return sha256
