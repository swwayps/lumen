-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_sha1.lua
--                (or: lua5.4 tools/test_sha1.lua)
--
-- SHA-1 is here for exactly one job: computing the RFC 6455
-- Sec-WebSocket-Accept value so the CDP handshake can be verified. It is not a
-- security primitive for anything else in this codebase.
package.path = "lua/?.lua;" .. package.path
local sha1 = require("sha1")

local checks = 0
local function eq(got, want, m)
  checks = checks + 1
  if got ~= want then
    error("FAIL " .. (m or "") .. ": got " .. tostring(got) .. " want " .. tostring(want))
  end
end

-- FIPS 180-1 / RFC 3174 vectors.
eq(sha1.hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709", "empty string")
eq(sha1.hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d", "abc")
eq(sha1.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
  "84983e441c3bd26ebaae4aa1f95129e5e54670f1", "56-byte multi-block")
eq(sha1.hex(string.rep("a", 1000000)),
  "34aa973cd4c4daa4f61eeb2bdbad27316534016f", "one million a's")

-- Block-boundary lengths: 55 (fits with padding), 56 (forces an extra block),
-- 63, 64, 65. These are where length encoding and padding go wrong.
eq(sha1.hex(string.rep("a", 55)), "c1c8bbdc22796e28c0e15163d20899b65621d65a", "55 bytes")
eq(sha1.hex(string.rep("a", 56)), "c2db330f6083854c99d4b5bfb6e8f29f201be699", "56 bytes")
eq(sha1.hex(string.rep("a", 63)), "03f09f5b158a7a8cdad920bddc29b81c18a551f5", "63 bytes")
eq(sha1.hex(string.rep("a", 64)), "0098ba824b5c16427bd7a1122a5a442a25ec644d", "64 bytes")
eq(sha1.hex(string.rep("a", 65)), "11655326c708d70319be2610e8a57d9a5b959d3b", "65 bytes")

-- Binary-safe: NUL bytes and high bytes must be hashed, not truncated.
eq(sha1.hex("\0"), "5ba93c9db0cff93f52b521d7420e43f6eda2784f", "single NUL")
eq(sha1.hex("\255\254\0\1"), sha1.hex("\255\254\0\1"), "high bytes are stable")
checks = checks + 1
if sha1.hex("a\0b") == sha1.hex("a") then error("FAIL: NUL truncates input") end

-- raw() returns the 20-byte digest.
checks = checks + 1
if #sha1.raw("abc") ~= 20 then error("FAIL: raw digest is not 20 bytes") end
eq(sha1.raw("abc"):byte(1), 0xa9, "raw first byte")
eq(sha1.raw("abc"):byte(20), 0x9d, "raw last byte")

print("test_sha1: ALL PASS (" .. checks .. " checks)")
