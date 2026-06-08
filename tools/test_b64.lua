package.path = "lua/?.lua;" .. package.path
local b64 = require("b64")
local function eq(a, b, m) if a ~= b then error("FAIL "..(m or "")..": "..tostring(a).." ~= "..tostring(b)) end end
eq(b64.encode(""), "", "empty")
eq(b64.encode("f"), "Zg==", "1 byte pad2")
eq(b64.encode("fo"), "Zm8=", "2 byte pad1")
eq(b64.encode("foo"), "Zm9v", "3 byte nopad")
eq(b64.encode("foobar"), "Zm9vYmFy", "6 byte")
eq(b64.encode("Man"), "TWFu", "classic")
print("test_b64: ALL PASS")
