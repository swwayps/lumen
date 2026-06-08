-- Pure RFC 6455 client-side WebSocket framing. Text frames only (CDP is JSON).
-- No IO here — encode returns a byte string, decode consumes a byte string.
local wsframe = {}

local schar, sbyte, ssub = string.char, string.byte, string.sub

-- Build a random 4-byte mask unless one is supplied (tests supply a fixed mask).
local function random_mask()
  return schar(math.random(0, 255), math.random(0, 255),
               math.random(0, 255), math.random(0, 255))
end

-- encode_text(payload [, mask]) -> masked client text frame (string)
function wsframe.encode_text(payload, mask)
  mask = mask or random_mask()
  local len = #payload
  local header
  if len <= 125 then
    header = schar(0x81, 0x80 | len)
  elseif len <= 0xFFFF then
    header = schar(0x81, 0x80 | 126, (len >> 8) & 0xFF, len & 0xFF)
  else
    -- 8-byte length; CDP payloads rarely reach here but handle it.
    header = schar(0x81, 0x80 | 127,
      0, 0, 0, 0,
      (len >> 24) & 0xFF, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF)
  end
  local out = { header, mask }
  local mb = { sbyte(mask, 1, 4) }
  for i = 1, len do
    out[#out + 1] = schar(sbyte(payload, i) ~ mb[((i - 1) % 4) + 1])
  end
  return table.concat(out)
end

-- decode_frame(buf) -> payload, opcode, rest, complete
-- Parses ONE unmasked server frame from the front of buf. If the buffer
-- doesn't yet hold a full frame, returns (nil, nil, buf, false).
function wsframe.decode_frame(buf)
  if #buf < 2 then return nil, nil, buf, false end
  local b1, b2 = sbyte(buf, 1), sbyte(buf, 2)
  local opcode = b1 & 0x0F
  local masked = (b2 & 0x80) ~= 0
  local len = b2 & 0x7F
  local offset = 2
  if len == 126 then
    if #buf < 4 then return nil, nil, buf, false end
    len = (sbyte(buf, 3) << 8) | sbyte(buf, 4)
    offset = 4
  elseif len == 127 then
    if #buf < 10 then return nil, nil, buf, false end
    len = 0
    for i = 3, 10 do len = (len << 8) | sbyte(buf, i) end
    offset = 10
  end
  local mask
  if masked then
    if #buf < offset + 4 then return nil, nil, buf, false end
    mask = { sbyte(buf, offset + 1, offset + 4) }
    offset = offset + 4
  end
  if #buf < offset + len then return nil, nil, buf, false end
  local payload = ssub(buf, offset + 1, offset + len)
  if masked then
    local out = {}
    for i = 1, len do
      out[i] = schar(sbyte(payload, i) ~ mask[((i - 1) % 4) + 1])
    end
    payload = table.concat(out)
  end
  local rest = ssub(buf, offset + len + 1)
  return payload, opcode, rest, true
end

return wsframe
