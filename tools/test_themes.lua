package.path = (os.getenv("LUMEN_LUA_DIR") or "lua") .. "/?.lua;" .. package.path

local json = require("json")
local themes = require("themes")
local engine = require("themeengine")
local b64 = require("b64")
local fs = require("fs")

local function eq(a, b, msg) assert(a == b, (msg or "mismatch") .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end

local d = themes.default_config()
eq(d.enabled, false, "disabled by default")
eq(d.allow_javascript, true, "javascript defaults on")
eq(d.force_default_theme, false, "external default-theme override defaults off")
eq(themes.active_key({
  enabled=true, active="Fixture", force_default_theme=true,
}), nil, "external override suppresses the configured custom theme")
eq(themes.active_key({
  enabled=true, active="Fixture", force_default_theme=false,
}), "Fixture", "custom theme remains active when the override is off")
do
  local path = "/tmp/lumen-theme-override-test-" .. tostring(os.time()) .. ".json"
  local file = assert(io.open(path, "w"))
  file:write('{"enabled":true,"active":"Fixture","force_default_theme":true}')
  file:close()
  local forced = themes.load_config(path)
  eq(forced.force_default_theme, true, "themes.json persists the external override")
  eq(themes.active_key(forced), nil, "themes.json override selects the default Steam theme")
  assert(themes.consume_default_override(forced, path))
  local consumed = themes.load_config(path)
  eq(consumed.force_default_theme, false, "default-theme override resets after a safe boot")
  eq(consumed.enabled, true, "consuming the override preserves theme enablement")
  eq(consumed.active, "Fixture", "consuming the override preserves the selected theme")
  os.remove(path)
end
eq(#engine.DEFAULT_PATCHES, 14, "complete default table")
eq(assert(b64.decode(b64.encode("theme\0bytes"))), "theme\0bytes", "base64 round trip")
eq(json.encode(themes.list("/tmp/lumen-themes-path-that-does-not-exist")), "[]", "empty theme list is JSON array")

-- Installed themes are shown in download/install order, newest first. Existing
-- themes without metadata can fall back to the filesystem timestamp, but a
-- persisted origin timestamp is authoritative and deterministic.
do
  local root = "/tmp/lumen-theme-order-test-" .. tostring(os.time())
  fs.create_directories(root .. "/alpha")
  fs.create_directories(root .. "/zulu")
  local alpha = assert(io.open(root .. "/alpha/skin.json", "w"))
  alpha:write('{"name":"Alpha","author":"A","description":"Older"}')
  alpha:close()
  local zulu = assert(io.open(root .. "/zulu/skin.json", "w"))
  zulu:write('{"name":"Zulu","author":"Z","description":"Newest"}')
  zulu:close()
  local ordered = themes.list(root, {
    alpha = { installed_at = 100 },
    zulu = { installed_at = 200 },
  })
  eq(ordered[1].native, "zulu", "newest downloaded theme is listed first")
  eq(ordered[2].native, "alpha", "oldest downloaded theme is listed last")
  fs.remove_all(root)
end

assert(themes.validate_manifest({ name="T", author="A", description="D", Patches={} }))
assert(themes.validate_manifest({ name="T", author="A", description="D", Patches={{
  MatchRegexString=".DesktopUI", TargetCss={"dist/client.css","dist/shared.css"},
  TargetJs={"dist/client.js","dist/shared.js"},
}} }), "Millennium patch target arrays are valid")
assert(not themes.validate_manifest({ name="T", author="A", description="D",
  Patches={{ MatchRegexString=".*", TargetCss="../escape.css" }} }))
assert(not themes.validate_manifest({ name="T", author="A", description="D",
  Patches={{ MatchRegexString=".*", TargetCss={"safe.css","../escape.css"} }} }),
  "every member of a target array is path-validated")

local got_url, posted
local fake = {
  get = function(url)
    got_url = url
    return { status=200, body=json.encode({ name="Theme", skin_data={ name="Theme", author="A",
      description="D", github={ owner="Owner", repo_name="Repo" } } }) }
  end,
  post = function(url, body)
    posted = {url=url, body=json.decode(body)}
    return { status=200, body=json.encode({data={download="https://example.invalid/theme.zip",latestHash="abc"}}) }
  end,
}
local item = assert(themes.lookup("zQndv1rI0FXLh3QTRgOL", {http=fake}))
eq(item.owner, "Owner"); eq(item.repo, "Repo")
assert(got_url:match("zQndv1rI0FXLh3QTRgOL$"))
assert(not themes.lookup("short", {http=fake}))

-- PopupManager can create a window before that target has its own CDP Fetch
-- handler. The lightweight hook must keep the default Steam body hidden until
-- its virtual theme stylesheets finish loading, then reveal it (with a timeout
-- fail-safe so a malformed theme can never leave a permanent blank window).
do
  local root = "/tmp/lumen-theme-prepaint-test-" .. tostring(os.time())
  local dir = root .. "/Fixture"
  fs.create_directories(dir .. "/fonts")
  local manifest = assert(io.open(dir .. "/skin.json", "w"))
  manifest:write('{"name":"Fixture","author":"A","description":"D","Patches":[' ..
    '{"MatchRegexString":"^Steam$","TargetCss":"libraryroot.custom.css"}],' ..
    '"RootColors":"colors.css",' ..
    '"Steam-WebKit":"webkit.css",' ..
    '"Conditions":{"Z last":{"default":"on","values":{"on":{"TargetCss":{' ..
    '"affects":["^Steam$"],"src":"z.css"}}}},' ..
    '"A first":{"default":"on","values":{"on":{"TargetCss":{' ..
    '"affects":["^Steam$"],"src":"a.css"}}}}}}')
  manifest:close()
  local font = assert(io.open(dir .. "/fonts/fixture.woff2", "wb"))
  font:write("fixture-font")
  font:close()
  local fallback_font = assert(io.open(dir .. "/fonts/fixture.woff", "wb"))
  fallback_font:write("redundant-fixture-fallback")
  fallback_font:close()
  local large_font_bytes = string.rep("large-font-fixture", 70000)
  local large_font = assert(io.open(dir .. "/fonts/large.woff2", "wb"))
  large_font:write(large_font_bytes)
  large_font:close()
  local css = assert(io.open(dir .. "/libraryroot.custom.css", "w"))
  css:write('@font-face{font-family:Fixture;src:url("./fonts/fixture.woff2") format("woff2"),' ..
    'url("./fonts/fixture.woff") format("woff")}' ..
    '@font-face{font-family:Large;src:url("./fonts/large.woff2")}' ..
    'body{background:#123}')
  css:close()
  local colors = assert(io.open(dir .. "/colors.css", "w"))
  colors:write(':root{--arbitrary-surface:#112233;--arbitrary-accent:rgb(220, 80, 40);}')
  colors:close()
  local webkit = assert(io.open(dir .. "/webkit.css", "w"))
  webkit:write("body{--webkit-only-marker:1}")
  webkit:close()
  local zcss = assert(io.open(dir .. "/z.css", "w")); zcss:write("body{color:#aaa}"); zcss:close()
  local acss = assert(io.open(dir .. "/a.css", "w")); acss:write("body{color:#bbb}"); acss:close()
  local parsed = assert(themes.read_manifest(dir))
  assert(parsed.__condition_order[1] == "Z last"
      and parsed.__condition_order[2] == "A first",
    "condition cascade order follows skin.json declaration order")
  local runtime = assert(engine.build({enabled=true,allow_javascript=true,
    active="Fixture",preferences={Fixture={__rootcolors={
      ["arbitrary-surface"]="#334455",
    }}},origins={Fixture={commit="test"}}}, root))
  assert(runtime.assets.js[1]:find("__lumenThemePaletteSeed", 1, true)
      and runtime.assets.js[1]:find("arbitrary%-surface")
      and runtime.assets.js[1]:find("#334455", 1, true)
      and runtime.assets.js[1]:find("arbitrary%-accent")
      and runtime.popup_hook:find("__lumenThemePaletteSeed", 1, true),
    "every target receives effective RootColors and the active theme revision as a palette seed")
  assert(runtime.assets.js[1]:find('indexOf("lumen-theme-"+P.native+"-")', 1, true),
    "full bootstrap preserves synchronous nodes belonging to the active theme")
  assert(runtime.assets.js[1]:find('"promotePopup":false', 1, true)
      and runtime.assets.js[1]:find("if(previous.length)return", 1, true)
      and not runtime.assets.js[1]:find("P.promotePopup", 1, true),
    "full bootstrap preserves prepaint popup CSS instead of parsing the same theme twice")
  assert(runtime.assets.js[1]:find('"browserOnly":true', 1, true)
      and runtime.assets.js[1]:find('a.browserOnly&&location.hostname==="steamloopback.host"', 1, true),
    "Steam-WebKit assets are excluded from internal steamloopback documents")
  assert(not runtime.popup_hook:find("webkit%-only%-marker"),
    "popup hook does not carry Store/Community CSS that can never match a native menu")
  assert(runtime.assets.js[1]:find("z.css", 1, true)
      < runtime.assets.js[1]:find("a.css", 1, true),
    "condition assets retain their manifest cascade order")
  assert(runtime.popup_hook:find("lumen%-theme%-prepaint"),
    "popup hook installs a prepaint guard")
  assert(type(runtime.popup_guard_hook) == "string"
      and #runtime.popup_guard_hook < 8192,
    "cold boot uses a tiny prepaint hook instead of evaluating the compiled theme")
  assert(runtime.popup_guard_hook:find("AddPopupCreatedCallback", 1, true)
      and runtime.popup_guard_hook:find("lumen%-theme%-prepaint")
      and runtime.popup_guard_hook:find("8000", 1, true),
    "the tiny hook guards existing and future popups with a bounded fail-safe")
  assert(runtime.popup_guard_hook:find("Object.defineProperty", 1, true)
      and runtime.popup_guard_hook:find('"g_PopupManager"', 1, true),
    "the file preloader traps PopupManager assignment before library.js can create a popup")
  assert(not runtime.popup_guard_hook:find("body{background:#123}", 1, true)
      and not runtime.popup_guard_hook:find("data:font/woff2", 1, true),
    "the prepaint hook carries no theme CSS or embedded fonts")
  assert(runtime.popup_hook:find("!already||hold", 1, true),
    "an idempotent popup refresh never hides an already-themed visible window")
  assert(runtime.popup_hook:find("addEventListener", 1, true)
      and runtime.popup_hook:find('"load"', 1, true),
    "popup hook waits for virtual stylesheets")
  assert(runtime.popup_hook:find("8000", 1, true),
    "popup prepaint guard has a bounded fail-safe")
  assert(runtime.popup_hook:find("__lumenOriginalFocus", 1, true)
      and runtime.popup_hook:find("__lumenPendingPopupFocus", 1, true)
      and runtime.popup_hook:find("firstElementChild", 1, true),
    "a cold context menu defers its first native focus until React has committed content")
  assert(runtime.popup_hook:find("__lumenPopupContentObserver", 1, true)
      and runtime.popup_hook:find("MutationObserver", 1, true),
    "cold popup readiness is event-driven instead of adding a permanent polling loop")
  assert(runtime.popup_hook:find("setTimeout(function(){original.apply", 1, true),
    "the deferred native focus yields one turn for Steam's own menu resize")
  assert(runtime.assets.js[1]:find('if(n.id==="lumen-theme-prepaint"', 1, true)
      and runtime.popup_hook:find('if(n.id==="lumen-theme-prepaint"', 1, true),
    "theme cleanup preserves the prepaint guard in both full and popup bootstraps")
  assert(runtime.popup_hook:find("createflags=4538378", 1, true),
    "a context-menu document remains guarded before Steam assigns its body classes")
  assert(runtime.popup_hook:find("body{background:#123}", 1, true),
    "popup hook carries compiled CSS synchronously instead of a dead virtual link")
  assert(runtime.popup_asset_root == dir,
    "native preload exposes the active theme directory as its local asset root")
  assert(not runtime.popup_hook:find("data:font\\/woff2;base64", 1, true)
      and not runtime.popup_hook:find(b64.encode("fixture-font"), 1, true)
      and not runtime.popup_hook:find(b64.encode(large_font_bytes):sub(1, 128), 1, true),
    "popup hook never embeds font binaries into its parser-blocking bootstrap")
  assert(runtime.popup_hook:find("fonts\\/fixture.woff2?lumen-theme=Fixture%3Atest", 1, true)
      and runtime.popup_hook:find("fonts\\/fixture.woff?lumen-theme=Fixture%3Atest", 1, true)
      and runtime.popup_hook:find("fonts\\/large.woff2?lumen-theme=Fixture%3Atest", 1, true),
    "popup CSS loads every theme asset from the same-origin native asset mount")
  assert(not runtime.popup_hook:find("lumen-theme.local/Fixture/test/fonts/fixture.woff2", 1, true),
    "pre-login assets never depend on the later CDP virtual provider")
  assert(runtime.popup_hook:find("setInterval", 1, true)
      and runtime.popup_hook:find("g_PopupManager", 1, true),
    "popup hook waits for PopupManager during cold boot")
  assert(runtime.popup_hook:find("__lumenDocumentThemeArmed", 1, true),
    "the universal bootstrap arms each document only once per theme revision")
  assert(not runtime.popup_hook:find("requestAnimationFrame", 1, true),
    "hidden SharedJSContext cleanup never depends on a visual animation frame")
  assert(runtime.popup_hook:find("MillenniumWindow_ContextMenu", 1, true)
      and runtime.popup_hook:find("replace(/[^a-zA-Z0-9]/g", 1, true),
    "popup hook adds Millennium context-menu compatibility breadcrumbs")
  local document_hook = runtime.assets.document_bootstrap_source
  assert(type(document_hook) == "string" and document_hook ~= runtime.popup_hook,
    "page targets receive a lightweight loader, not the compiled theme body")
  assert(#document_hook < 4096,
    "per-document registration stays small enough to install across every Steam target")
  assert(document_hook:find("lumen%-theme%-prepaint")
      and document_hook:find("import(", 1, true),
    "the loader hides the default document before importing the compiled theme")
  assert(document_hook:find("createflags=4538378", 1, true)
      and document_hook:find("setTimeout(reveal,8000)", 1, true),
    "a native menu keeps the prepaint guard when its early module import is unavailable")
  assert(document_hook:find("MutationObserver", 1, true)
      and not document_hook:find("queueMicrotask", 1, true),
    "a document without <html> waits passively instead of starving the parser")
  assert(not document_hook:find("g_PopupManager", 1, true),
    "ordinary page loaders do not poll for SharedJSContext-only globals")
  assert(runtime.assets.shared_bootstrap_source == document_hook,
    "SharedJSContext uses the same small loader on future documents")
  assert(runtime.assets.bypass_csp == true,
    "theme JavaScript explicitly opts the browser gateway into CSP bypass")
  assert(runtime.assets.browser_gateway ~= true,
    "production themes never activate Steam's incompatible browser auto-attach")
  local bootstrap_url = runtime.assets.document_bootstrap_url
  assert(type(bootstrap_url) == "string"
      and document_hook:find(json.encode(bootstrap_url), 1, true),
    "the loader imports its versioned virtual bootstrap URL")
  assert(bootstrap_url:find("/__lumen_bootstrap%-%x+%.js$"),
    "the bootstrap URL changes with its implementation to avoid a stale module cache")
  local bootstrap_body, bootstrap_mime = runtime.assets.virtual_provider(bootstrap_url)
  assert(bootstrap_body == runtime.popup_hook
      and bootstrap_mime:find("javascript", 1, true),
    "the virtual provider serves the compiled universal theme bootstrap once")
  local no_js = assert(engine.build({enabled=true,allow_javascript=false,
    active="Fixture",preferences={},origins={Fixture={commit="test"}}}, root))
  assert(no_js.assets.bypass_csp == false
      and no_js.assets.document_bootstrap_source == no_js.popup_hook,
    "disabling theme JavaScript avoids CSP bypass and injects CSS bootstrap directly")

  -- A manifest may reuse one stylesheet for RootColors and Steam-WebKit. The
  -- WebKit route is browser-only, but the RootColors route must still reach
  -- native popups instead of inheriting that restriction through deduplication.
  local shared_dir = root .. "/SharedPath"
  fs.create_directories(shared_dir)
  local shared_manifest = assert(io.open(shared_dir .. "/skin.json", "w"))
  shared_manifest:write('{"name":"Shared Path","author":"A","description":"D",' ..
    '"RootColors":"shared.css","Steam-WebKit":"shared.css"}')
  shared_manifest:close()
  local shared_css = assert(io.open(shared_dir .. "/shared.css", "w"))
  shared_css:write(":root{--shared-path-marker:#123456}")
  shared_css:close()
  local shared_runtime = assert(engine.build({enabled=true,allow_javascript=true,
    active="SharedPath",preferences={},origins={SharedPath={commit="test"}}}, root))
  assert(shared_runtime.popup_hook:find("shared%-path%-marker"),
    "a RootColors file reused by Steam-WebKit remains available to native popups")
  fs.remove_all(root)
end

print("test_themes: ok")
