-- File handoff for notifications emitted inside SLSsteam.so.
--
-- The hook cannot call JavaScript directly and notify-send is invisible in
-- Steam's Gamepad UI. It therefore publishes small, atomic JSON files here;
-- the Lumen loop drains them and relays fresh events to SharedJSContext.
local json = require("json")
local lfs = require("lfs")
local socket = require("socket")

local queue = {}

local MAX_AGE_MS = 120000
local MAX_FUTURE_SKEW_MS = 10000
local MAX_TITLE_BYTES = 256
local MAX_BODY_BYTES = 4096
local MAX_FILE_BYTES = 8192

function queue.default_dir()
  local home = os.getenv("HOME")
  if not home or home == "" then return nil end
  return home .. "/.local/share/Lumen/notifications"
end

function queue.now_ms()
  return math.floor(socket.gettime() * 1000)
end

function queue.decode_event(raw, now_ms)
  if type(raw) ~= "string" or #raw == 0 or #raw > MAX_FILE_BYTES then return nil end
  local ok, event = pcall(json.decode, raw)
  if not ok or type(event) ~= "table" or event.version ~= 1 then return nil end
  if type(event.created_ms) ~= "number" or event.created_ms % 1 ~= 0 then return nil end
  if type(event.title) ~= "string" or #event.title == 0 or
     #event.title > MAX_TITLE_BYTES then return nil end
  if type(event.body) ~= "string" or #event.body == 0 or
     #event.body > MAX_BODY_BYTES then return nil end
  if type(event.timeout_ms) ~= "number" or event.timeout_ms % 1 ~= 0 or
     event.timeout_ms < 1000 or event.timeout_ms > 60000 then return nil end

  now_ms = now_ms or queue.now_ms()
  local age = now_ms - event.created_ms
  if age > MAX_AGE_MS or age < -MAX_FUTURE_SKEW_MS then return nil end
  return event
end

-- Read and remove every complete event. A producer publishes with rename(), so
-- only *.json is visible here; dot-prefixed *.tmp files are never consumed.
-- Invalid/stale events are removed as well so a bad file cannot retry forever.
function queue.drain(dir, now_ms)
  dir = dir or queue.default_dir()
  if not dir or lfs.attributes(dir, "mode") ~= "directory" then return {} end

  local names = {}
  local ok, iter, state = pcall(lfs.dir, dir)
  if not ok then return {} end
  for name in iter, state do
    if name:match("^event%-.+%.json$") then names[#names + 1] = name end
  end
  table.sort(names)

  local events = {}
  for _, name in ipairs(names) do
    local path = dir .. "/" .. name
    local mode = lfs.attributes(path, "mode")
    local raw
    if mode == "file" then
      local f = io.open(path, "rb")
      if f then raw = f:read(MAX_FILE_BYTES + 1); f:close() end
    end
    os.remove(path)
    local event = queue.decode_event(raw, now_ms)
    if event then events[#events + 1] = event end
  end
  return events
end

return queue
