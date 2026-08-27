-- Run: lua5.4 tools/test_wsframe.lua   (from repo root)
package.path = "lua/?.lua;" .. package.path
local ws = require("wsframe")

local function eq(a, b, msg)
  if a ~= b then
    error(string.format("FAIL %s: got %q expected %q", msg or "", tostring(a), tostring(b)))
  end
end

-- 1. encode_text produces a masked client frame with the right header.
do
  -- Force a known mask so the output is deterministic.
  local frame = ws.encode_text("hi", "\1\2\3\4")
  eq(frame:byte(1), 0x81, "fin+text opcode")
  eq(frame:byte(2), 0x82, "masked + len 2")          -- 0x80 | 2
  eq(frame:sub(3, 6), "\1\2\3\4", "mask bytes")
  -- "hi" = 0x68,0x69 XOR mask[0],mask[1] = 0x69,0x6b
  eq(frame:byte(7), 0x68 ~ 0x01, "masked payload[1]")
  eq(frame:byte(8), 0x69 ~ 0x02, "masked payload[2]")
end

-- 2. decode_frame round-trips an unmasked server text frame.
do
  -- server frame: 0x81, len=5 (unmasked), "hello"
  local buf = string.char(0x81, 0x05) .. "hello"
  local msg, opcode, rest, complete = ws.decode_frame(buf)
  eq(complete, true, "complete")
  eq(opcode, 0x1, "text opcode")
  eq(msg, "hello", "payload")
  eq(rest, "", "no trailing bytes")
end

-- 3. decode_frame reports incomplete when the buffer is short.
do
  local buf = string.char(0x81, 0x05) .. "hel"   -- claims 5, only 3 present
  local _, _, _, complete = ws.decode_frame(buf)
  eq(complete, false, "incomplete frame detected")
end

-- 4. decode_frame handles the 126 extended-length path.
do
  local payload = string.rep("x", 200)
  local len = #payload
  local buf = string.char(0x81, 126, math.floor(len / 256), len % 256) .. payload
  local msg, opcode, _, complete = ws.decode_frame(buf)
  eq(complete, true, "extended-len complete")
  eq(opcode, 0x1, "extended-len opcode")
  eq(#msg, 200, "extended-len payload size")
end

-- ── RFC 6455 handshake validation ───────────────────────────────────────────
-- The client used to send a FIXED Sec-WebSocket-Key and accept any response
-- containing the substring "101" anywhere. That accepts a peer that never proved
-- it speaks WebSocket at all, and accepts a canned reply recorded from someone
-- else's handshake. Now the key is random per connection and the response's
-- Sec-WebSocket-Accept must be the digest of the key we actually sent.
do
  local function ok(c, m) if not c then error("FAIL: " .. (m or "")) end end

  -- RFC 6455 §1.3 worked example.
  ok(ws.expected_accept("dGhlIHNhbXBsZSBub25jZQ==")
      == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455 accept vector")

  -- new_key() is 16 random bytes, base64-encoded (24 chars, "==" padded), and
  -- differs per call.
  local seen = {}
  for _ = 1, 16 do
    local k = ws.new_key()
    ok(#k == 24, "key is 24 base64 characters, got " .. #k)
    ok(k:sub(-2) == "==", "key encodes exactly 16 bytes")
    ok(seen[k] == nil, "keys do not repeat")
    seen[k] = true
  end

  local KEY = "dGhlIHNhbXBsZSBub25jZQ=="
  local GOOD = "HTTP/1.1 101 Switching Protocols\r\n"
    .. "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    .. "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"

  ok(ws.handshake_ok(GOOD, KEY) == true, "matching accept passes")

  -- Header name matching is case-insensitive (servers vary).
  ok(ws.handshake_ok(
    GOOD:gsub("Sec%-WebSocket%-Accept", "sec-websocket-accept"), KEY) == true,
    "lowercased header name accepted")

  -- Wrong digest: the peer did not see our key.
  ok(ws.handshake_ok(
    GOOD:gsub("s3pPLMBiTxaQ9kYGzzhZRbK%+xOo=", "AAAAAAAAAAAAAAAAAAAAAAAAAAA="),
    KEY) == false, "wrong accept rejected")

  -- Right digest for a DIFFERENT key: a replayed handshake.
  ok(ws.handshake_ok(GOOD, ws.new_key()) == false,
    "accept for another key rejected")

  -- Missing the header entirely.
  ok(ws.handshake_ok(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n", KEY)
    == false, "missing accept header rejected")

  -- Not a 101 at all, even when the body happens to contain "101".
  ok(ws.handshake_ok(
    "HTTP/1.1 200 OK\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
    .. "\r\nrequest 101 accepted", KEY) == false, "200 with a stray 101 rejected")
  ok(ws.handshake_ok(
    "HTTP/1.1 404 Not Found\r\nX-Trace: 101101\r\n\r\n", KEY) == false,
    "404 rejected")

  -- Degenerate inputs.
  ok(ws.handshake_ok("", KEY) == false, "empty response rejected")
  ok(ws.handshake_ok(GOOD, "") == false, "empty key accepts nothing")
  ok(ws.handshake_ok(GOOD, nil) == false, "nil key accepts nothing")
end

print("test_wsframe: ALL PASS")
