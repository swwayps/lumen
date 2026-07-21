-- Managed Millennium-compatible themes for Lumen.
local json = require("json")
local fs = require("fs")
local http = require("http")
local b64 = require("b64")
local lfs = require("lfs")

local themes = {}
local apply_callback

local HOME = os.getenv("HOME") or ""
local CONFIG = HOME .. "/.config/Lumen/themes.json"
local ROOT = HOME .. "/.local/share/Lumen/themes"
local DEFAULT = {
  enabled = false, allow_javascript = true, active = nil,
  force_default_theme = false,
  preferences = {}, origins = {}, recovery = { pending = false, failures = 0 },
}

local function clone(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = clone(x) end
  return out
end

local function read_file(path, binary)
  local f = io.open(path, binary and "rb" or "r")
  if not f then return nil end
  local body = f:read("*a"); f:close(); return body
end

-- lua-cjson materializes JSON objects as unordered Lua tables.  Theme
-- condition styles are cascade-sensitive, while Millennium evaluates them in
-- the declaration order from skin.json.  Preserve just that top-level key
-- order with a small lexical pass; values continue to be decoded by cjson.
local function condition_key_order(body)
  local function string_end(pos)
    local i = pos + 1
    while i <= #body do
      local c = body:sub(i, i)
      if c == "\\" then i = i + 2
      elseif c == '"' then return i
      else i = i + 1 end
    end
    return nil
  end
  local function after(pos)
    return body:find("[^ \t\r\n]", pos) or (#body + 1)
  end
  local depth, start, i = 0, nil, 1
  while i <= #body do
    local c = body:sub(i, i)
    if c == '"' then
      local last = string_end(i); if not last then return {} end
      local next_pos = after(last + 1)
      if depth == 1 and body:sub(next_pos, next_pos) == ":" then
        local ok, key = pcall(json.decode, body:sub(i, last))
        local value_pos = after(next_pos + 1)
        if ok and key == "Conditions" and body:sub(value_pos, value_pos) == "{" then
          start = value_pos; break
        end
      end
      i = last
    elseif c == "{" then depth = depth + 1
    elseif c == "}" then depth = depth - 1 end
    i = i + 1
  end
  if not start then return {} end
  local out = {}
  depth, i = 1, start + 1
  while i <= #body and depth > 0 do
    local c = body:sub(i, i)
    if c == '"' then
      local last = string_end(i); if not last then break end
      local next_pos = after(last + 1)
      if depth == 1 and body:sub(next_pos, next_pos) == ":" then
        local ok, key = pcall(json.decode, body:sub(i, last))
        if ok and type(key) == "string" then out[#out + 1] = key end
      end
      i = last
    elseif c == "{" then depth = depth + 1
    elseif c == "}" then depth = depth - 1 end
    i = i + 1
  end
  return out
end

local function write_file(path, body, binary)
  fs.create_directories(fs.parent_path(path))
  local f, err = io.open(path, binary and "wb" or "w")
  if not f then return nil, err end
  local ok, werr = f:write(body)
  f:close()
  if not ok then return nil, werr end
  return true
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function merge_defaults(cfg)
  cfg = type(cfg) == "table" and cfg or {}
  local out = clone(DEFAULT)
  for k, v in pairs(cfg) do out[k] = v end
  if type(out.preferences) ~= "table" then out.preferences = {} end
  if type(out.origins) ~= "table" then out.origins = {} end
  if type(out.recovery) ~= "table" then out.recovery = clone(DEFAULT.recovery) end
  if type(out.enabled) ~= "boolean" then out.enabled = false end
  if type(out.allow_javascript) ~= "boolean" then out.allow_javascript = true end
  if type(out.force_default_theme) ~= "boolean" then out.force_default_theme = false end
  return out
end

function themes.config_path() return CONFIG end
function themes.root_path() return ROOT end
function themes.default_config() return clone(DEFAULT) end
function themes.set_apply_callback(fn) apply_callback = fn end

function themes.active_key(cfg)
  if type(cfg) ~= "table" or cfg.force_default_theme == true
      or cfg.enabled ~= true or type(cfg.active) ~= "string" then
    return nil
  end
  return cfg.active
end

function themes.load_config(path)
  local body = read_file(path or CONFIG)
  if not body then return merge_defaults(nil) end
  local ok, cfg = pcall(json.decode, body)
  return merge_defaults(ok and cfg or nil)
end

function themes.save_config(cfg, path)
  path = path or CONFIG
  fs.create_directories(fs.parent_path(path))
  local tmp = path .. ".tmp"
  local ok, err = write_file(tmp, json.encode(merge_defaults(cfg)))
  if not ok then return nil, err end
  os.execute("chmod 600 " .. shell_quote(tmp) .. " >/dev/null 2>&1")
  local moved, merr = os.rename(tmp, path)
  if not moved then os.remove(tmp); return nil, merr end
  return true
end

function themes.consume_default_override(cfg, path)
  if type(cfg) ~= "table" or cfg.force_default_theme ~= true then
    return true, false
  end
  local next_cfg = clone(cfg)
  next_cfg.force_default_theme = false
  local ok, err = themes.save_config(next_cfg, path)
  if not ok then return nil, err end
  return true, true
end

local function safe_name(s)
  s = tostring(s or "theme"):gsub("[^%w._-]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if s == "" or s == "." or s == ".." then return "theme" end
  return s:sub(1, 96)
end

local function validate_rel(path)
  if type(path) ~= "string" or path == "" or path:find("%z") or path:sub(1, 1) == "/"
      or path:find("\\", 1, true) then return nil, "unsafe asset path" end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then return nil, "unsafe asset path" end
  end
  return path
end

local function validate_targets(value)
  if type(value) == "string" then return validate_rel(value) end
  if type(value) ~= "table" then return nil, "unsafe asset path" end
  local count = 0
  for i, path in ipairs(value) do
    count = count + 1
    local _, err = validate_rel(path)
    if err then return nil, "item " .. tostring(i) .. ": " .. err end
  end
  if count == 0 then return nil, "asset list must not be empty" end
  return value
end

function themes.validate_manifest(data)
  if type(data) ~= "table" then return nil, "skin.json must contain an object" end
  for _, key in ipairs({ "name", "author", "description" }) do
    if type(data[key]) ~= "string" then return nil, "skin.json missing string " .. key end
  end
  if data.Patches ~= nil and type(data.Patches) ~= "table" then return nil, "Patches must be an array" end
  for i, patch in ipairs(data.Patches or {}) do
    if type(patch) ~= "table" or type(patch.MatchRegexString) ~= "string" then
      return nil, "Patches[" .. i .. "] missing MatchRegexString"
    end
    for _, key in ipairs({ "TargetCss", "TargetJs" }) do
      if patch[key] ~= nil then
        local _, err = validate_targets(patch[key]); if err then return nil, "Patches[" .. i .. "]." .. key .. ": " .. err end
      end
    end
  end
  return data
end

function themes.read_manifest(dir)
  local body = read_file(dir .. "/skin.json")
  if not body then return nil, "skin.json not found" end
  local ok, data = pcall(json.decode, body)
  if not ok then return nil, "invalid skin.json: " .. tostring(data) end
  data.__condition_order = condition_key_order(body)
  return themes.validate_manifest(data)
end

function themes.list(root, origins)
  root = root or ROOT
  origins = type(origins) == "table" and origins or {}
  local out = json.array({})
  if not fs.exists(root) then return out end
  local ok, entries = pcall(fs.list, root)
  if not ok then return out end
  for _, entry in ipairs(entries) do
    if entry.is_directory and entry.name:sub(1, 6) ~= ".tmp-" then
      local manifest = themes.read_manifest(entry.path)
      if manifest then
        local conditions = json.array({})
        if type(manifest.Conditions) == "table" then
          local names, have = {}, {}
          for _, name in ipairs(manifest.__condition_order or {}) do
            if manifest.Conditions[name] and not have[name] then
              names[#names+1], have[name] = name, true
            end
          end
          local tail = {}; for name in pairs(manifest.Conditions) do
            if not have[name] then tail[#tail+1] = name end
          end
          table.sort(tail); for _, name in ipairs(tail) do names[#names+1] = name end
          for _, name in ipairs(names) do
            local c = manifest.Conditions[name]
            local values = json.array({})
            if type(c) == "table" and type(c.values) == "table" then
              for value in pairs(c.values) do values[#values+1] = value end
              table.sort(values)
            end
            conditions[#conditions+1] = { name=name, description=c.description,
              default=c.default, tab=c.tab, section=c.section, values=values,
              slider=c.slider }
          end
        end
        local root_colors = json.array({})
        if type(manifest.RootColors) == "string" then
          local css = read_file(entry.path .. "/" .. manifest.RootColors)
          if css then
            for name, value in css:gmatch("%-%-([%w_-]+)%s*:%s*([^;]+);") do
              value = value:match("^%s*(.-)%s*$")
              root_colors[#root_colors+1] = { name=name, default=value }
            end
            table.sort(root_colors, function(a,b) return a.name < b.name end)
          end
        end
        out[#out + 1] = {
          native = entry.name, name = manifest.name, author = manifest.author,
          description = manifest.description, version = manifest.version,
          installed_at = tonumber(origins[entry.name] and origins[entry.name].installed_at)
            or tonumber(lfs.attributes(entry.path, "modification")) or 0,
          configurable = manifest.Conditions ~= nil or manifest.RootColors ~= nil,
          conditions = conditions, root_colors = root_colors,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.installed_at ~= b.installed_at then return a.installed_at > b.installed_at end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

local function decode_arg(raw)
  if type(raw) == "table" then return raw end
  local ok, v = pcall(json.decode, raw or "{}")
  return ok and type(v) == "table" and v or {}
end

local function response(ok, extra)
  local out = extra or {}; out.success = ok
  return json.encode(out)
end

function themes.lookup(id, deps)
  if type(id) ~= "string" or not id:match("^[A-Za-z0-9]+$") or #id ~= 20 then
    return nil, "Theme ID must contain exactly 20 letters or numbers"
  end
  local h = deps and deps.http or http
  local r, err = h.get("https://steambrew.app/api/v2/details/" .. id, { timeout = 20 })
  if not r then return nil, err or "request failed" end
  if tonumber(r.status) ~= 200 then return nil, "theme lookup returned HTTP " .. tostring(r.status) end
  local ok, data = pcall(json.decode, r.body or "")
  if not ok or type(data) ~= "table" then return nil, "invalid theme lookup response" end
  local skin = data.skin_data
  local gh = type(skin) == "table" and skin.github
  if type(gh) ~= "table" or type(gh.owner) ~= "string" or type(gh.repo_name) ~= "string" then
    return nil, "theme does not declare a GitHub repository"
  end
  return { id = id, name = data.name or skin.name, author = skin.author,
    description = skin.description, owner = gh.owner, repo = gh.repo_name }
end

local function unique_temp(root)
  return root .. "/.tmp-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
end

local function find_theme_dir(root)
  if fs.exists(root .. "/skin.json") then return root end
  local ok, entries = pcall(fs.list, root)
  if not ok then return nil end
  local found
  for _, e in ipairs(entries) do
    if e.is_directory and fs.exists(e.path .. "/skin.json") then
      if found then return nil end
      found = e.path
    end
  end
  return found
end

local function copy_tree(src, dst)
  fs.create_directories(dst)
  local cmd = "cp -a -- " .. shell_quote(src .. "/.") .. " " .. shell_quote(dst)
  local rc = os.execute(cmd)
  return rc == true or rc == 0
end

local function validate_tree(root)
  local count, total = 0, 0
  local function walk(dir)
    for name in lfs.dir(dir) do
      if name ~= "." and name ~= ".." then
        local path = dir .. "/" .. name
        local smode = lfs.symlinkattributes(path, "mode")
        if smode == "link" then return nil, "symbolic links are not allowed in themes" end
        count = count + 1
        if count > 4096 then return nil, "theme contains too many files" end
        if smode == "directory" then
          local ok, err = walk(path); if not ok then return nil, err end
        elseif smode == "file" then
          local size = lfs.attributes(path, "size") or 0
          if size > 32 * 1024 * 1024 then return nil, "theme contains a file larger than 32 MiB" end
          total = total + size
          if total > 256 * 1024 * 1024 then return nil, "theme is larger than 256 MiB" end
        else return nil, "theme contains an unsupported filesystem entry" end
      end
    end
    return true
  end
  return walk(root)
end

function themes.import_folder(source, origin, root)
  root = root or ROOT
  if type(source) ~= "string" or not fs.exists(source) then return nil, "selected folder does not exist" end
  local safe, serr = validate_tree(source); if not safe then return nil, serr end
  local manifest, err = themes.read_manifest(source)
  if not manifest then return nil, err end
  fs.create_directories(root)
  local native = safe_name((origin and origin.repo) or manifest.name)
  local stage = unique_temp(root)
  fs.create_directories(stage)
  if not copy_tree(source, stage) then fs.remove_all(stage); return nil, "failed to copy theme" end
  local check, cerr = themes.read_manifest(stage)
  if not check then fs.remove_all(stage); return nil, cerr end
  local final, backup = root .. "/" .. native, root .. "/.old-" .. native
  fs.remove_all(backup)
  if fs.exists(final) then os.rename(final, backup) end
  local moved, merr = os.rename(stage, final)
  if not moved then
    if fs.exists(backup) then os.rename(backup, final) end
    fs.remove_all(stage); return nil, merr or "failed to install theme"
  end
  fs.remove_all(backup)
  local cfg = themes.load_config()
  if origin then
    origin.installed_at = os.time()
    cfg.origins[native] = origin
    themes.save_config(cfg)
  end
  return { native = native, name = manifest.name, author = manifest.author,
    description = manifest.description, version = manifest.version }
end

function themes.import_zip(zip, origin, root)
  root = root or ROOT
  if type(zip) ~= "string" or not fs.exists(zip) then return nil, "selected ZIP does not exist" end
  fs.create_directories(root)
  local stage = unique_temp(root)
  fs.create_directories(stage)
  local list_cmd = "unzip -Z1 " .. shell_quote(zip)
  local p = io.popen(list_cmd, "r")
  if not p then fs.remove_all(stage); return nil, "unzip is not available" end
  local count = 0
  for name in p:lines() do
    count = count + 1
    if count > 4096 or name:sub(1, 1) == "/" or name:find("\\", 1, true) then
      p:close(); fs.remove_all(stage); return nil, "unsafe ZIP contents"
    end
    for part in name:gmatch("[^/]+") do
      if part == ".." then p:close(); fs.remove_all(stage); return nil, "unsafe ZIP path" end
    end
  end
  if p:close() == nil then fs.remove_all(stage); return nil, "invalid ZIP archive" end
  local rc = os.execute("unzip -qq " .. shell_quote(zip) .. " -d " .. shell_quote(stage))
  if not (rc == true or rc == 0) then fs.remove_all(stage); return nil, "failed to extract ZIP" end
  local dir = find_theme_dir(stage)
  if not dir then fs.remove_all(stage); return nil, "ZIP does not contain one theme with skin.json" end
  local safe, serr = validate_tree(dir)
  if not safe then fs.remove_all(stage); return nil, serr end
  local installed, err = themes.import_folder(dir, origin, root)
  fs.remove_all(stage)
  return installed, err
end

function themes.install_id(id, deps)
  local details, err = themes.lookup(id, deps)
  if not details then return nil, err end
  local h = deps and deps.http or http
  local req = json.encode({ owner = details.owner, repo = details.repo })
  local r, rerr = h.post("https://steambrew.app/api/v2/update", req,
    { timeout = 30, headers = { ["Content-Type"] = "application/json" } })
  if not r then return nil, rerr or "download lookup failed" end
  local ok, update = pcall(json.decode, r.body or "")
  local data = ok and update.data
  if tonumber(r.status) ~= 200 or type(data) ~= "table" or type(data.download) ~= "string" then
    return nil, "theme download could not be resolved"
  end
  local dl, derr = h.get(data.download, { timeout = 120 })
  if not dl or tonumber(dl.status) ~= 200 then return nil, derr or "theme download failed" end
  fs.create_directories(ROOT)
  local zip = unique_temp(ROOT) .. ".zip"
  local wrote, werr = write_file(zip, dl.body or "", true)
  if not wrote then return nil, werr end
  local installed, ierr = themes.import_zip(zip, {
    id = id, owner = details.owner, repo = details.repo, commit = data.latestHash,
  })
  os.remove(zip)
  return installed, ierr
end

function themes.update(native, deps)
  local cfg = themes.load_config()
  local origin = cfg.origins[native]
  if type(origin) ~= "table" or type(origin.owner) ~= "string" or type(origin.repo) ~= "string" then
    return nil, "this locally imported theme has no update source"
  end
  local h = deps and deps.http or http
  local r, err = h.post("https://steambrew.app/api/v2/update",
    json.encode({owner=origin.owner, repo=origin.repo}),
    {timeout=30, headers={["Content-Type"]="application/json"}})
  if not r then return nil, err or "update lookup failed" end
  local ok, resolved = pcall(json.decode, r.body or "")
  local data = ok and resolved.data
  if tonumber(r.status) ~= 200 or type(data) ~= "table" or type(data.download) ~= "string" then
    return nil, "theme update could not be resolved"
  end
  local dl, derr = h.get(data.download, {timeout=120})
  if not dl or tonumber(dl.status) ~= 200 then return nil, derr or "theme update download failed" end
  fs.create_directories(ROOT)
  local zip = unique_temp(ROOT) .. ".zip"
  local wrote, werr = write_file(zip, dl.body or "", true)
  if not wrote then return nil, werr end
  origin.commit = data.latestHash
  local installed, ierr = themes.import_zip(zip, origin)
  os.remove(zip)
  return installed, ierr
end

function themes.remove(native)
  if safe_name(native) ~= native then return nil, "invalid theme name" end
  local cfg = themes.load_config()
  if cfg.active == native then cfg.active = nil end
  cfg.origins[native] = nil; cfg.preferences[native] = nil
  themes.save_config(cfg)
  return fs.remove_all(ROOT .. "/" .. native)
end

function themes.register(registry)
  registry.LumenThemesStatus = function()
    local cfg = themes.load_config()
    local installed = themes.list(nil, cfg.origins)
    for _, item in ipairs(installed) do item.updateable = cfg.origins[item.native] ~= nil end
    return response(true, { config = cfg, themes = installed })
  end
  registry.LumenThemesLookup = function(raw)
    local r = decode_arg(raw); local item, err = themes.lookup(r.id)
    return item and response(true, { theme = item }) or response(false, { error = err })
  end
  registry.LumenThemesInstallId = function(raw)
    local item, err = themes.install_id(decode_arg(raw).id)
    return item and response(true, { theme = item }) or response(false, { error = err })
  end
  registry.LumenThemesImportZip = function(raw)
    local item, err = themes.import_zip(decode_arg(raw).path)
    return item and response(true, { theme = item }) or response(false, { error = err })
  end
  registry.LumenThemesImportZipData = function(raw)
    local r = decode_arg(raw)
    if type(r.data) ~= "string" or #r.data > 96 * 1024 * 1024 then
      return response(false, { error="ZIP is missing or too large" })
    end
    local bytes, derr = b64.decode(r.data)
    if not bytes then return response(false, { error=derr }) end
    fs.create_directories(ROOT)
    local path = unique_temp(ROOT) .. ".zip"
    local ok, werr = write_file(path, bytes, true)
    if not ok then return response(false, { error=werr }) end
    local item, err = themes.import_zip(path); os.remove(path)
    return item and response(true, { theme=item }) or response(false, { error=err })
  end
  registry.LumenThemesImportFolder = function(raw)
    local item, err = themes.import_folder(decode_arg(raw).path)
    return item and response(true, { theme = item }) or response(false, { error = err })
  end
  registry.LumenThemesSetConfig = function(raw)
    local r, cfg = decode_arg(raw), themes.load_config()
    if type(r.enabled) == "boolean" then cfg.enabled = r.enabled end
    if type(r.allow_javascript) == "boolean" then cfg.allow_javascript = r.allow_javascript end
    if r.active ~= nil then
      if r.active == false or r.active == "" then cfg.active = nil
      elseif type(r.active) == "string" then cfg.active = safe_name(r.active) end
    end
    if type(r.preferences) == "table" and cfg.active then cfg.preferences[cfg.active] = r.preferences end
    local ok, err = themes.save_config(cfg)
    local runtime_changed = r.active ~= nil or r.allow_javascript ~= nil or r.preferences ~= nil
      or r.reload == true
      or (r.enabled ~= nil and cfg.active ~= nil)
    if ok and runtime_changed and apply_callback then pcall(apply_callback, cfg) end
    return response(ok and true or false, ok and { config = cfg } or { error = err })
  end
  registry.LumenThemesRemove = function(raw)
    local ok, err = themes.remove(decode_arg(raw).native)
    return response(ok and true or false, ok and {} or { error = err })
  end
  registry.LumenThemesUpdate = function(raw)
    local item, err = themes.update(decode_arg(raw).native)
    return item and response(true, {theme=item}) or response(false, {error=err})
  end
  registry.LumenThemesOpenFolder = function()
    fs.create_directories(ROOT)
    local rc = os.execute("xdg-open " .. shell_quote(ROOT) .. " >/dev/null 2>&1 &")
    return response(rc == true or rc == 0, rc and {} or { error = "could not open themes folder" })
  end
  registry.LumenThemesPickFolder = function()
    local cmd
    if os.execute("command -v kdialog >/dev/null 2>&1") == true then cmd = "kdialog --getexistingdirectory " .. shell_quote(HOME)
    elseif os.execute("command -v zenity >/dev/null 2>&1") == true then cmd = "zenity --file-selection --directory --filename=" .. shell_quote(HOME .. "/") end
    if not cmd then return response(false, { fallback = "open-folder", error = "no folder picker available" }) end
    local p = io.popen(cmd, "r"); local path = p and p:read("*l"); if p then p:close() end
    return path and path ~= "" and response(true, { path = path }) or response(false, { error = "no folder selected" })
  end
end

return themes
