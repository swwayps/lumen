-- Run with the linked C module: bin/lumen --test tools/test_http_async.lua
local core = require("lumen_http")
local socket = require("socket")

local function ok(value, message)
  if not value then error("FAIL: " .. message) end
end

local request, start_err = core.start({
  url = "https://127.0.0.1:1/",
  method = "GET",
  timeout = 1,
  follow_redirects = false,
  https_only = true,
  max_bytes = 1024,
})
ok(request ~= nil, "async request starts: " .. tostring(start_err))

local deadline = socket.gettime() + 3
local done, response, request_err
repeat
  done, response, request_err = core.poll(request)
  if not done then socket.sleep(0.01) end
until done or socket.gettime() >= deadline

ok(done == true, "async request completes without blocking the Lua loop")
ok(response == nil and type(request_err) == "string",
  "connection failure is returned asynchronously")

print("test_http_async: ALL PASS")
