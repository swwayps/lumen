-- freetp.lua — Lumen backend for the FreeTP Fix tile's freetp.org path.
--
-- FreeTP (freetp.org) publishes one DLE article per game under the "по сети"
-- (over the network) category and hosts the fix as an on-site attachment
-- (getfile-XXXX). The chain: DLE search -> the game's article -> its fix
-- attachment (setup .exe or archive; full-game .torrent repacks and game
-- update setups are skipped) -> index.php?do=download&id=XXXX with the
-- getfile page as Referer, fetched in the background -> file signature
-- check. The frontend then installs the file
-- through fixinstall, recorded, so Unfix can revert it.
--
-- DLE search answers a plain GET (index.php?do=search&subaction=search&story=),
-- so resolution costs a few small requests at click time — no crawl of the
-- listing pages and no standing cache.
--
-- The pure helpers are unit-tested with real saved page HTML
-- (tools/test_freetp.lua); resolve() and the download job take injectable deps
-- and never touch Millennium or the network in tests.

local freetp = {}

freetp.BASE_URL = "https://freetp.org"
freetp.SEARCH_URL = freetp.BASE_URL .. "/index.php?do=search&subaction=search&story="
-- Search pages are 12 results each and the game's article may sit a few pages
-- in ("Raft" is on page 2). Every search request blocks the single-threaded
-- RPC loop, so resolve stops at MAX_SEARCH_REQUESTS or once SEARCH_BUDGET
-- seconds have passed, whichever comes first.
freetp.MAX_SEARCH_REQUESTS = 5
freetp.SEARCH_BUDGET = 15
freetp.PAGE_MAX_BYTES = 2 * 1024 * 1024
-- The fix file itself downloads in the background (start/poll), so a slow
-- connection gets minutes instead of the blocking request cap.
freetp.DOWNLOAD_TIMEOUT = 300
freetp.MAX_FIX_BYTES = 64 * 1024 * 1024
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

-- search_url(query, page) -> the DLE search URL; later result pages are asked
-- for by page number (search_start), as the site's own pager does.
function freetp.search_url(query, page)
  local url = freetp.SEARCH_URL .. freetp.urlencode(query)
  if page and page > 1 then
    url = url .. "&search_start=" .. math.floor(page) .. "&full_search=0"
  end
  return url
end

-- next_search_page(html) -> the page number the search page's "next" link
-- submits, or nil on the last page. PURE.
function freetp.next_search_page(html)
  if type(html) ~= "string" then return nil end
  return tonumber(html:match('id="nextlink"[^>]*list_submit%((%d+)%)'))
end

