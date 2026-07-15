-- Pure base64 encoder. Used by the utils shim (utils.base64_encode).
local b64 = {}
local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function b64.encode(data)
  local out = {}
  local n = #data
  local i = 1
  while i <= n do
    local b1 = data:byte(i)
    local b2 = (i + 1 <= n) and data:byte(i + 1) or nil
    local b3 = (i + 2 <= n) and data:byte(i + 2) or nil
    local n1 = b1 >> 2
    local n2 = ((b1 & 0x03) << 4) | ((b2 or 0) >> 4)
    local n3 = b2 and (((b2 & 0x0F) << 2) | ((b3 or 0) >> 6)) or nil
    local n4 = b3 and (b3 & 0x3F) or nil
    out[#out + 1] = A:sub(n1 + 1, n1 + 1)
    out[#out + 1] = A:sub(n2 + 1, n2 + 1)
    out[#out + 1] = n3 and A:sub(n3 + 1, n3 + 1) or "="
    out[#out + 1] = n4 and A:sub(n4 + 1, n4 + 1) or "="
    i = i + 3
  end
  return table.concat(out)
end

function b64.decode(data)
  if type(data) ~= "string" then return nil, "base64 must be a string" end
  data = data:gsub("%s", "")
  if #data % 4 ~= 0 or data:find("[^A-Za-z0-9+/=]") then return nil, "invalid base64" end
  local rev = {}; for i = 1, #A do rev[A:sub(i,i)] = i - 1 end
  local out = {}
  for i = 1, #data, 4 do
    local c1,c2,c3,c4 = data:sub(i,i),data:sub(i+1,i+1),data:sub(i+2,i+2),data:sub(i+3,i+3)
    if not rev[c1] or not rev[c2] then return nil, "invalid base64" end
    local n = (rev[c1] << 18) | (rev[c2] << 12) |
      ((c3 == "=" and 0 or rev[c3] or 0) << 6) | (c4 == "=" and 0 or rev[c4] or 0)
    out[#out+1] = string.char((n >> 16) & 255)
    if c3 ~= "=" then out[#out+1] = string.char((n >> 8) & 255) end
    if c4 ~= "=" then out[#out+1] = string.char(n & 255) end
  end
  return table.concat(out)
end

return b64
