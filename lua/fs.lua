-- fs shim over luafilesystem (lfs). Paths are POSIX (Linux-only target).
local lfs = require("lfs")
local fs = {}

function fs.exists(path)
  return lfs.attributes(path, "mode") ~= nil
end

function fs.join(a, b)
  if a == "" then return b end
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

function fs.parent_path(path)
  local p = path:gsub("/+$", "")
  local parent = p:match("^(.*)/[^/]+$")
  return parent or (p:sub(1, 1) == "/" and "/" or ".")
end

function fs.current_path()
  return lfs.currentdir()
end

function fs.absolute(path)
  if path:sub(1, 1) == "/" then return (path:gsub("/+$", "")) end
  local base = lfs.currentdir()
  local joined = fs.join(base, path)
  local parts = {}
  for seg in joined:gmatch("[^/]+") do
    if seg == ".." then parts[#parts] = nil
    elseif seg ~= "." then parts[#parts + 1] = seg end
  end
  return "/" .. table.concat(parts, "/")
end

function fs.create_directories(path)
  local accum = (path:sub(1, 1) == "/") and "" or "."
  for seg in path:gmatch("[^/]+") do
    accum = accum .. "/" .. seg
    if lfs.attributes(accum, "mode") == nil then
      lfs.mkdir(accum)
    end
  end
  return true
end

function fs.list(path)
  local out = {}
  for entry in lfs.dir(path) do
    if entry ~= "." and entry ~= ".." then out[#out + 1] = entry end
  end
  return out
end

function fs.list_recursive(path)
  local out = {}
  local function walk(dir, prefix)
    for entry in lfs.dir(dir) do
      if entry ~= "." and entry ~= ".." then
        local full = dir .. "/" .. entry
        local rel = prefix == "" and entry or (prefix .. "/" .. entry)
        out[#out + 1] = rel
        if lfs.attributes(full, "mode") == "directory" then walk(full, rel) end
      end
    end
  end
  walk(path, "")
  return out
end

function fs.remove(path)
  if lfs.attributes(path, "mode") == "directory" then
    return lfs.rmdir(path)
  end
  return os.remove(path)
end

function fs.remove_all(path)
  local mode = lfs.attributes(path, "mode")
  if mode == nil then return true end
  if mode == "directory" then
    for entry in lfs.dir(path) do
      if entry ~= "." and entry ~= ".." then
        fs.remove_all(path .. "/" .. entry)
      end
    end
    return lfs.rmdir(path)
  end
  return os.remove(path)
end

return fs
