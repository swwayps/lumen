-- Run: lua5.4 tools/test_httpresp.lua
package.path = "lua/?.lua;" .. package.path
local h = require("httpresp")

local function eq(a, b, m)
  if a ~= b then error(string.format("FAIL %s: got %q expected %q", m or "", tostring(a), tostring(b))) end
end

-- 1. content_length parses the header (case-insensitive).
eq(h.content_length("HTTP/1.1 200 OK\r\nContent-Length: 407\r\nContent-Type: x"), 407, "CL parse")
eq(h.content_length("HTTP/1.1 200 OK\r\ncontent-length:12"), 12, "CL lowercase no-space")
eq(h.content_length("HTTP/1.1 200 OK\r\nContent-Type: x"), nil, "no CL -> nil")

-- 2. headers_complete splits at CRLFCRLF and returns header block + body start.
do
  local hdr, body = h.headers_complete("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc")
  eq(hdr, "HTTP/1.1 200 OK\r\nContent-Length: 3", "header block")
  eq(body, "abc", "body remainder")
end

-- 3. headers_complete returns nil when headers not yet whole.
eq(h.headers_complete("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n"), nil, "incomplete headers")

print("test_httpresp: ALL PASS")
