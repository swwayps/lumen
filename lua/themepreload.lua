-- Install the active theme's popup bootstrap into Steam's SharedJSContext
-- document before Valve's library.js runs.  CDP can only attach after Chromium
-- has exposed a target; by then the account selector may already have painted.
-- A tiny parser-blocking guard in index.html closes that race, while the full
-- compiled theme remains a deferred local file and runs after library.js.
--
-- This is deliberately reversible.  When themes are disabled we remove only
-- our marked HTML blocks and both helper files; Valve's surrounding index is
-- left byte-for-byte intact.
local fs = require("fs")
local lfs = require("lfs")

local preload = {}

preload.GUARD_START = "<!-- lumen-theme-preload:start -->"
preload.GUARD_END = "<!-- lumen-theme-preload:end -->"
preload.RUNTIME_START = "<!-- lumen-theme-runtime:start -->"
preload.RUNTIME_END = "<!-- lumen-theme-runtime:end -->"

local GUARD_FILE = "lumen-theme-preload.js"
local RUNTIME_FILE = "lumen-theme-runtime.js"
local ASSET_PATH_FILE = "lumen-theme-assets.path"
local ASSET_LINK = "lumen-theme-assets"

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  return body
end

local function atomic_write(path, body)
  if read(path) == body then return true, false end
  local tmp = path .. ".tmp.lumen." .. tostring(os.time()) .. "." ..
    tostring(math.random(100000, 999999))
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  local ok, werr = f:write(body)
  local closed, cerr = f:close()
  if not ok or not closed then
    os.remove(tmp)
    return nil, werr or cerr or "write failed"
  end
  local moved, merr = os.rename(tmp, path)
  if not moved then os.remove(tmp); return nil, merr end
  return true, true
end

local function sync_asset_link(ui, target)
  local link = fs.join(ui, ASSET_LINK)
  local mode = lfs.symlinkattributes(link, "mode")
  if not target then
    if mode == nil then return true, false end
    if mode ~= "link" then
      return nil, "refusing to remove non-symlink SteamUI theme asset path"
    end
    local ok, err = os.remove(link)
    if not ok then return nil, err end
    return true, true
  end
  if type(target) ~= "string" or target:sub(1, 1) ~= "/" or
      lfs.attributes(target, "mode") ~= "directory" then
    return nil, "theme asset root is not an absolute directory"
  end
  if mode == "link" and lfs.symlinkattributes(link, "target") == target then
    return true, false
  end
  if mode ~= nil and mode ~= "link" then
    return nil, "SteamUI theme asset path is not a symlink"
  end
  local temp = link .. ".tmp.lumen." .. tostring(os.time()) .. "." ..
    tostring(math.random(100000, 999999))
  os.remove(temp)
  local linked, lerr = lfs.link(target, temp, true)
  if not linked then return nil, lerr end
  local moved, merr = os.rename(temp, link)
  if not moved then os.remove(temp); return nil, merr end
  return true, true
end

