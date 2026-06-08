-- Pure HTTP/1.1 response helpers. CEF's DevTools HTTP server uses keep-alive
-- (Content-Length, no "Connection: close"), so a naive read-until-close hangs.
-- These pure functions let the IO layer read headers then exactly Content-Length
-- body bytes. No IO here.
local httpresp = {}

-- content_length(header_block) -> number or nil
-- header_block is the raw header text (everything before the blank line).
function httpresp.content_length(header_block)
  local n = header_block:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
  return n and tonumber(n) or nil
end

-- headers_complete(buf) -> header_block, body_so_far  OR  nil if headers not yet whole
-- Splits a received buffer at the first CRLFCRLF.
function httpresp.headers_complete(buf)
  local s, e = buf:find("\r\n\r\n", 1, true)
  if not s then return nil end
  return buf:sub(1, s - 1), buf:sub(e + 1)
end

return httpresp
