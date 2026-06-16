-- Run via the built binary:
--   LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_cefport.lua
--
-- cefport.lua resolves which TCP port Steam's CEF endpoint is on: slsteam-moon
-- rewrites Steam's hard-coded 8080 to a free loopback port and writes it to
-- ~/.local/share/Lumen/cef_port; the injector reads it from there, falling back
-- to 8080 (vanilla Steam / slsteam-moon off). These tests cover the pure parse
-- and the resolve(read_fn, fallback) wrapper exhaustively.
package.path = "lua/?.lua;" .. package.path
local cefport = require("cefport")

local fails = 0
local checks = 0
local function ok(cond, name)
  checks = checks + 1
  if cond then io.write("ok " .. name .. "\n")
  else io.write("FAIL " .. name .. "\n"); fails = fails + 1 end
end

-- ── parse_port: accepted ────────────────────────────────────────────────────
ok(cefport.parse_port("54017") == 54017, "plain valid")
ok(cefport.parse_port("54017\n") == 54017, "trailing newline")
ok(cefport.parse_port("  8123  ") == 8123, "surrounding whitespace")
ok(cefport.parse_port("\t8123\r\n") == 8123, "tabs/CRLF")
ok(cefport.parse_port("1024") == 1024, "low boundary")
ok(cefport.parse_port("65535") == 65535, "high boundary")
ok(cefport.parse_port("08080") == 8080, "leading zero decimal")

-- ── parse_port: rejected ────────────────────────────────────────────────────
ok(cefport.parse_port("1023") == nil, "below range")
ok(cefport.parse_port("65536") == nil, "above range")
ok(cefport.parse_port("70000") == nil, "way above range")
ok(cefport.parse_port("0") == nil, "zero")
ok(cefport.parse_port("-5") == nil, "negative")
ok(cefport.parse_port("80.5") == nil, "non-integer")
ok(cefport.parse_port("8080abc") == nil, "trailing garbage")
ok(cefport.parse_port("abc") == nil, "letters")
ok(cefport.parse_port("") == nil, "empty")
ok(cefport.parse_port("   ") == nil, "whitespace only")
ok(cefport.parse_port(nil) == nil, "nil")
ok(cefport.parse_port(8080) == nil, "number (non-string) rejected")
ok(cefport.parse_port({}) == nil, "table rejected")

-- ── resolve(read_fn, fallback) ──────────────────────────────────────────────
do local p, ff = cefport.resolve(function() return "49777" end, 8080)
   ok(p == 49777 and ff == true, "valid file content wins") end
do local p, ff = cefport.resolve(function() return "nonsense" end, 8080)
   ok(p == 8080 and ff == false, "garbage -> fallback") end
do local p, ff = cefport.resolve(function() return nil end, 8080)
   ok(p == 8080 and ff == false, "missing -> fallback") end
do local p, ff = cefport.resolve(function() return "70000" end, 8080)
   ok(p == 8080 and ff == false, "out-of-range -> fallback") end
do local p, ff = cefport.resolve(function() error("io boom") end, 8080)
   ok(p == 8080 and ff == false, "read error caught -> fallback") end
do local p, ff = cefport.resolve(function() return 49777 end, 8080)
   ok(p == 8080 and ff == false, "non-string content -> fallback") end
do local p, ff = cefport.resolve(function() return "12345" end, 9001)
   ok(p == 12345 and ff == true, "custom fallback unused when file valid") end
do local p, ff = cefport.resolve(function() return nil end, 9001)
   ok(p == 9001 and ff == false, "custom fallback honoured") end
do local p, ff = cefport.resolve(function() return nil end)
   ok(p == cefport.FALLBACK and p == 8080 and ff == false, "default fallback is 8080") end

-- ── read_contract: end-to-end against a real temp file via HOME override ─────
do
  local orig = os.getenv
  local home = "/tmp/lumen_cefport_test_" .. tostring(os.time())
  os.execute("mkdir -p '" .. home .. "/.local/share/Lumen'")
  os.getenv = function(k) if k == "HOME" then return home end return orig(k) end

  -- no file yet
  ok(cefport.read_contract() == nil, "read_contract: nil when file absent")
  local p1 = cefport.resolve(cefport.read_contract, 8080)
  ok(p1 == 8080, "resolve(read_contract): fallback when file absent")

  -- write a real contract file
  local f = io.open(home .. "/.local/share/Lumen/cef_port", "w")
  f:write("51515\n"); f:close()
  ok(cefport.read_contract() == "51515", "read_contract: reads first line")
  local p2, ff2 = cefport.resolve(cefport.read_contract, 8080)
  ok(p2 == 51515 and ff2 == true, "resolve(read_contract): reads real file")

  os.getenv = orig
  os.execute("rm -rf '" .. home .. "'")
end

if fails == 0 then io.write("\ntest_cefport: ALL PASS (" .. checks .. " checks)\n")
else io.write("\n" .. fails .. "/" .. checks .. " FAILED\n"); os.exit(1) end
