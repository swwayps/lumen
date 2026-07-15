package.path = (os.getenv("LUMEN_LUA_DIR") or "lua") .. "/?.lua;" .. package.path

local themes = require("themes")
local engine = require("themeengine")

local zip, root = os.getenv("LUMEN_THEME_ZIP"), os.getenv("LUMEN_THEME_ROOT")
assert(zip and root, "set LUMEN_THEME_ZIP and LUMEN_THEME_ROOT")
local installed = assert(themes.import_zip(zip, nil, root))
local runtime = assert(engine.build({ enabled=true, allow_javascript=true,
  active=installed.native, preferences={}, origins={
    [installed.native]={commit="testcommit123"},
  } }, root))
assert(runtime.manifest.name and #runtime.assets.js == 1)
assert(runtime.assets.js[1]:find("lumen%-theme%-"))
assert(#runtime.assets.js[1] < 200000, "theme bootstrap must stay lightweight")
assert(type(runtime.popup_hook) == "string" and runtime.popup_hook:find("AddPopupCreatedCallback", 1, true),
  "runtime provides an immediate Steam PopupManager hook")
assert(#runtime.popup_hook < 16 * 1024 * 1024,
  "compiled popup CSS remains bounded when themes are explicitly enabled")
local first = runtime.manifest.Patches and runtime.manifest.Patches[1]
local css_path = first and first.TargetCss
if type(css_path) == "table" then css_path = css_path[1] end
assert(type(css_path) == "string", "theme declares at least one CSS patch")
local versioned = "https://lumen-theme.local/" .. installed.native .. "/testcommit123/" .. css_path
assert(runtime.assets.js[1]:find("testcommit123", 1, true), "theme URLs include cache version")
local css, mime = runtime.assets.virtual_provider(versioned)
assert(css and #css > 0 and mime:match("text/css"), "virtual CSS asset")
print("real theme ok: " .. runtime.manifest.name .. " -> " .. installed.native)
