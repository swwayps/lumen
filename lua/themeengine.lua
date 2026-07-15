-- Convert the active Millennium skin into one idempotent per-target bootstrap.
local json = require("json")
local themes = require("themes")
local b64 = require("b64")

local engine = {}

engine.DEFAULT_PATCHES = {
  { MatchRegexString="^Steam$", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
  { MatchRegexString="^OverlayBrowser_Browser$", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
  { MatchRegexString="^SP Overlay:", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
  { MatchRegexString="Menu$", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
  { MatchRegexString="Supernav$", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
  { MatchRegexString="^notificationtoasts_", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
  { MatchRegexString="^SteamBrowser_Find$", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
  { MatchRegexString="^OverlayTab\\d+_Find$", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
  { MatchRegexString="^Steam Big Picture Mode$", TargetCss="bigpicture.custom.css", TargetJs="bigpicture.custom.js" },
  { MatchRegexString="^QuickAccess_", TargetCss="bigpicture.custom.css", TargetJs="bigpicture.custom.js" },
  { MatchRegexString="^MainMenu_", TargetCss="bigpicture.custom.css", TargetJs="bigpicture.custom.js" },
  { MatchRegexString=".friendsui-container", TargetCss="friends.custom.css", TargetJs="friends.custom.js" },
  { MatchRegexString=".ModalDialogPopup", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
  { MatchRegexString=".FullModalOverlay", TargetCss="libraryroot.custom.css", TargetJs="libraryroot.custom.js" },
}

local MIME = {
  png="image/png", jpg="image/jpeg", jpeg="image/jpeg", gif="image/gif", webp="image/webp",
  svg="image/svg+xml", woff="font/woff", woff2="font/woff2", ttf="font/ttf", otf="font/otf",
}

-- The SharedJSContext hook must be installed before Steam creates its login
-- window. Binary assets never belong in that parser-blocking JavaScript: the
-- native preload gate exposes the active theme directory under this same-origin
-- route immediately before steamwebhelper starts.
local POPUP_ASSET_PREFIX = "https://steamloopback.host/lumen-theme-assets/"

local function mime(path)
  local ext = (path:match("%.([^.]+)$") or ""):lower()
  return MIME[ext] or (ext == "css" and "text/css; charset=utf-8")
    or ((ext == "js" or ext == "mjs") and "text/javascript; charset=utf-8")
    or "application/octet-stream"
end

local function url_encode_path(path)
  return (path:gsub("[^%w%._~/%-]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function url_decode_path(path)
  return (path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h,16)) end))
end

local function read(path, binary)
  local f = io.open(path, binary and "rb" or "r")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function dirname(path) return path:match("^(.*)/[^/]*$") or "" end

local function normalize(base, rel)
  if rel:match("^[%a][%w+.-]*:") or rel:sub(1, 2) == "//" or rel:sub(1, 1) == "#" then return nil end
  local parts = {}
  for p in (base .. "/" .. rel):gmatch("[^/]+") do
    if p == ".." then if #parts == 0 then return nil end; parts[#parts] = nil
    elseif p ~= "." and p ~= "" then parts[#parts+1] = p end
  end
  return table.concat(parts, "/")
end

local function inline_css_assets(root, rel, css)
  local base = dirname(rel)
  return (css:gsub("url%((.-)%)", function(raw)
    local q = raw:match("^%s*(['\"])(.-)%1%s*$")
    local value = q and raw:match("^%s*['\"](.-)['\"]%s*$") or raw:match("^%s*(.-)%s*$")
    if not value then return "url(" .. raw .. ")" end
    local path = normalize(base, value)
    if not path then return "url(" .. raw .. ")" end
    local bytes = read(root .. "/" .. path, true)
    if not bytes then return "url(" .. raw .. ")" end
    local ext = path:match("%.([^.]+)$"); local mime = MIME[(ext or ""):lower()]
    if not mime then return "url(" .. raw .. ")" end
    return "url(data:" .. mime .. ";base64," .. b64.encode(bytes) .. ")"
  end))
end

local function bundle_css(root, rel, css, prefix, depth, stack, inline_urls, url_suffix)
  depth, stack = depth or 0, stack or {}
  if depth > 16 then return css end
  local base = dirname(rel)
  local function expand(path, original)
    local child_path = normalize(base, path)
    if not child_path or stack[child_path] then return original end
    local child = read(root .. "/" .. child_path, true)
    if not child then return original end
    stack[child_path] = true
    child = bundle_css(root, child_path, child, prefix, depth + 1, stack,
      inline_urls, url_suffix)
    stack[child_path] = nil
    return "\n/* lumen import: " .. child_path .. " */\n" .. child .. "\n"
  end
  css = css:gsub("@import%s+url%(%s*['\"]?([^'\"%)]+)['\"]?%s*%)%s*;", function(path)
    return expand(path, '@import url("' .. path .. '");')
  end)
  css = css:gsub("@import%s+['\"]([^'\"]+)['\"]%s*;", function(path)
    return expand(path, '@import "' .. path .. '";')
  end)
  return (css:gsub("url%((.-)%)", function(raw)
    local value = raw:match("^%s*['\"](.-)['\"]%s*$") or raw:match("^%s*(.-)%s*$")
    local path = value and normalize(base, value)
    if not path then return "url(" .. raw .. ")" end
    if inline_urls then
      local bytes = read(root .. "/" .. path, true)
      local limit = type(inline_urls) == "number" and inline_urls or math.huge
      local ext = (path:match("%.([^.]+)$") or ""):lower()
      local redundant_font_fallback = false
      if ext == "woff" or ext == "ttf" or ext == "otf" then
        local woff2_path = path:gsub("%.[^.]+$", ".woff2")
        redundant_font_fallback = read(root .. "/" .. woff2_path, true) ~= nil
      end
      if bytes and #bytes <= limit and not redundant_font_fallback then
        return "url(data:" .. mime(path) .. ";base64," .. b64.encode(bytes) .. ")"
      end
    end
    return 'url("' .. prefix .. url_encode_path(path) .. (url_suffix or "") .. '")'
  end))
end

local function inline_js_imports(root, rel, body, depth, stack)
  depth, stack = depth or 0, stack or {}
  if depth > 16 then return body end
  local base = dirname(rel)
  return (body:gsub("(['\"])(%.?%.?/[^'\"]+)%1", function(q, spec)
    local clean = spec:gsub("[?#].*$", "")
    local path = normalize(base, clean)
    if not path or stack[path] then return q .. spec .. q end
    local child = read(root .. "/" .. path, true)
    if not child then return q .. spec .. q end
    stack[path] = true
    child = inline_js_imports(root, path, child, depth + 1, stack)
    stack[path] = nil
    return q .. "data:text/javascript;base64," .. b64.encode(child) .. q
  end))
end

local function effective_patches(manifest)
  local incoming = manifest.Patches or {}
  if not manifest.UseDefaultPatches then return incoming end
  local override = {}
  for _, p in ipairs(incoming) do override[p.MatchRegexString] = true end
  local out = {}
  for _, p in ipairs(engine.DEFAULT_PATCHES) do
    if not override[p.MatchRegexString] then out[#out+1] = p end
  end
  for _, p in ipairs(incoming) do out[#out+1] = p end
  return out
end

local function add_asset(out, seen, root, kind, path, affects)
  if type(path) ~= "string" then return end
  local key = kind .. "\0" .. path
  if seen[key] then
    local asset, have = seen[key], {}
    for _, match in ipairs(asset.affects or {}) do have[match] = true end
    for _, match in ipairs(affects or {}) do
      if not have[match] then asset.affects[#asset.affects+1] = match; have[match] = true end
    end
    return asset
  end
  if not read(root .. "/" .. path, true) then return end
  local asset = { kind=kind, path=path, affects=affects or { ".*" } }
  seen[key] = asset
  out[#out+1] = asset
  return asset
end

local function add_targets(out, seen, root, kind, target, affects)
  if type(target) == "string" then
    add_asset(out, seen, root, kind, target, affects)
  elseif type(target) == "table" then
    for _, path in ipairs(target) do add_asset(out, seen, root, kind, path, affects) end
  end
end

local function condition_assets(manifest, prefs, root, out, seen, allow_js)
  if type(manifest.Conditions) ~= "table" then return end
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
    local choice = prefs[name] or c.default
    if type(c.slider) == "table" and type(c.slider.cssVariable) == "string" then
      local value = tonumber(choice) or tonumber(c.default)
      if value then
        local min, max = tonumber(c.slider.min), tonumber(c.slider.max)
        if min and value < min then value = min end
        if max and value > max then value = max end
        out[#out+1] = { kind="css", path="__lumen-slider-" .. name,
          body=":root{" .. c.slider.cssVariable .. ":" .. tostring(value) .. tostring(c.slider.unit or "") .. ";}",
          affects={".*"} }
      end
    end
    local value = type(c.values) == "table" and c.values[choice]
    if type(value) == "table" then
      local css = value.TargetCss
      local js = value.TargetJs
      if type(css) == "table" then add_asset(out, seen, root, "css", css.src, css.affects) end
      if allow_js and type(js) == "table" then add_asset(out, seen, root, "js", js.src, js.affects) end
    end
  end
end

-- RootColors names are intentionally theme-defined, not a Millennium schema.
-- Preserve the effective values (including user overrides) so each renderer
-- can resolve semantic Lumen roles without rereading files or guessing which
-- custom-property naming convention a theme happens to use.
local function palette_seed(manifest, dir, prefs)
  local out = json.array({})
  if type(manifest.RootColors) ~= "string" then return out end
  local css = read(dir .. "/" .. manifest.RootColors)
  if not css then return out end
  local chosen = type(prefs.__rootcolors) == "table" and prefs.__rootcolors or {}
  for name, default in css:gmatch("%-%-([%w_-]+)%s*:%s*([^;]+);") do
    default = default:match("^%s*(.-)%s*$")
    local value = type(chosen[name]) == "string" and chosen[name] or default
    out[#out+1] = { name=name, value=value }
  end
  return out
end

function engine.build(config, root)
  if not config or not config.enabled or type(config.active) ~= "string" then return nil end
  root = root or themes.root_path()
  local dir = root .. "/" .. config.active
  local origin = type(config.origins) == "table" and config.origins[config.active] or nil
  local version = type(origin) == "table" and origin.commit or nil
  version = tostring(version or ("session-" .. tostring(os.time()))):gsub("[^%w._-]", "-")
  local prefix = "https://lumen-theme.local/" .. url_encode_path(config.active)
    .. "/" .. url_encode_path(version) .. "/"
  local bootstrap_path = "__lumen_bootstrap.js"
  local bootstrap_body
  local manifest, err = themes.read_manifest(dir)
  if not manifest then return nil, err end
  local prefs = (config.preferences or {})[config.active] or {}
  local palette = palette_seed(manifest, dir, prefs)
  local assets, seen = {}, {}
  for _, p in ipairs(effective_patches(manifest)) do
    local affects = { p.MatchRegexString }
    add_targets(assets, seen, dir, "css", p.TargetCss, affects)
    if config.allow_javascript then add_targets(assets, seen, dir, "js", p.TargetJs, affects) end
  end
  if type(manifest["Steam-WebKit"]) == "string" then
    -- Keep this route separate from patch/RootColors deduplication. A theme is
    -- allowed to reuse the same file for both; only the Steam-WebKit use is
    -- browser-only, while its other role must still reach native popups.
    local path = manifest["Steam-WebKit"]
    if read(dir .. "/" .. path, true) then
      assets[#assets+1] = { kind="css", path=path,
        affects={ "https?://" }, browserOnly=true }
    end
  end
  if type(manifest.RootColors) == "string" then
    add_asset(assets, seen, dir, "css", manifest.RootColors, { ".*" })
    local chosen = prefs.__rootcolors
    if type(chosen) == "table" then
      local names = {}; for name in pairs(chosen) do names[#names+1] = name end
      table.sort(names)
      local rules = {}
      for _, name in ipairs(names) do
        if tostring(name):match("^[%w_-]+$") and type(chosen[name]) == "string" then
          rules[#rules+1] = "--" .. name .. ":" .. chosen[name] .. ";"
        end
      end
      if #rules > 0 then assets[#assets+1] = { kind="css", path="__lumen-root-colors.css",
        body=":root{" .. table.concat(rules) .. "}", affects={".*"} } end
    end
  end
  condition_assets(manifest, prefs, dir,
    assets, seen, config.allow_javascript)
  for _, asset in ipairs(assets) do
    if not asset.body then
      asset.url = prefix .. url_encode_path(asset.path)
    end
  end
  local payload = json.encode({ native=config.active, revision=version, palette=palette, assets=assets,
    promotePopup=false })
  local js = [[(function(P){
    window.__lumenThemePaletteSeed={theme:P.native,revision:P.revision,colors:P.palette||[]};
    Array.from(document.querySelectorAll('[id^="lumen-theme-"]')).forEach(function(n){
      if(n.id==="lumen-theme-prepaint"||n.id==="lumen-theme-transition"||n.id==="lumen-theme-transition-style")return;
      if(n.id.indexOf("lumen-theme-"+P.native+"-")!==0)n.remove();
    });
    var oldCompat=document.getElementById("lumen-luatools-icon-compat");if(oldCompat)oldCompat.remove();
    var probe=[document.title||window.title||"",location.href||""];
    if(document.body) probe=probe.concat(Array.from(document.body.classList).map(function(x){return "."+x}));
    if(document.documentElement) probe=probe.concat(Array.from(document.documentElement.classList).map(function(x){return "."+x}));
    if(probe[0]==="Steam Games List")probe.push("Steam");
    function hit(list){return list.some(function(x){return probe.some(function(v){try{return new RegExp(x).test(v)}catch(e){return false}})})}
    P.assets.forEach(function(a,i){
      if(a.browserOnly&&location.hostname==="steamloopback.host")return;
      if(!hit(a.affects||[".*"])) return;
      var previous=a.path?Array.from(document.querySelectorAll("[data-lumen-theme-asset]")).filter(function(n){return n.dataset.lumenThemeAsset===a.kind+":"+a.path}):[];
      if(previous.length)return;
      var id="lumen-theme-"+P.native+"-"+a.kind+"-"+i;
      if(document.getElementById(id)) return;
      if(a.kind==="css"){
        var s;if(a.body){s=document.createElement("style");s.textContent=a.body}else{s=document.createElement("link");s.rel="stylesheet";s.href=a.url}s.id=id;if(a.path)s.dataset.lumenThemeAsset=a.kind+":"+a.path;
        (document.head||document.documentElement).appendChild(s);
      }else{
        var s=document.createElement("script");s.id=id;s.type="module";
        s.src=a.body?URL.createObjectURL(new Blob([a.body],{type:"text/javascript"})):a.url;
        if(a.path)s.dataset.lumenThemeAsset=a.kind+":"+a.path;(document.head||document.documentElement).appendChild(s);
      }
    });
    // Themes commonly replace Steam's icon fonts with Fluent glyphs. Keep that
    // replacement out of LuaTools overlays, whose fa-* codepoints belong to
    // Font Awesome and otherwise render as missing-glyph boxes.
    if(!document.getElementById("lumen-luatools-icon-compat")){
      var compat=document.createElement("style");
      compat.id="lumen-luatools-icon-compat";
      compat.textContent=
        '[class*="luatools-"] .fa-solid,[class*="luatools-"] .fa-solid:before{'+
        'font-family:"Font Awesome 6 Free"!important;font-weight:900!important;}'+
        '[class*="luatools-"] .fa-brands,[class*="luatools-"] .fa-brands:before{'+
        'font-family:"Font Awesome 6 Brands"!important;font-weight:400!important;}';
      (document.head||document.documentElement).appendChild(compat);
    }
    window.__lumenThemeApplied=P.native;
    requestAnimationFrame(function(){requestAnimationFrame(function(){
      var t=document.getElementById("lumen-theme-transition");if(t)t.remove();
      var ts=document.getElementById("lumen-theme-transition-style");if(ts)ts.remove();
    })});
  })(]] .. payload .. ")"
  local function virtual_provider(url)
    if type(url) ~= "string" or url:sub(1,#prefix) ~= prefix then return nil, "not found" end
    local rel = url_decode_path(url:sub(#prefix+1):gsub("[?#].*$", ""))
    local safe = normalize("", rel)
    if not safe or safe ~= rel then return nil, "unsafe path" end
    if safe == bootstrap_path and bootstrap_body then
      return bootstrap_body, "text/javascript; charset=utf-8"
    end
    local bytes = read(dir .. "/" .. safe, true)
    if not bytes then return nil, "not found" end
    return bytes, mime(safe)
  end
  local popup_assets = {}
  local popup_asset_suffix = "?lumen-theme=" ..
    url_encode_path(config.active .. ":" .. version)
  for _, asset in ipairs(assets) do
    if asset.kind == "css" and not asset.browserOnly then
      local body = asset.body
      if not body and asset.path then
        local raw = read(dir .. "/" .. asset.path, true)
        if raw then body = bundle_css(dir, asset.path, raw, POPUP_ASSET_PREFIX,
          nil, nil, false, popup_asset_suffix) end
      end
      popup_assets[#popup_assets+1] = {
        body=body, path=asset.path, affects=asset.affects,
      }
    end
  end
  local popup_payload = json.encode({native=config.active, revision=version,
    palette=palette, assets=popup_assets})
  local popup_hook = [[(function(P){
    window.__lumenPopupThemeHook=P.native;
    function matches(patterns,probe){return (patterns||[".*"]).some(function(x){return probe.some(function(v){try{return new RegExp(x).test(v)}catch(e){return false}})})}
    function popupRoot(ctx){return ctx&&(ctx.root_element||ctx.m_element)}
    function isColdContextMenu(ctx){
      var params=ctx&&(ctx.params||ctx.m_rgParams)||{};
      var name=ctx&&ctx.m_strName||"";
      return !!(ctx&&ctx.m_bCreateHidden&&(name.indexOf("contextmenu")===0||params.bHideOnClose||String(params.body_class||"").indexOf("ContextMenuPopupBody")>=0));
    }
    function popupHasContent(ctx){var root=popupRoot(ctx);return !!(root&&root.firstElementChild)}
    function finishColdPopup(ctx,force){
      if(!force&&!popupHasContent(ctx))return false;
      ctx.__lumenPopupContentReady=true;
      if(ctx.__lumenPopupContentObserver){ctx.__lumenPopupContentObserver.disconnect();ctx.__lumenPopupContentObserver=null}
      var w=ctx&&ctx.window;
      if(ctx.__lumenPopupContentTimer){clearTimeout(ctx.__lumenPopupContentTimer);ctx.__lumenPopupContentTimer=null}
      patch(ctx,true);
      if(w&&w.__lumenThemeReveal)w.__lumenThemeReveal(false);
      var pending=ctx.__lumenPendingPopupFocus;ctx.__lumenPendingPopupFocus=null;
      var original=ctx.Focus&&ctx.Focus.__lumenOriginalFocus;
      if(pending&&typeof original==="function")setTimeout(function(){original.apply(pending.scope,pending.args)},0);
      return true;
    }
    function watchColdPopup(ctx){
      if(!isColdContextMenu(ctx)||ctx.__lumenPopupContentReady)return;
      if(finishColdPopup(ctx,false)||ctx.__lumenPopupContentObserver)return;
      var root=popupRoot(ctx),w=ctx&&ctx.window;if(!root||!w)return;
      var Observer=w.MutationObserver||MutationObserver;
      ctx.__lumenPopupContentObserver=new Observer(function(){finishColdPopup(ctx,false)});
      ctx.__lumenPopupContentObserver.observe(root,{childList:true,subtree:true});
      if(!ctx.__lumenPopupContentTimer)ctx.__lumenPopupContentTimer=setTimeout(function(){finishColdPopup(ctx,true)},8000);
    }
    function wrapColdPopupFocus(ctx){
      if(!isColdContextMenu(ctx)||typeof ctx.Focus!=="function"||ctx.__lumenFocusThemeHook===patch)return;
      var original=ctx.Focus.__lumenOriginalFocus||ctx.Focus;
      var wrapped=function(){
        if(ctx.__lumenPopupContentReady||popupHasContent(ctx)){ctx.__lumenPopupContentReady=true;return original.apply(this,arguments)}
        ctx.__lumenPendingPopupFocus={scope:this,args:Array.prototype.slice.call(arguments)};
        watchColdPopup(ctx);
      };
      wrapped.__lumenOriginalFocus=original;ctx.Focus=wrapped;ctx.__lumenFocusThemeHook=patch;
    }
    function patch(ctx,hold){
      try{
        var w=ctx&&ctx.window;if(!w||!w.document)return;var d=w.document;
        w.__lumenThemePaletteSeed={theme:P.native,revision:P.revision,colors:P.palette||[]};
        var guard=d.getElementById("lumen-theme-prepaint");
        var already=w.__lumenThemeApplied===P.native;
        if(!guard&&(!already||hold)){guard=d.createElement("style");guard.id="lumen-theme-prepaint";guard.textContent="body{visibility:hidden!important}";(d.head||d.documentElement).appendChild(guard)}
        function reveal(force){
          var nodes=Array.from(d.querySelectorAll('[data-lumen-theme-asset^="css:"]'));
          if(!force&&nodes.some(function(n){return n.tagName==="LINK"&&n.dataset.lumenThemeLoaded!=="1"&&!n.sheet}))return;
          if(w.__lumenThemeRevealTimer){clearTimeout(w.__lumenThemeRevealTimer);w.__lumenThemeRevealTimer=null}
          if(w.__lumenThemePrepaintTimer){clearTimeout(w.__lumenThemePrepaintTimer);w.__lumenThemePrepaintTimer=null}
          var g=d.getElementById("lumen-theme-prepaint");if(g)g.remove();
          var t=d.getElementById("lumen-theme-transition");if(t)t.remove();var ts=d.getElementById("lumen-theme-transition-style");if(ts)ts.remove();
        }
        w.__lumenThemeReveal=reveal;
        if(!w.__lumenThemeRevealTimer)w.__lumenThemeRevealTimer=setTimeout(function(){reveal(true)},8000);
        var title=ctx.title||ctx.m_strTitle||d.title||"";
        var params=ctx.params||ctx.m_rgParams||{};
        var name=ctx.m_strName||"",html=d.documentElement;
        if(html){
          if(name==="SP Desktop_uid0")html.classList.add("MillenniumWindow_MainSteamWindow");
          else if(name==="friendslist_uid0")html.classList.add("MillenniumWindow_FriendsList");
          else if(name.indexOf("chat_ChatWindow_")>=0)html.classList.add("MillenniumWindow_FriendChatWindow");
          if(name.indexOf("contextmenu")>=0){html.classList.add("MillenniumWindow_ContextMenu");html.classList.add(title.replace(/[^a-zA-Z0-9]/g,"_"))}
          if((params.minHeight===601&&params.minWidth===842)||(params.dimensions&&params.dimensions.minHeight===601&&params.dimensions.minWidth===842))html.classList.add("MillenniumWindow_GameProperties");
        }
        var classes=((params.body_class||"")+" "+(params.html_class||"")).trim().split(/\s+/).filter(Boolean).map(function(x){return "."+x});
        if(d.body)classes=classes.concat(Array.from(d.body.classList).map(function(x){return "."+x}));
        if(d.documentElement)classes=classes.concat(Array.from(d.documentElement.classList).map(function(x){return "."+x}));
        var probe=[title,d.location&&d.location.href||""].concat(classes);if(title==="Steam Games List")probe.push("Steam");
        Array.from(d.querySelectorAll('[id^="lumen-theme-"]')).forEach(function(n){
          if(n.id==="lumen-theme-prepaint"||n.id==="lumen-theme-transition"||n.id==="lumen-theme-transition-style")return;
          if(n.id.indexOf("lumen-theme-"+P.native+"-")!==0)n.remove();
        });
        P.assets.forEach(function(a,i){if(!matches(a.affects,probe))return;var key=a.path&&"css:"+a.path;if(key&&Array.from(d.querySelectorAll("[data-lumen-theme-asset]")).some(function(n){return n.dataset.lumenThemeAsset===key}))return;var id="lumen-theme-"+P.native+"-popup-css-"+i;if(d.getElementById(id))return;var s;if(a.body){s=d.createElement("style");s.textContent=a.body;s.dataset.lumenThemeLoaded="1"}else{s=d.createElement("link");s.rel="stylesheet";s.href=a.url;s.dataset.lumenThemeLoaded="0";var done=function(){s.dataset.lumenThemeLoaded="1";if(w.__lumenThemeReveal)w.__lumenThemeReveal(false)};s.addEventListener("load",done,{once:true});s.addEventListener("error",done,{once:true})}s.id=id;if(key)s.dataset.lumenThemeAsset=key;(d.head||d.documentElement).appendChild(s)});
        w.__lumenThemeApplied=P.native;
        if(!hold)setTimeout(function(){reveal(false)},0);
      }catch(e){}
    }
    function schedule(ctx){
      wrapColdPopupFocus(ctx);
      var hold=isColdContextMenu(ctx)&&!popupHasContent(ctx);
      patch(ctx,hold);if(hold)watchColdPopup(ctx);
      setTimeout(function(){var pending=isColdContextMenu(ctx)&&!popupHasContent(ctx);patch(ctx,pending);if(pending)watchColdPopup(ctx)},0);
      setTimeout(function(){var pending=isColdContextMenu(ctx)&&!popupHasContent(ctx);patch(ctx,pending);if(pending)watchColdPopup(ctx)},100);
      try{
        if(typeof ctx.m_fnReadyToRender==="function"&&ctx.__lumenReadyThemeHook!==patch){
          var original=ctx.m_fnReadyToRender.__lumenOriginalReady||ctx.m_fnReadyToRender;
          var wrapped=function(){
            var cold=isColdContextMenu(ctx);patch(ctx,cold);
            var result=original.apply(this,arguments);
            if(cold){patch(ctx,true);watchColdPopup(ctx);finishColdPopup(ctx,false)}else patch(ctx,false);
            return result;
          };
          wrapped.__lumenOriginalReady=original;ctx.m_fnReadyToRender=wrapped;ctx.__lumenReadyThemeHook=patch;
        }
      }catch(e){}
    }
    function armDocument(){
      var armKey=P.native+":"+P.revision;
      if(window.__lumenDocumentThemeArmed===armKey)return;
      if(!document.documentElement){setTimeout(armDocument,0);return}
      window.__lumenDocumentThemeArmed=armKey;
      var ctx={window:window,title:"",m_strTitle:"",params:{}};
      function apply(hold){ctx.title=document.title||"";ctx.m_strTitle=ctx.title;patch(ctx,hold)}
      apply(true);
      function coldContextDocument(){
        if(location.protocol!=="about:")return false;
        var menuWindow=location.search.indexOf("createflags=4538378")>=0||
          !!(document.body&&document.body.classList.contains("ContextMenuPopupBody"));
        if(!menuWindow)return false;
        var root=document.body&&document.body.firstElementChild;return !root||!root.firstElementChild;
      }
      var observer=new MutationObserver(function(){apply(true);if(document.readyState!=="loading"&&!coldContextDocument())ready()});
      observer.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:["class"]});
      function ready(){
        if(coldContextDocument())return;
        observer.disconnect();apply(false);
      }
      if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",ready,{once:true});else ready();
    }
    armDocument();
    function install(){
      try{
        if(typeof g_PopupManager==="undefined"||!g_PopupManager||typeof g_PopupManager.GetPopups!=="function"||typeof g_PopupManager.AddPopupCreatedCallback!=="function")return false;
        var key=P.native+":"+P.revision;
        if(window.__lumenPopupThemeInstalled===key){Array.from(g_PopupManager.GetPopups()).forEach(schedule);return true}
        window.__lumenPopupThemeInstalled=key;
        var activeSchedule=function(ctx){if(window.__lumenPopupThemeInstalled===key)schedule(ctx)};
        Array.from(g_PopupManager.GetPopups()).forEach(activeSchedule);g_PopupManager.AddPopupCreatedCallback(activeSchedule);return true;
      }catch(e){return false}
    }
    var sharedHost=location.hostname==="steamloopback.host"&&location.search.indexOf("IN_STEAMUI_SHARED_CONTEXT=true")>=0;
    if(!sharedHost)return;
    if(!install()){
      if(window.__lumenPopupThemeTimer)clearInterval(window.__lumenPopupThemeTimer);
      var tries=0;window.__lumenPopupThemeTimer=setInterval(function(){tries++;if(install()||tries>=500){clearInterval(window.__lumenPopupThemeTimer);window.__lumenPopupThemeTimer=null}},10);
    }
  })(]] .. popup_payload .. ")"
  -- The compiled popup hook may contain megabytes of theme CSS and fonts.  It
  -- is too large for the one timing-critical job at cold boot: hiding a popup
  -- before its first default frame.  Install this tiny callback first, then let
  -- the normal SharedJSContext route deliver the complete hook once Steam is
  -- ready.  The full hook removes the guard only after its styles are present.
  local popup_guard_payload = json.encode({native=config.active, revision=version})
  local popup_guard_hook = [[(function(P){
    var key=P.native+":"+P.revision;
    function guard(ctx){
      try{
        var w=ctx&&ctx.window,d=w&&w.document;if(!d||w.__lumenThemeApplied===P.native)return;
        var g=d.getElementById("lumen-theme-prepaint");
        if(!g){g=d.createElement("style");g.id="lumen-theme-prepaint";g.textContent="body{visibility:hidden!important}";(d.head||d.documentElement).appendChild(g)}
        if(w.__lumenThemePrepaintTimer)w.clearTimeout(w.__lumenThemePrepaintTimer);
        w.__lumenThemePrepaintTimer=w.setTimeout(function(){var n=d.getElementById("lumen-theme-prepaint");if(n)n.remove();w.__lumenThemePrepaintTimer=null},8000);
      }catch(e){}
    }
    function install(manager){
      try{
        var pm=manager||window.g_PopupManager;
        if(!pm||typeof pm.GetPopups!=="function"||typeof pm.AddPopupCreatedCallback!=="function")return false;
        if(window.__lumenPopupPrepaintInstalled===key){Array.from(pm.GetPopups()).forEach(guard);return true}
        window.__lumenPopupPrepaintInstalled=key;
        var active=function(ctx){if(window.__lumenPopupPrepaintInstalled===key)guard(ctx)};
        Array.from(pm.GetPopups()).forEach(active);pm.AddPopupCreatedCallback(active);return true;
      }catch(e){return false}
    }
    function trapPopupManager(){
      try{
        var desc=Object.getOwnPropertyDescriptor(window,"g_PopupManager");
        if(desc&&!desc.configurable)return;
        var value=desc&&desc.value;
        Object.defineProperty(window,"g_PopupManager",{configurable:true,enumerable:true,
          get:function(){return value},set:function(next){value=next;install(next)}});
        if(value)install(value);
      }catch(e){}
    }
    trapPopupManager();
    if(!install()){
      if(window.__lumenPopupPrepaintTimerHost)clearInterval(window.__lumenPopupPrepaintTimerHost);
      var tries=0;window.__lumenPopupPrepaintTimerHost=setInterval(function(){tries++;if(install()||tries>=500){clearInterval(window.__lumenPopupPrepaintTimerHost);window.__lumenPopupPrepaintTimerHost=null}},10);
    }
  })(]] .. popup_guard_payload .. ")"
  local bootstrap_hash = 0
  for i = 1, #popup_hook do
    bootstrap_hash = (bootstrap_hash * 131 + popup_hook:byte(i)) % 2147483647
  end
  bootstrap_path = string.format("__lumen_bootstrap-%08x.js", bootstrap_hash)
  bootstrap_body = popup_hook
  local document_bootstrap_url = prefix .. bootstrap_path
  local document_bootstrap = [[(function(u){
    var d=document;
    var waitForRoot;
    function hide(){
      var root=d.head||d.documentElement;
      if(!root){
        if(!waitForRoot){
          waitForRoot=new MutationObserver(function(){
            if(!d.documentElement)return;
            waitForRoot.disconnect();waitForRoot=null;hide();
          });
          waitForRoot.observe(d,{childList:true});
        }
        return;
      }
      if(d.getElementById("lumen-theme-prepaint"))return;
      var guard=d.createElement("style");guard.id="lumen-theme-prepaint";
      guard.textContent="body{visibility:hidden!important}";root.appendChild(guard);
    }
    function reveal(){var guard=d.getElementById("lumen-theme-prepaint");if(guard)guard.remove()}
    function failed(){
      if(location.protocol==="about:"&&location.search.indexOf("createflags=4538378")>=0)setTimeout(reveal,8000);
      else reveal();
    }
    hide();import(u).catch(failed);
  })(]] .. json.encode(document_bootstrap_url) .. ")"
  -- Dynamic import keeps the per-target registration tiny, but Steam's CSP
  -- permits it only when the user has explicitly allowed theme JavaScript.
  -- With JavaScript disabled, inject the compiled CSS bootstrap directly and
  -- leave CSP untouched so the security toggle has real meaning.
  local registered_bootstrap = config.allow_javascript
    and document_bootstrap or popup_hook
  return { native=config.active,
    assets={ polyfill=nil, css={}, js={js}, id_prefix="theme-" .. config.active,
      virtual_provider=virtual_provider,
      document_bootstrap_url=document_bootstrap_url,
      document_bootstrap_source=registered_bootstrap,
      shared_bootstrap_source=registered_bootstrap,
      bypass_csp=config.allow_javascript == true },
    popup_guard_hook=popup_guard_hook,
    popup_hook=popup_hook,
    popup_asset_root=dir,
    manifest=manifest }
end

return engine
