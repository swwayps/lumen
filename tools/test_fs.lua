-- Run via the built binary (lfs is in the binary, not host lua5.4):
--   LUMEN_LUA_DIR=lua ./bin/lumen --test-fs
package.path = "lua/?.lua;" .. package.path
local fs = require("fs")
local function ok(c, m) if not c then error("FAIL: "..(m or "")) end end

local tmp = "/tmp/lumen_fs_test"
os.execute("rm -rf " .. tmp)

ok(not fs.exists(tmp), "absent before create")
fs.create_directories(tmp .. "/a/b")
ok(fs.exists(tmp .. "/a/b"), "recursive mkdir")
ok(fs.join("x", "y") == "x/y", "join")
ok(fs.join("x/", "y") == "x/y", "join trailing slash")
ok(fs.parent_path("/x/y/z") == "/x/y", "parent_path")
ok(fs.absolute("."):sub(1, 1) == "/", "absolute is rooted")

local f = io.open(tmp .. "/a/file.txt", "w"); f:write("hi"); f:close()
local listed = fs.list(tmp .. "/a")
local found = false
for _, e in ipairs(listed) do if e.name == "file.txt" and e.path:find("file.txt") then found = true end end
ok(found, "list finds file with name+path")

local rec = fs.list_recursive(tmp)
local found_b = false
for _, e in ipairs(rec) do if e.name == "b" and e.is_directory then found_b = true end end
ok(found_b, "list_recursive finds dir b with is_directory")

fs.remove(tmp .. "/a/file.txt")
ok(not fs.exists(tmp .. "/a/file.txt"), "remove file")
fs.remove_all(tmp)
ok(not fs.exists(tmp), "remove_all dir tree")

print("test_fs: ALL PASS")
