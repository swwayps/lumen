-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_nonce.lua
--                (or: lua5.4 tools/test_nonce.lua)
package.path = "lua/?.lua;" .. package.path
local nonce = require("nonce")

local checks = 0
local function ok(c, m)
  checks = checks + 1
  if not c then error("FAIL: " .. (m or "")) end
end

-- bytes(n) returns exactly n bytes.
do
  ok(#nonce.bytes(1) == 1, "one byte")
  ok(#nonce.bytes(16) == 16, "sixteen bytes")
  ok(#nonce.bytes(32) == 32, "thirty-two bytes")
end

-- bytes() rejects non-positive / absurd lengths rather than returning short data.
do
  ok(nonce.bytes(0) == nil, "zero length refused")
  ok(nonce.bytes(-1) == nil, "negative length refused")
  ok(nonce.bytes("x") == nil, "non-number refused")
end

-- hex(n) returns 2n lowercase hex characters.
do
  local h = nonce.hex(16)
  ok(#h == 32, "hex is two chars per byte")
  ok(h:match("^[0-9a-f]+$") ~= nil, "hex charset only")
end

-- Successive values differ. Two 16-byte draws colliding would mean the source is
-- not random at all, which is exactly what this guards against.
do
  local seen = {}
  for _ = 1, 32 do
    local h = nonce.hex(16)
    ok(seen[h] == nil, "no repeat within 32 draws")
    seen[h] = true
  end
end

-- The fallback path (no /dev/urandom) still produces full-length distinct
-- values, so a hardened container without /dev/urandom degrades in quality but
-- never returns a short or empty token that would disable a comparison.
do
  local a = nonce.bytes(16, function() return nil end)
  local b = nonce.bytes(16, function() return nil end)
  ok(a and #a == 16, "fallback keeps the requested length")
  ok(b and #b == 16, "fallback keeps the requested length (second draw)")
  ok(a ~= b, "fallback draws differ")
end

-- A reader that returns short data is topped up rather than trusted.
do
  local v = nonce.bytes(16, function(n) return string.rep("A", math.min(n, 4)) end)
  ok(v and #v == 16, "short read topped up to the requested length")
end

print("test_nonce: ALL PASS (" .. checks .. " checks)")
