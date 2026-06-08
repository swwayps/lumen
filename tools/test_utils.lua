package.path = "lua/?.lua;" .. package.path
local utils = require("utils")
local function ok(c, m) if not c then error("FAIL: "..(m or "")) end end
local p = "/tmp/lumen_utils_test.txt"
os.remove(p)
ok(utils.write_file(p, "ab"), "write")
ok(utils.read_file(p) == "ab", "read")
utils.append_file(p, "cd")
ok(utils.read_file(p) == "abcd", "append")
local out, success = utils.exec("echo hi")
ok(out == "hi" and success, "exec echo")
ok(utils.base64_encode("foo") == "Zm9v", "base64")
os.remove(p)
print("test_utils: ALL PASS")
