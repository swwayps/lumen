-- logger shim: replaces Millennium's native logger module. The backend's
-- plugin_logger does `m_logger:info(...)` (colon = method call, passes self),
-- so return an object with info/warn/error methods. Writes to ~/.lumen.log.
local logger = {}
logger.__index = logger

local LOG_PATH = (os.getenv("HOME") or "/tmp") .. "/.lumen.log"

local function write(level, msg)
  local f = io.open(LOG_PATH, "a")
  if f then
    f:write(os.date("!%Y-%m-%dT%H:%M:%SZ ") .. level .. " " .. tostring(msg) .. "\n")
    f:close()
  end
end

function logger:info(msg)  write("INFO", msg) end
function logger:warn(msg)  write("WARN", msg) end
function logger:error(msg) write("ERROR", msg) end

-- require("logger") returns the object itself (so m_logger:info works).
return setmetatable({}, logger)
