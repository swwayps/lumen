-- Run: lua5.4 tools/test_sha256.lua
-- Pure-Lua SHA-256 used by the Cloud Saves tab for the PKCE S256 code
-- challenge. Deterministic NIST test vectors; also checks the raw digest is
-- exactly 32 bytes (so base64url of it produces the right challenge).
package.path = "lua/?.lua;" .. package.path
local sha256 = require("sha256")

local function eq(got, want, msg)
  if got ~= want then
    error("FAIL: " .. (msg or "") .. "\n  got  = " .. tostring(got) ..
          "\n  want = " .. tostring(want))
  end
end

-- Known-answer vectors (FIPS 180-4 / RFC 6234).
eq(sha256.hex(""),
   "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
   "empty string")
eq(sha256.hex("abc"),
   "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
   "abc")
eq(sha256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
   "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
   "56-byte message (two blocks)")

-- A message longer than one 64-byte block with a length that forces padding
-- into a second block.
local million_a = string.rep("a", 1000)
eq(#sha256.hex(million_a), 64, "hex is 64 chars regardless of input length")

-- Raw digest must be exactly 32 bytes (needed for base64url PKCE challenge).
local raw = sha256.digest("abc")
eq(#raw, 32, "raw digest is 32 bytes")
-- hex(x) must equal hex-of-digest(x).
local hexed = raw:gsub(".", function(c) return string.format("%02x", c:byte()) end)
eq(hexed, sha256.hex("abc"), "digest and hex agree")

print("test_sha256: ALL PASS")
