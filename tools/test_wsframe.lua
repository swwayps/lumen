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

print("test_wsframe: ALL PASS")
