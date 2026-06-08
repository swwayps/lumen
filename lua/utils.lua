-- utils shim: file IO, exec, env, base64. (steam_utils.* live in the backend,
-- NOT here.) get_backend_path returns the dir lumen was told the backend is in.
local b64 = require("b64")
local utils = {}

function utils.get_backend_path()
  return os.getenv("LUMEN_BACKEND_DIR") or ""
end

function utils.read_file(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local data = f:read("*a"); f:close(); return data
end

function utils.write_file(path, text)
  local f = io.open(path, "wb"); if not f then return false end
  f:write(text or ""); f:close(); return true
end

function utils.append_file(path, text)
  local f = io.open(path, "ab"); if not f then return false end
  f:write(text or ""); f:close(); return true
end

-- exec: run a shell command, return stdout (trailing whitespace trimmed) + ok flag.
function utils.exec(cmd)
  local f = io.popen(cmd, "r"); if not f then return "", false end
  local out = f:read("*a") or ""
  local ok = f:close()
  return (out:gsub("%s+$", "")), (ok and true or false)
end

function utils.getenv(name) return os.getenv(name) end

function utils.base64_encode(data) return b64.encode(data or "") end

return utils