local function remove_block(body, first, last)
  local changed = false
  while true do
    local a = body:find(first, 1, true)
    if not a then return body, changed end
    local b = body:find(last, a + #first, true)
    if not b then return nil, "unterminated Lumen theme marker" end
    body = body:sub(1, a - 1) .. body:sub(b + #last)
    changed = true
  end
end

function preload.clean_html(body)
  local clean, guard_changed = remove_block(body,
    preload.GUARD_START, preload.GUARD_END)
  if not clean then return nil, guard_changed end
  local runtime_changed
  clean, runtime_changed = remove_block(clean,
    preload.RUNTIME_START, preload.RUNTIME_END)
  if not clean then return nil, runtime_changed end
  return clean, guard_changed or runtime_changed
end

function preload.patch_html(body)
  local clean, changed = preload.clean_html(body)
  if not clean then return nil, changed end

  local first_script = clean:find("<script", 1, true)
  if not first_script then return nil, "SteamUI index has no script anchor" end

  local library_start = clean:find('<script[^>]-src=["\']/library%.js["\'][^>]*>')
  if not library_start then
    return nil, "SteamUI index library.js anchor was not recognized"
  end
  local library_close = clean:find("</script>", library_start, true)
  if not library_close then
    return nil, "SteamUI index library.js tag is incomplete"
  end
  library_close = library_close + #"</script>" - 1

  local guard = preload.GUARD_START ..
    '<script src="/' .. GUARD_FILE .. '"></script>' .. preload.GUARD_END
  local runtime = preload.RUNTIME_START ..
    '<script defer="defer" src="/' .. RUNTIME_FILE .. '"></script>' ..
    preload.RUNTIME_END

  -- Insert the later block first so the earlier byte offset stays valid.
  clean = clean:sub(1, library_close) .. runtime .. clean:sub(library_close + 1)
  clean = clean:sub(1, first_script - 1) .. guard .. clean:sub(first_script)
  return clean, true or changed
end

local function resolve_root(root)
  if type(root) == "string" and root ~= "" then return root end
  return require("millennium").steam_path()
end

local function resolve_stage(root)
  if type(root) == "string" and root ~= "" then return root end
  local home = os.getenv("HOME") or ""
  if home == "" then return "" end
  return fs.join(home, ".local", "share", "Lumen", "theme-preload")
end

-- Stage compiled helpers outside Steam's verified tree. The native exec gate
-- copies them into steamui only after the updater is finished and immediately
-- before steamwebhelper starts, so a custom theme cannot trigger client repair.
function preload.stage(runtime, stage_root)
  local root = resolve_stage(stage_root)
  if root == "" then return nil, "Lumen theme staging path not found" end
  fs.create_directories(root)
  local guard_path = fs.join(root, GUARD_FILE)
  local runtime_path = fs.join(root, RUNTIME_FILE)
  local asset_path = fs.join(root, ASSET_PATH_FILE)
  if not runtime then
    local had_guard = fs.exists(guard_path)
    local had_runtime = fs.exists(runtime_path)
    local had_assets = fs.exists(asset_path)
    if had_guard then os.remove(guard_path) end
    if had_runtime then os.remove(runtime_path) end
    if had_assets then os.remove(asset_path) end
    return true, had_guard or had_runtime or had_assets
  end
  if type(runtime.popup_guard_hook) ~= "string" or
      type(runtime.popup_hook) ~= "string" or
      type(runtime.popup_asset_root) ~= "string" then
    return nil, "theme runtime is missing popup bootstrap sources"
  end
  local ok_guard, guard_changed = atomic_write(guard_path, runtime.popup_guard_hook)
  if not ok_guard then return nil, guard_changed end
  local ok_runtime, runtime_changed = atomic_write(runtime_path, runtime.popup_hook)
  if not ok_runtime then return nil, runtime_changed end
  local ok_assets, assets_changed = atomic_write(asset_path,
    runtime.popup_asset_root)
  if not ok_assets then return nil, assets_changed end
  return true, guard_changed or runtime_changed or assets_changed
end

-- sync(runtime[, steam_root]) -> ok, changed_or_error
-- `runtime=nil` is the disabled/default-theme path and removes every artifact.
function preload.sync(runtime, steam_root)
  local root = resolve_root(steam_root)
  if root == "" then return nil, "Steam root not found" end
  local ui = fs.join(root, "steamui")
  local index_path = fs.join(ui, "index.html")
  local guard_path = fs.join(ui, GUARD_FILE)
  local runtime_path = fs.join(ui, RUNTIME_FILE)
  local original = read(index_path)
  if not original then return nil, "SteamUI index.html not found" end

  local next_html, html_changed
  if runtime then
    if type(runtime.popup_guard_hook) ~= "string" or
        type(runtime.popup_hook) ~= "string" or
        type(runtime.popup_asset_root) ~= "string" then
      return nil, "theme runtime is missing popup bootstrap sources"
    end
    next_html, html_changed = preload.patch_html(original)
    if not next_html then return nil, html_changed end

    -- Validate the HTML before touching helper files, then publish both files
    -- before the index that references them.
    local ok_guard, guard_changed = atomic_write(guard_path,
      runtime.popup_guard_hook)
    if not ok_guard then return nil, guard_changed end
    local ok_runtime, runtime_changed = atomic_write(runtime_path,
      runtime.popup_hook)
    if not ok_runtime then return nil, runtime_changed end
    local ok_assets, assets_changed = sync_asset_link(ui,
      runtime.popup_asset_root)
    if not ok_assets then return nil, assets_changed end
    local ok_index, index_changed = atomic_write(index_path, next_html)
    if not ok_index then return nil, index_changed end
    return true, guard_changed or runtime_changed or assets_changed or index_changed
  end

  next_html, html_changed = preload.clean_html(original)
  if not next_html then return nil, html_changed end
  local index_changed = false
  if html_changed then
    local ok_index, changed_or_err = atomic_write(index_path, next_html)
    if not ok_index then return nil, changed_or_err end
    index_changed = changed_or_err
  end
  local had_guard = fs.exists(guard_path)
  local had_runtime = fs.exists(runtime_path)
  if had_guard then os.remove(guard_path) end
  if had_runtime then os.remove(runtime_path) end
  local assets_ok, assets_changed = sync_asset_link(ui, nil)
  if not assets_ok then return nil, assets_changed end
  return true, index_changed or had_guard or had_runtime or assets_changed
end

return preload
