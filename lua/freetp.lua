-- freetp.lua — Lumen backend for the FreeTP Fix tile's freetp.org path.
--
-- FreeTP (freetp.org) publishes one DLE article per game under the "по сети"
-- (over the network) category and hosts the fix as an on-site attachment
-- (getfile-XXXX). The chain: DLE search -> the game's article -> its
-- installable attachment (setup .exe or archive; full-game .torrent repacks
-- are skipped) -> index.php?do=download&id=XXXX with the getfile page as
-- Referer -> file signature check. The frontend then installs the file
-- through fixinstall, recorded, so Unfix can revert it.
--
-- DLE search answers a plain GET (index.php?do=search&subaction=search&story=),
-- so resolution costs two small requests at click time — no crawl of the
-- listing pages and no standing cache.
--
-- The pure helpers are unit-tested with real saved page HTML
-- (tools/test_freetp.lua); resolve() and download_fix() take injectable deps
-- and never touch Millennium or the network in tests.

local freetp = {}

freetp.BASE_URL = "https://freetp.org"
freetp.SEARCH_URL = freetp.BASE_URL .. "/index.php?do=search&subaction=search&story="
local BASE_PATTERN = freetp.BASE_URL:gsub("%p", "%%%0")

-- Percent-encode a search query value (unreserved characters stay literal).
function freetp.urlencode(value)
  return (tostring(value or ""):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

-- Blank out the HTML entities that appear in DLE titles, so a word like "&amp;"
-- can never leak into a normalized name as a phantom "amp" word.
local function clean_title(title)
  return (tostring(title or "")
    :gsub("&#%d+;", " ")
    :gsub("&%a+;", " "))
end

-- Lowercase [a-z0-9] words concatenated: the same matching shape as the
-- online-fix mirror's normalize (luatools-moon onlinefix.lua), without its
-- game-specific special cases. Cyrillic article filler ("играть по
-- сети и интернету Онлайн") is dropped by the character class, so
-- normalize("CRACK играть по сети и интернету Онлайн") == normalize("CRACK").
function freetp.normalize(name)
  if type(name) ~= "string" then return "" end
  local words = {}
  for word in clean_title(name):lower():gmatch("[a-z0-9]+") do words[#words + 1] = word end
  return table.concat(words)
end

-- parse_search(html) -> list of { url, title } for po-seti articles.
-- Anchors whose text carries no Latin word at all (the "Подробнее"
-- navigation link) are skipped, so the per-URL dedup below can never let
-- navigation text steal a title's slot.
function freetp.parse_search(html)
  local out = {}
  if type(html) ~= "string" then return out end
  local seen = {}
  for url, title in html:gmatch(
      'href="(' .. BASE_PATTERN .. '/po%-seti/%d+%-[^"]+%.html)"[^>]*>([^<]*)</a>') do
    if not seen[url] and freetp.normalize(title) ~= "" then
      seen[url] = true
      out[#out + 1] = { url = url, title = clean_title(title) }
    end
  end
  return out
end

-- pick_article(entries, game_name) -> the entry whose title matches the Steam
-- game name after normalization, or nil. Exact match only, so "CRACK" never
-- matches "The Crackpet Show".
function freetp.pick_article(entries, game_name)
  local target = freetp.normalize(game_name)
  if target == "" then return nil end
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    if freetp.normalize(e and e.title) == target then return e end
  end
  return nil
end

-- resolve(game_name, get) -> { files, errorCode? }: the getfile attachments
-- of the game's po-seti article. errorCode says there is no article
-- (no_name, search_failed, no_page) or it could not be read (page_failed), so
-- a network failure is never mistaken for "no fix". Two sequential requests,
-- 6 s timeout each, matching the single-threaded-loop budget the online-fix
-- resolver established (12 s worst case).
function freetp.resolve(game_name, get)
  local res = { files = {} }
  if type(game_name) ~= "string" or game_name == "" then
    res.errorCode = "no_name"
    return res
  end
  local ok_s, search = pcall(get,
    freetp.SEARCH_URL .. freetp.urlencode(game_name), { timeout = 6 })
  if not ok_s or type(search) ~= "table" or search.status ~= 200
      or type(search.body) ~= "string" then
    res.errorCode = "search_failed"
    return res
  end
  local article = freetp.pick_article(freetp.parse_search(search.body), game_name)
  if not article then
    res.errorCode = "no_page"
    return res
  end
  local ok_a, page = pcall(get, article.url, { timeout = 6 })
  if ok_a and type(page) == "table" and page.status == 200
      and type(page.body) == "string" then
    res.files = freetp.parse_article_files(page.body)
  else
    res.errorCode = "page_failed"
  end
  return res
end

-- parse_article_files(html) -> { { id, url, label } } for the article's
-- getfile-XXXX attachments. Labels are the anchor text (they usually carry
-- the real file name: "…Multiplayer Fix Online.exe" vs "…by Pioneer.torrent"). PURE.
function freetp.parse_article_files(html)
  local out = {}
  if type(html) ~= "string" then return out end
  local seen = {}
  for id, label in html:gmatch(
      'href="[^"]*getfile%-(%d+)[^"]*"[^>]*>([^<]+)') do
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = {
        id = id,
        url = freetp.BASE_URL .. "/getfile-" .. id,
        label = label:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""),
      }
    end
  end
  return out
end

-- File signature per installable extension, checked on the downloaded body.
local FILE_MAGIC = { exe = "MZ", zip = "PK\x03\x04", rar = "Rar!",
  ["7z"] = "7z\xbc\xaf\x27\x1c" }

-- pick_fix_file(files) -> { id, url, label, ext?, magic? } for the first
-- directly installable attachment (.exe setup or an archive), skipping
-- full-game .torrent repacks, or nil. The label's LAST extension decides, so
-- "fix.exe.rar" is a rar and "…by Pioneer.torrent" is never picked. A label
-- without a file name ("How to Fish-Multiplayer-Fix-Online-v1.5") is the
-- fallback, picked without ext: download_fix decides by file signature. PURE.
function freetp.pick_fix_file(files)
  local fallback
  for _, f in ipairs(type(files) == "table" and files or {}) do
    local ext
    for e in string.lower(tostring(f and f.label or "")):gmatch("%.(%w+)") do
      if FILE_MAGIC[e] or e == "torrent" then ext = e end
    end
    if ext ~= "torrent" and (ext or not fallback) then
      local pick = {}
      for k, v in pairs(f) do pick[k] = v end
      pick.ext = ext
      pick.magic = ext and FILE_MAGIC[ext]
      if ext then return pick end
      fallback = pick
    end
  end
  return fallback
end

-- download_fix(appid, game_name, deps) -> { success, path, size } or
-- { success = false, errorCode }: resolve the article, pick its installable
-- fix file, fetch /index.php?do=download&id=<id> with the getfile page as
-- Referer, check the file signature, and store it in fixinstall's download
-- dir, which install empties once the fix is extracted. deps: get /
-- write_file / mkdir / dl_dir, injectable for tests. The RPC loop is
-- single-threaded, so the file fetch is capped (30 s, 64 MB): FreeTP's fix
-- setups are a few MB.
function freetp.download_fix(appid, game_name, deps)
  deps = deps or {}
  local res = { success = false }
  appid = tonumber(appid)
  if not appid then
    res.errorCode = "invalid_appid"
    return res
  end
  local get = deps.get
  if not get then
    local ok, http = pcall(require, "http")
    if not ok or type(http) ~= "table" or type(http.get) ~= "function" then
      res.errorCode = "http_unavailable"
      return res
    end
    get = http.get
  end
  local write_file = deps.write_file or function(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
  end
  local mkdir = deps.mkdir or function(path)
    os.execute("mkdir -p -- " .. shell_quote(path) .. " 2>/dev/null")
    return true
  end

  local resolved = freetp.resolve(game_name, get)
  if resolved.errorCode then
    res.errorCode = resolved.errorCode
    return res
  end
  local pick = freetp.pick_fix_file(resolved.files)
  if not pick then
    res.errorCode = "no_fix_file"
    return res
  end
  local dl_url = freetp.BASE_URL
    .. "/index.php?do=download&id=" .. freetp.urlencode(pick.id)
  local ok_dl, dl = pcall(get, dl_url, {
    headers = { ["Referer"] = pick.url },
    timeout = 30,
    max_bytes = 64 * 1024 * 1024,
  })
  if not ok_dl or type(dl) ~= "table" or dl.status ~= 200
      or type(dl.body) ~= "string" or #dl.body == 0 then
    res.errorCode = "download_failed"
    return res
  end
  if not pick.ext then
    for ext, magic in pairs(FILE_MAGIC) do
      if dl.body:sub(1, #magic) == magic then pick.ext, pick.magic = ext, magic end
    end
  end
  if not pick.magic or dl.body:sub(1, #pick.magic) ~= pick.magic then
    res.errorCode = "wrong_content"
    return res
  end
  local home = os.getenv("HOME") or ""
  if home == "" then
    res.errorCode = "no_home"
    return res
  end
  local dir = deps.dl_dir or require("fixinstall").download_dir(home)
  mkdir(dir)
  local path = dir .. "/" .. appid .. "-freetp-fix." .. pick.ext
  if not write_file(path, dl.body) then
    res.errorCode = "write_failed"
    return res
  end
  res.success = true
  res.path = path
  res.size = #dl.body
  return res
end

-- register(registry, deps): install LumenDownloadFreeTPFix, wrapping the
-- table-returning core in JSON encoding (the dispatch contract). `deps` is
-- passed straight to the core — inject it from tests; production leaves it
-- nil so it uses the Lumen http client. The bridge passes
-- {appid, contentScriptQuery, gameName} alphabetically positional; the table
-- form is tolerated too.
function freetp.register(registry, deps)
  local json = require("json")
  registry.LumenDownloadFreeTPFix = function(appid, contentScriptQuery, gameName)
    if type(appid) == "table" then
      gameName = appid.gameName
      appid = appid.appid
    end
    local ok, res = pcall(freetp.download_fix, appid, gameName, deps)
    if not ok then
      return json.encode({ success = false, error = tostring(res) })
    end
    return json.encode(res)
  end
  return registry
end

return freetp
