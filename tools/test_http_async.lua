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

-- A successful async transfer must retain the response body. This exercises
-- the storage lifetime behind CURLOPT_WRITEDATA rather than only completion.
local server = assert(socket.tcp())
assert(server:bind("127.0.0.1", 0))
assert(server:listen(1))
server:settimeout(0)
local host, port = server:getsockname()
local local_request = assert(core.start({
  url = "http://" .. host .. ":" .. tostring(port) .. "/",
  method = "GET",
  timeout = 3,
  follow_redirects = false,
  max_bytes = 1024,
}))
local client, replied, local_done, local_response, local_err
deadline = socket.gettime() + 3
repeat
  local_done, local_response, local_err = core.poll(local_request)
  if not client then
    client = server:accept()
    if client then client:settimeout(0) end
  end
  if client and not replied then
    client:send("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n" ..
      "Content-Type: text/plain\r\nConnection: close\r\n\r\nhello async")
    client:close()
    replied = true
  end
  if not local_done then socket.sleep(0.01) end
until local_done or socket.gettime() >= deadline
server:close()

ok(local_done == true, "local async response completes: " .. tostring(local_err))
ok(local_response and local_response.status == 200,
  "local async response preserves its status")
ok(local_response and local_response.body == "hello async",
  "local async response preserves its body storage")

print("test_http_async: ALL PASS")
