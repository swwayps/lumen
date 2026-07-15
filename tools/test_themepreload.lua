-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_themepreload.lua
package.path = "lua/?.lua;" .. package.path

local fs = require("fs")
local lfs = require("lfs")
local preload = require("themepreload")

local function read(path)
  local f = assert(io.open(path, "rb"))
  local body = f:read("*a")
  f:close()
  return body
end

local function write(path, body)
  fs.create_directories(fs.parent_path(path))
  local f = assert(io.open(path, "wb"))
  assert(f:write(body))
  f:close()
end

local root = "/tmp/lumen-theme-preload-test-" .. tostring(os.time())
fs.remove_all(root)
fs.create_directories(root .. "/steamui")

local vanilla = '<!doctype html><html><head><title>SharedJSContext</title>' ..
  '<script defer="defer" src="/libraries/vendor.js"></script>' ..
  '<script defer="defer" src="/library.js"></script>' ..
  '<link href="/css/library.css" rel="stylesheet"></head><body></body></html>'
write(root .. "/steamui/index.html", vanilla)

local runtime = {
  popup_guard_hook = "/* lumen tiny synchronous guard */",
  popup_hook = "/* lumen compiled theme */",
  popup_asset_root = root .. "/theme-one",
}
fs.create_directories(runtime.popup_asset_root)

local stage = root .. "/stage"
local staged_ok, staged_changed = preload.stage(runtime, stage)
assert(staged_ok and staged_changed == true,
  "theme helpers can be staged without touching Steam's verified files")
assert(read(stage .. "/lumen-theme-preload.js") == runtime.popup_guard_hook)
assert(read(stage .. "/lumen-theme-runtime.js") == runtime.popup_hook)
assert(read(stage .. "/lumen-theme-assets.path") == runtime.popup_asset_root)
assert(read(root .. "/steamui/index.html") == vanilla,
  "staging leaves the live Steam index byte-for-byte vanilla")

local ok, changed = preload.sync(runtime, root)
assert(ok, changed)
assert(changed == true, "first prepare changes the SteamUI bootstrap")

local patched = read(root .. "/steamui/index.html")
local guard_pos = assert(patched:find(preload.GUARD_START, 1, true))
local vendor_pos = assert(patched:find('src="/libraries/vendor.js"', 1, true))
local library_pos = assert(patched:find('src="/library.js"', 1, true))
local runtime_pos = assert(patched:find(preload.RUNTIME_START, 1, true))
assert(guard_pos < vendor_pos,
  "the synchronous guard loads before Valve's first deferred bundle")
assert(library_pos < runtime_pos,
  "the compiled theme loads after library.js has created PopupManager")
assert(patched:find('src="/lumen-theme-preload.js"', 1, true))
assert(patched:find('src="/lumen-theme-runtime.js"', 1, true))
assert(read(root .. "/steamui/lumen-theme-preload.js") == runtime.popup_guard_hook)
assert(read(root .. "/steamui/lumen-theme-runtime.js") == runtime.popup_hook)
assert(lfs.symlinkattributes(root .. "/steamui/lumen-theme-assets", "mode") == "link")
assert(lfs.symlinkattributes(root .. "/steamui/lumen-theme-assets", "target") == runtime.popup_asset_root)

-- Steam rewrites index.html from steamui_websrc_all.zip.vz during cold boot.
-- The pre-login monitor must notice that reset without comparing the 2 MB
-- compiled helper on every tick, then let sync() restore the bootstrap once.
write(root .. "/steamui/index.html", vanilla)
local reset_ok, reset_changed = preload.sync(runtime, root)
assert(reset_ok and reset_changed == true,
  "the bootstrap is reasserted after Steam replaces index.html")
patched = read(root .. "/steamui/index.html")

local ok2, changed2 = preload.sync(runtime, root)
assert(ok2 and changed2 == false, "preparing the same theme is idempotent")
assert(read(root .. "/steamui/index.html") == patched,
  "idempotent prepare does not rewrite index.html")

local runtime2 = {
  popup_guard_hook = "/* next guard */",
  popup_hook = "/* next compiled theme */",
  popup_asset_root = root .. "/theme-two",
}
fs.create_directories(runtime2.popup_asset_root)
local ok3, changed3 = preload.sync(runtime2, root)
assert(ok3 and changed3 == true, "switching theme updates bootstrap files")
local switched = read(root .. "/steamui/index.html")
assert(switched == patched, "switching theme does not churn the index markers")
assert(read(root .. "/steamui/lumen-theme-preload.js") == runtime2.popup_guard_hook)
assert(read(root .. "/steamui/lumen-theme-runtime.js") == runtime2.popup_hook)
assert(lfs.symlinkattributes(root .. "/steamui/lumen-theme-assets", "target") == runtime2.popup_asset_root)

local clean_ok, clean_changed = preload.sync(nil, root)
assert(clean_ok and clean_changed == true, "disabling themes removes the bootstrap")
assert(read(root .. "/steamui/index.html") == vanilla,
  "disabling themes restores the exact surrounding Steam index content")
assert(not fs.exists(root .. "/steamui/lumen-theme-preload.js"))
assert(not fs.exists(root .. "/steamui/lumen-theme-runtime.js"))
assert(lfs.symlinkattributes(root .. "/steamui/lumen-theme-assets", "mode") == nil)

local clean_ok2, clean_changed2 = preload.sync(nil, root)
assert(clean_ok2 and clean_changed2 == false,
  "disabled cleanup is idempotent and has zero persistent work")

-- Unknown Steam layouts must fail closed: never edit an index whose library
-- anchor cannot be identified, and never leave half-installed helper files.
local unknown = '<html><head><script src="/different.js"></script></head></html>'
write(root .. "/steamui/index.html", unknown)
local bad_ok = preload.sync(runtime, root)
assert(not bad_ok, "an unknown SteamUI layout is rejected")
assert(read(root .. "/steamui/index.html") == unknown)
assert(not fs.exists(root .. "/steamui/lumen-theme-preload.js"))
assert(not fs.exists(root .. "/steamui/lumen-theme-runtime.js"))

fs.remove_all(root)
print("ok - SteamUI theme preloader")