-- plain_query(name) -> the name with ASCII punctuation deleted: DLE finds
-- nothing for "R.E.P.O." but finds "REPO". PURE.
function freetp.plain_query(name)
  return (tostring(name or ""):gsub("%p", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- resolve(game_name, get, clock) -> { files, errorCode? }: the getfile
-- attachments of the game's po-seti article. errorCode says there is no
-- article (no_name, no_page) or it could not be looked up or read
-- (search_failed, page_failed), so a network failure is never mistaken for
-- "no fix". Search order: the name as is, then without punctuation, then the
-- next result pages of those searches, within MAX_SEARCH_REQUESTS and
-- SEARCH_BUDGET; then the article. clock defaults to os.time.
function freetp.resolve(game_name, get, clock)
  local res = { files = {} }
  if type(game_name) ~= "string" or game_name == "" then
    res.errorCode = "no_name"
    return res
  end
  clock = clock or os.time
  local deadline = clock() + freetp.SEARCH_BUDGET
  local requests, failed = 0, false
  local function search(query, page)
    local left = deadline - clock()
    if requests >= freetp.MAX_SEARCH_REQUESTS or left <= 0 then return nil end
    requests = requests + 1
    local ok, r = pcall(get, freetp.search_url(query, page),
      { timeout = math.max(1, math.min(6, left)), max_bytes = freetp.PAGE_MAX_BYTES })
    if not ok or type(r) ~= "table" or r.status ~= 200 or type(r.body) ~= "string" then
      failed = true
      return nil
    end
    return r.body
  end

  local queries = { game_name }
  local plain = freetp.plain_query(game_name)
  if plain ~= "" and plain ~= game_name then queries[2] = plain end
  local article
  local more = {}
  for _, query in ipairs(queries) do
    local body = search(query, 1)
    article = body and freetp.pick_article(freetp.parse_search(body), game_name)
    if article then break end
    local nxt = body and freetp.next_search_page(body)
    if nxt and nxt > 1 then more[#more + 1] = { query = query, page = nxt } end
  end
  for _, m in ipairs(more) do
    if article then break end
    while m.page and not article do
      local body = search(m.query, m.page)
      article = body and freetp.pick_article(freetp.parse_search(body), game_name)
      local nxt = body and freetp.next_search_page(body)
      m.page = nxt and nxt > m.page and nxt or nil
    end
  end
  if not article then
    res.errorCode = failed and "search_failed" or "no_page"
    return res
  end
  local ok_a, page = pcall(get, article.url,
    { timeout = 6, max_bytes = freetp.PAGE_MAX_BYTES })
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

-- Label words of a game update or patch setup ("Left_4_Dead_2_Update-v2220-2243.exe"):
-- installing one over the game is never the fix.
local UPDATE_WORDS = { update = true, updates = true, upd = true, patch = true, hotfix = true }
local FIX_WORDS = { fix = true, fixes = true }

-- The label's lowercase ASCII words; camel case splits ("OnlineFix" -> online,
-- fix), so "Fix" is matched as a word and never inside "Hotfix".
local function label_words(label)
  local words = {}
  local spaced = tostring(label or ""):gsub("(%l)(%u)", "%1 %2"):lower()
  for w in spaced:gmatch("%a+") do words[w] = true end
  return words
end

local function has_word(words, set)
  for w in pairs(words) do
    if set[w] then return true end
  end
  return false
end

-- pick_fix_file(files) -> { id, url, label, ext?, magic? } for the attachment
-- most likely to be the fix, or nil. Full-game .torrent repacks are skipped,
-- and so are update/patch setups whose label does not also say "fix". A label
-- saying "fix" wins whatever its extension (one that also says "update" comes
-- after a plain fix), then a label with an installable extension (.exe setup
-- or an archive), then page order. The label's LAST
-- extension decides the type, so "fix.exe.rar" is a rar. A label without a
-- file name ("How to Fish-Multiplayer-Fix-Online-v1.5") is picked without
-- ext: the download is typed by its file signature. PURE.
function freetp.pick_fix_file(files)
  local best, best_score
  for _, f in ipairs(type(files) == "table" and files or {}) do
    local label = tostring(f and f.label or "")
    local ext
    for e in label:lower():gmatch("%.(%w+)") do
      if FILE_MAGIC[e] or e == "torrent" then ext = e end
    end
    local words = label_words(label)
    local fix, update = has_word(words, FIX_WORDS), has_word(words, UPDATE_WORDS)
    if ext ~= "torrent" and (fix or not update) then
      local score = (fix and 4 or 0) - (update and 2 or 0) + (ext and 1 or 0)
      if not best_score or score > best_score then
        best = {}
        for k, v in pairs(f) do best[k] = v end
        best.ext = ext
        best.magic = ext and FILE_MAGIC[ext]
        best_score = score
      end
    end
  end
  return best
end

-- The download dir (fixinstall's, which install empties), or nil without HOME.
local function download_dir(deps)
  if deps.dl_dir then return deps.dl_dir end
  local home = os.getenv("HOME") or ""
  if home == "" then return nil end
  return require("fixinstall").download_dir(home)
end

-- http client functions: deps.get / deps.start / deps.poll, else Lumen's.
local function http_fn(deps, name)
  if deps[name] then return deps[name] end
  local ok, http = pcall(require, "http")
  return ok and type(http) == "table" and type(http[name]) == "function" and http[name] or nil
end

-- start_download(appid, game_name, deps) -> job: resolve the article and pick
-- its fix file (a few small blocking requests), then start fetching
-- /index.php?do=download&id=<id> with the getfile page as Referer in the
-- background; poll_download advances the job. A job that failed before the
-- fetch carries its result already. deps: get / start / poll / write_file /
-- mkdir / dl_dir / clock, injectable for tests.
function freetp.start_download(appid, game_name, deps)
  deps = deps or {}
  local job = {}
  local function fail(code)
    job.result = { success = false, errorCode = code }
    return job
  end
  job.appid = tonumber(appid)
  if not job.appid then return fail("invalid_appid") end
  local get, start = http_fn(deps, "get"), http_fn(deps, "start")
  if not get or not start or not http_fn(deps, "poll") then return fail("http_unavailable") end

  local resolved = freetp.resolve(game_name, get, deps.clock)
  if resolved.errorCode then return fail(resolved.errorCode) end
  local pick = freetp.pick_fix_file(resolved.files)
  if not pick then return fail("no_fix_file") end
  local ok, handle = pcall(start, freetp.BASE_URL
    .. "/index.php?do=download&id=" .. freetp.urlencode(pick.id), {
    headers = { ["Referer"] = pick.url },
    timeout = freetp.DOWNLOAD_TIMEOUT,
    max_bytes = freetp.MAX_FIX_BYTES,
  })
  if not ok or not handle then return fail("download_failed") end
  job.pick, job.handle = pick, handle
  return job
end

-- Check the fetched body's file signature and store it as
-- <download dir>/<appid>-freetp-fix.<ext>.
local function store_download(job, dl, deps)
  local res = { success = false }
  local pick = job.pick
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

  if type(dl) ~= "table" or dl.status ~= 200
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
  local dir = download_dir(deps)
  if not dir then
    res.errorCode = "no_home"
    return res
  end
  mkdir(dir)
  local path = dir .. "/" .. job.appid .. "-freetp-fix." .. pick.ext
  if not write_file(path, dl.body) then
    res.errorCode = "write_failed"
    return res
  end
  res.success = true
  res.path = path
  res.size = #dl.body
  return res
end

-- poll_download(job, deps) -> the job's result once it has one,
-- { success, path, size } or { success = false, errorCode }; nil while the
-- file is still downloading.
function freetp.poll_download(job, deps)
  deps = deps or {}
  if job.result then return job.result end
  local ok, done, dl = pcall(http_fn(deps, "poll"), job.handle)
  if ok and done ~= true then return nil end
  job.handle = nil
  job.result = store_download(job, ok and dl or nil, deps)
  return job.result
end

-- discard_download(appid, deps): delete the file a download job stored for
-- appid (the menu was closed before installing it).
function freetp.discard_download(appid, deps)
  deps = deps or {}
  appid = tonumber(appid)
  local dir = download_dir(deps)
  if not appid or not dir then return end
  local remove = deps.remove_file or os.remove
  for ext in pairs(FILE_MAGIC) do
    remove(dir .. "/" .. appid .. "-freetp-fix." .. ext)
  end
end

-- register(registry, deps): install LumenDownloadFreeTPFix and
-- LumenDiscardFreeTPDownload, wrapping the table-returning cores in JSON
-- encoding (the dispatch contract). `deps` is passed straight to the cores —
-- inject it from tests; production leaves it nil so it uses the Lumen http
-- client. LumenDownloadFreeTPFix starts a download job on the first call and
-- advances it on each later call for the same appid, answering
-- { success = true, pending = true } until it has the result; the frontend
-- polls it. The bridge passes {appid, contentScriptQuery, gameName}
-- alphabetically positional; the table form is tolerated too.
function freetp.register(registry, deps)
  local json = require("json")
  local clock = (deps and deps.clock) or os.time
  local jobs = {}
  registry.LumenDownloadFreeTPFix = function(appid, contentScriptQuery, gameName)
    if type(appid) == "table" then
      gameName = appid.gameName
      appid = appid.appid
    end
    local ok, res = pcall(function()
      local key = tonumber(appid)
      local job = key and jobs[key]
      -- A job nobody polls any more (its menu was closed) starts over.
      if job and clock() - job.polled > 30 then job = nil end
      if not job then
        job = freetp.start_download(appid, gameName, deps)
        if key then jobs[key] = job end
      end
      job.polled = clock()
      local result = freetp.poll_download(job, deps)
      if not result then return { success = true, pending = true } end
      if key then jobs[key] = nil end
      return result
    end)
    if not ok then
      return json.encode({ success = false, error = tostring(res) })
    end
    return json.encode(res)
  end
  -- {appid, contentScriptQuery} sorted.
  registry.LumenDiscardFreeTPDownload = function(appid, contentScriptQuery)
    if type(appid) == "table" then appid = appid.appid end
    local key = tonumber(appid)
    if key then jobs[key] = nil end
    local ok, err = pcall(freetp.discard_download, appid, deps)
    return json.encode(ok and { success = true } or { success = false, error = tostring(err) })
  end
  return registry
end

return freetp
