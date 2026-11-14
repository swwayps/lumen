-- Host tests for freetp.lua: the FreeTP (freetp.org) resolver and downloader
-- behind the FreeTP Fix tile — search-result parsing with REAL saved page
-- shapes, normalized name matching, on-site attachment picking, and the
-- resolve()/download_fix() orchestration with injected effects (no real http).
-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_freetp.lua
package.path = "lua/?.lua;" .. package.path

local ft = require("freetp")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.write("FAIL: " .. name .. "\n") end
end

-- ── fixtures (verbatim shapes from freetp.org, 2026-11-08) ───────────────────
local SEARCH_HTML = [==[
<div class="search-results">
<h2><a href="https://freetp.org/po-seti/7365-crack-po-seti-besplatno.html">CRACK играть по сети и интернету Онлайн</a></h2>
<a href="https://freetp.org/po-seti/7365-crack-po-seti-besplatno.html">Подробнее</a>
<h2><a href="https://freetp.org/po-seti/5013-the-crackpet-show-igra-po-seti-i-internetu-onlayn.html">The Crackpet Show играть по сети и интернету Онлайн</a></h2>
<a href="https://freetp.org/po-seti/5013-the-crackpet-show-igra-po-seti-i-internetu-onlayn.html">Подробнее</a>
<h2><a href="https://freetp.org/po-seti/5625-new-star-gp-po-seti-i-internetu.html">New Star GP играть по сети и интернету Онлайн</a></h2>
<a href="https://freetp.org/po-seti/5625-new-star-gp-po-seti-i-internetu.html">Подробнее</a>
<h2><a href="https://freetp.org/po-seti/7111-reanimal-igra-po-seti-i-internetu-onlayn.html">REANIMAL играть по сети и Интернету Онлайн</a></h2>
<a href="https://freetp.org/po-seti/7111-reanimal-igra-po-seti-i-internetu-onlayn.html">Подробнее</a>
<h2><a href="https://freetp.org/po-seti/15-left-4-dead-2-zapusk-po-internetu-i-seti-lan-online.html">Left 4 Dead 2 играть по сети и интернету Онлайн / ЛАН</a></h2>
</div>
]==]

-- The CRACK article's shape: a redirect link, an ad button, community links,
-- a file-host link in a user comment, and the one on-site getfile attachment
-- (see GETFILE_PAGE_HTML below for the chain tests).
local CRACK_PAGE_HTML = [==[
<p style="color:orange">&nbsp;- В случае <a href="https://freetp.org/index.php?do=go&amp;encryptedurl=U2FsdGVkX1" target="_blank" data-encode="true">CRACK в Steam</a>.</p>
<hr>
<p style="text-align:center;"><strong><span style="color:#b500b5;"><a href="https://ads.example/r/1" rel="nofollow noopener external noreferrer" target="_blank">СКАЧАТЬ</a></span></strong></p>
<a href="https://chat.example/invite">Discord FreeTP</a>
<a href="https://messenger.example/channel">Telegram</a>
<a href="https://store.steampowered.com/app/4312190/CRACK/">Steam</a>
<div class="text share-content ftp-comment__text"><div id='comm-id-128033'><p>comment<br><a href="https://filehost.example/f/abc" target="_blank" rel="noopener external nofollow noreferrer">https://filehost.example/f/abc</a></p></div></div>
<p><a href="//freetp.org/getfile-20665" target="_blank">Скачать CRACK Simulator Multiplayer Fix Online.exe</a></p>
]==]

-- An article whose only links are an ad and community invites: no attachment.
local DISCORD_ONLY_PAGE_HTML = [==[
<a href="https://ads.example/r/1" rel="nofollow" target="_blank">СКАЧАТЬ</a>
<a href="https://chat.example/invite">Discord FreeTP</a>
<a href="https://messenger.example/channel">Telegram</a>
]==]

-- The CRACK article also carries FreeTP's own getfile-XXXX attachments: the
-- small Inno fix setup and the full-game repack torrent (verbatim shapes).
local GETFILE_PAGE_HTML = [==[
<p><strong>1.2) Скачать Онлайн фикс CRACK </strong>(Стим фикс)</p>
<div class="quote_block noncontenteditable"> <div class="quote"> <div class="quote_body contenteditable"> <p><a href="//freetp.org/getfile-20665" target="_blank">Скачать CRACK Simulator Multiplayer Fix Online.exe</a> <br>[Устанавливаем в папку с игрой]</p> </div> </div> </div>
<p><a href="//freetp.org/getfile-20797" target="_blank">Скачать CRACK v1.1.29 by Pioneer.torrent</a> <br>[0.8 Gb]</p>
]==]

-- Left 4 Dead 2's attachments (verbatim shapes): repack, game update, fix.
local L4D2_PAGE_HTML = [==[
<p><strong>1.1) Скачать игру Left 4 Dead 2 торрент</strong>&nbsp;(последняя версия)&nbsp;</p>
<!--QuoteBegin--><div class="quote"><!--QuoteEBegin--><p><a href="//freetp.org/getfile-13735" target="_blank" rel="noopener">Скачать Left_4_Dead_2_Repack_by_Pioneer_v2243 v03.12.2024.torrent</a><br>Размер: 7,82 Гб, всё необходимое уже встроено.</p><!--QuoteEnd--></div><!--QuoteEEnd-->
<p><strong>1.2) Скачать патч для Left 4 Dead 2 (обновление)</strong></p>
<!--QuoteBegin--><div class="quote"><!--QuoteEBegin--><p><a href="//freetp.org/getfile-13734" target="_blank" rel="noopener">Скачать Left_4_Dead_2_Update-v2220-2243.exe</a><br>(все в одном с версии 2220 до 2243)</p><!--QuoteEnd--></div><!--QuoteEEnd-->
<p><strong>1.3) Скачать онлайн фикс Left 4 Dead 2&nbsp;</strong></p>
<!--QuoteBegin--><div class="quote"><!--QuoteEBegin--><p><a href="//freetp.org/getfile-7732" target="_blank" rel="noopener">Скачать Left_4_Dead_2_Multiplayer Fix Online-v3</a><br>Устанавливать в папку с игрой.</p><!--QuoteEnd--></div><!--QuoteEEnd-->
]==]

-- A results page with more pages after it: the pager's "next" link (verbatim
-- shape, page 1 of "Raft", whose article is on page 2).
local function search_page(entries_html, next_page)
  local nav = next_page and ('<span class="page_next" title="Следующая страница">'
    .. '<a name="nextlink" id="nextlink" onclick="if (!window.__cfRLUnblockHandlers) return false; '
    .. 'javascript:list_submit(' .. next_page .. '); return(false)" href="#">Вперед</a></span>')
    or '<span class="page_next" title="Следующая страница"><span>Вперед</span></span>'
  return '<div class="search-results">' .. entries_html .. '</div><div class="navigation">' .. nav .. '</div>'
end
local RAFT_P1 = search_page(
  [[<h2><a href="https://freetp.org/po-seti/5456-super-raft-boat-together-igra-po-seti-besplatno-onlayn.html">Super Raft Boat Together играть по сети и интернету Онлайн</a></h2>]], 2)
local RAFT_P2 = search_page(
  [[<h2><a href="https://freetp.org/po-seti/2827-raft-igra-po-seti-besplatno-onlayn-v1103.html">Raft играть по сети и интернету Онлайн / ЛАН</a></h2>]], 3)
local REPO_P1 = search_page(
  [[<h2><a href="https://freetp.org/po-seti/6564-repo-igra-po-seti-i-internetu-onlayn.html">R.E.P.O. играть по сети и интернету Онлайн</a></h2>]], nil)

-- ── normalize / urlencode / entities ────────────────────────────────────────
check("normalize: cyrillic filler drops out",
  ft.normalize("CRACK играть по сети и интернету Онлайн") == "crack")
check("normalize: punctuation drops out",
  ft.normalize("FlatOut: Ultimate Carnage") == "flatoutultimatecarnage")
check("normalize: entity text decodes before matching",
  ft.normalize("Baldur&#39;s Gate &amp; Dark Alliance")
    == ft.normalize("Baldur's Gate: Dark Alliance"))
check("normalize: non-string -> empty", ft.normalize(nil) == "")
check("urlencode: spaces and reserved chars encode",
  ft.urlencode("Left 4 Dead 2") == "Left%204%20Dead%202"
    and ft.urlencode("A&B=C?") == "A%26B%3DC%3F")

-- ── parse_search ────────────────────────────────────────────────────────────
local entries = ft.parse_search(SEARCH_HTML)
check("search: one entry per unique article url", #entries == 5)
check("search: 'Подробнее' navigation anchors never steal a title",
  entries[1].url == "https://freetp.org/po-seti/7365-crack-po-seti-besplatno.html"
    and ft.normalize(entries[1].title) == "crack")
check("search: malformed body -> empty", #ft.parse_search(nil) == 0
  and #ft.parse_search("<div>no results</div>") == 0)

-- ── pick_article ────────────────────────────────────────────────────────────
check("pick: CRACK resolves to its own article, not The Crackpet Show",
  ft.pick_article(entries, "CRACK").url == "https://freetp.org/po-seti/7365-crack-po-seti-besplatno.html")
check("pick: The Crackpet Show resolves to its own article",
  ft.pick_article(entries, "The Crackpet Show").url
    == "https://freetp.org/po-seti/5013-the-crackpet-show-igra-po-seti-i-internetu-onlayn.html")
check("pick: multi-word name with digits",
  ft.pick_article(entries, "Left 4 Dead 2").url
    == "https://freetp.org/po-seti/15-left-4-dead-2-zapusk-po-internetu-i-seti-lan-online.html")
check("pick: unknown game -> nil", ft.pick_article(entries, "BeamNG") == nil)
check("pick: empty name -> nil", ft.pick_article(entries, "") == nil)

-- ── resolve (injected get, no real network) ─────────────────────────────────
local function search_then_page(page_html)
  return function(url)
    if url:find("do=search", 1, true) then
      return { status = 200, body = SEARCH_HTML }
    end
    return { status = 200, body = page_html }
  end
end

local r = ft.resolve("CRACK", search_then_page(CRACK_PAGE_HTML))
check("resolve: article found", r.errorCode == nil)
check("resolve: only the on-site attachment counts (ad, file-host comment skipped)",
  #r.files == 1 and r.files[1].url == "https://freetp.org/getfile-20665")

local r_noattach = ft.resolve("REANIMAL", search_then_page(DISCORD_ONLY_PAGE_HTML))
check("resolve: an article without attachments is found, with no files",
  r_noattach.errorCode == nil and #r_noattach.files == 0)

local r_down = ft.resolve("CRACK", function() return { status = 500, body = "" } end)
check("resolve: site down -> search_failed", r_down.errorCode == "search_failed")

local r_miss = ft.resolve("BeamNG", search_then_page(CRACK_PAGE_HTML))
check("resolve: game not covered -> no_page", r_miss.errorCode == "no_page")

local r_page_down = ft.resolve("CRACK", function(url)
  if url:find("do=search", 1, true) then
    return { status = 200, body = SEARCH_HTML }
  end
  return { status = 500, body = "" }
end)
check("resolve: article fetch failing is page_failed, not a missing fix",
  r_page_down.errorCode == "page_failed" and #r_page_down.files == 0)

check("resolve: empty name -> no_name", ft.resolve("", search_then_page("")).errorCode == "no_name")

-- ── resolve: later result pages and punctuation-free names ──────────────────
check("next page: read from the pager's next link, nil on the last page",
  ft.next_search_page(RAFT_P1) == 2 and ft.next_search_page(REPO_P1) == nil
    and ft.next_search_page(nil) == nil)
check("plain query: punctuation deleted, words kept",
  ft.plain_query("R.E.P.O.") == "REPO"
    and ft.plain_query("FlatOut: Ultimate Carnage") == "FlatOut Ultimate Carnage")

-- A fake DLE site: search pages by query and page number (search_start).
local function dle_site(pages_by_query, opts)
  opts = opts or {}
  local log = {}
  local get = function(url, o)
    log[#log + 1] = { url = url, opts = o }
    local story = url:match("[?&]story=([^&]*)")
    if story then
      local page = tonumber(url:match("[?&]search_start=(%d+)")) or 1
      if opts.fail_page == page then return { status = 503, body = "" } end
      local q = story:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
      local pages = pages_by_query[q] or {}
      local body = pages[page] or (opts.endless and search_page("", page + 1))
        or search_page("", nil)
      return { status = 200, body = body }
    end
    return { status = 200, body = GETFILE_PAGE_HTML }
  end
  return get, log
end

local raft_get, raft_log = dle_site({ Raft = { RAFT_P1, RAFT_P2 } })
local r_raft = ft.resolve("Raft", raft_get)
check("resolve: an article on the second results page is found",
  r_raft.errorCode == nil and #r_raft.files == 2
    and raft_log[2].url:find("search_start=2", 1, true) ~= nil
    and raft_log[3].url == "https://freetp.org/po-seti/2827-raft-igra-po-seti-besplatno-onlayn-v1103.html")

local repo_get, repo_log = dle_site({ REPO = { REPO_P1 } })
local r_repo = ft.resolve("R.E.P.O.", repo_get)
check("resolve: a punctuated name with no results is searched again without punctuation",
  r_repo.errorCode == nil and #r_repo.files == 2
    and repo_log[1].url:find("story=R.E.P.O.", 1, true) ~= nil
    and repo_log[2].url:find("story=REPO", 1, true) ~= nil)

local endless_get, endless_log = dle_site({}, { endless = true })
local r_endless = ft.resolve("Raft", endless_get)
check("resolve: an endless pager stops at MAX_SEARCH_REQUESTS -> no_page",
  r_endless.errorCode == "no_page" and #endless_log == ft.MAX_SEARCH_REQUESTS)

local now = 1000
local slow_get, slow_log = dle_site({}, { endless = true })
local r_slow = ft.resolve("Raft", function(url, o)
  now = now + 6
  return slow_get(url, o)
end, function() return now end)
check("resolve: search requests stop once SEARCH_BUDGET has passed, timeouts clamped to what is left",
  r_slow.errorCode == "no_page"
    and #slow_log == math.ceil(ft.SEARCH_BUDGET / 6) and #slow_log < ft.MAX_SEARCH_REQUESTS
    and slow_log[#slow_log].opts.timeout <= ft.SEARCH_BUDGET - 6 * (#slow_log - 1))

local flaky_get = dle_site({ Raft = { RAFT_P1, RAFT_P2 } }, { fail_page = 2 })
check("resolve: a results page that fails to load is search_failed, not a missing fix",
  ft.resolve("Raft", flaky_get).errorCode == "search_failed")

local every_get_capped = true
for _, c in ipairs(raft_log) do
  if type(c.opts) ~= "table" or not c.opts.timeout or not c.opts.max_bytes then every_get_capped = false end
end
check("resolve: every search and article request has a timeout and max_bytes", every_get_capped)

-- ── on-site getfile attachments (the auto-download chain) ────────────────────
local files = ft.parse_article_files(GETFILE_PAGE_HTML)
check("files: both getfile attachments parsed", #files == 2
  and files[1].id == "20665" and files[2].id == "20797")
check("files: url reconstructed, label trimmed",
  files[1].url == "https://freetp.org/getfile-20665"
    and files[1].label == "Скачать CRACK Simulator Multiplayer Fix Online.exe")
check("files: malformed -> empty", #ft.parse_article_files(nil) == 0
  and #ft.parse_article_files("no attachments") == 0)

local pick = ft.pick_fix_file(files)
check("pick: the .exe setup wins over the repack torrent",
  pick ~= nil and pick.id == "20665" and pick.ext == "exe" and pick.magic == "MZ")
check("pick: torrent-only article -> nil",
  ft.pick_fix_file({ { id = "1", label = "Скачать CRACK by Pioneer.torrent" } }) == nil)
check("pick: no files -> nil", ft.pick_fix_file(nil) == nil)
check("pick: archive labels are installable too",
  ft.pick_fix_file({ { id = "2", label = "Скачать fix.zip" } }).ext == "zip")
check("pick: the last extension decides (fix.exe.rar is a rar)",
  ft.pick_fix_file({ { id = "3", label = "Скачать fix.exe.rar" } }).magic == "Rar!")
-- How to Fish (2026-11-08): the fix's label carries no file name at all.
local htf_files = {
  { id = "20386", label = "Скачать How to Fish v1.1.3 Portable.torrent" },
  { id = "20149", label = "Скачать How to Fish-Multiplayer-Fix-Online-v1.5" },
}
local htf_pick = ft.pick_fix_file(htf_files)
check("pick: a label without a file name is the fallback, decided by signature",
  htf_pick ~= nil and htf_pick.id == "20149" and htf_pick.ext == nil and htf_pick.magic == nil)
-- Left 4 Dead 2 (2026-11-08): the repack torrent, a game update setup with a
-- file name, and the fix whose label has none, in page order.
local l4d2_files = ft.parse_article_files(L4D2_PAGE_HTML)
local l4d2_pick = ft.pick_fix_file(l4d2_files)
check("pick: the fix beats a game update setup that has a file extension",
  #l4d2_files == 3 and l4d2_pick ~= nil and l4d2_pick.id == "7732" and l4d2_pick.ext == nil)
check("pick: an article with only a repack and a game update has no fix",
  ft.pick_fix_file({ l4d2_files[1], l4d2_files[2] }) == nil)
check("pick: a hotfix is a game update, not the fix",
  ft.pick_fix_file({ { id = "1", label = "Скачать Game_Hotfix_v1.2.exe" },
    { id = "2", label = "Скачать Game Online.exe" } }).id == "2")
check("pick: a fix label that also mentions a patch is still the fix",
  ft.pick_fix_file({ { id = "1", label = "Скачать Game_Patch_v1.2.exe" },
    { id = "2", label = "Скачать Game Multiplayer Fix + patch v1.2.zip" } }).id == "2")
check("pick: a camel-cased OnlineFix label counts as a fix",
  ft.pick_fix_file({ { id = "1", label = "Скачать Game.exe" },
    { id = "2", label = "Скачать Game OnlineFix" } }).id == "2")
check("pick: a plain fix ranks above a fix bundled with a game update",
  ft.pick_fix_file({ { id = "1", label = "Скачать Game_Update_v2_Fix.exe" },
    { id = "2", label = "Скачать Game Multiplayer Fix Online.exe" } }).id == "2")

-- ── download job (injected get: search -> article -> file) ──────────────────
-- The file fetch is a background transfer (start/poll); here the injected get
-- answers it, complete on the first poll.
local function as_job(deps)
  deps.start = deps.start or function(url, opts) return { url = url, opts = opts } end
  deps.poll = deps.poll or function(h) return true, deps.get(h.url, h.opts) end
  return deps
end
local function download_fix(appid, name, deps)
  deps = as_job(deps)
  return ft.poll_download(ft.start_download(appid, name, deps), deps)
end
local function fake_chain(pages)
  local calls = {}
  local get = function(url, opts)
    calls[#calls + 1] = { url = url, opts = opts }
    if url:find("do=search", 1, true) then return { status = 200, body = SEARCH_HTML } end
    if url:find("/po%-seti/", 1) then return { status = 200, body = pages.article } end
    return pages.download or { status = 200, body = "MZ" .. string.rep("X", 100) }
  end
  return get, calls
end
local written = {}
local get_ok, calls = fake_chain({ article = GETFILE_PAGE_HTML })
local dl = download_fix(4312190, "CRACK", {
  get = get_ok,
  mkdir = function() return true end,
  dl_dir = "/tmp/ftdl",
  write_file = function(p, data)
    written[#written + 1] = { path = p, size = #data }
    return true
  end,
})
check("download: full chain succeeds", dl.success == true
  and dl.path == "/tmp/ftdl/4312190-freetp-fix.exe"
  and #written == 1 and written[1].size == 102)
check("download: the attachment page is sent as Referer",
  #calls == 3 and calls[3].url == "https://freetp.org/index.php?do=download&id=20665"
    and type(calls[3].opts) == "table"
    and calls[3].opts.headers.Referer == "https://freetp.org/getfile-20665")
check("download: the file fetch gets minutes, not the blocking request cap, and a size cap",
  calls[3].opts.timeout == ft.DOWNLOAD_TIMEOUT and ft.DOWNLOAD_TIMEOUT > 30
    and calls[3].opts.max_bytes == ft.MAX_FIX_BYTES)

local dl_noexe = download_fix(4312190, "CRACK", {
  get = (fake_chain({ article = DISCORD_ONLY_PAGE_HTML })),
  dl_dir = "/tmp/ftdl",
  mkdir = function() return true end,
  write_file = function() return true end,
})
check("download: article without an on-site fix -> no_fix_file",
  dl_noexe.success == false and dl_noexe.errorCode == "no_fix_file")

local dl_html = download_fix(4312190, "CRACK", {
  get = (fake_chain({ article = GETFILE_PAGE_HTML,
    download = { status = 200, body = "<html>not a file</html>" } })),
  dl_dir = "/tmp/ftdl",
  mkdir = function() return true end,
  write_file = function() return true end,
})
check("download: a non-file body is refused (wrong_content)",
  dl_html.success == false and dl_html.errorCode == "wrong_content")

local HTF_SEARCH = [==[<h2><a href="https://freetp.org/po-seti/7275-how-to-fish-po-seti-i-internetu-onlayn.html">How to Fish играть по сети и интернету Онлайн</a></h2>]==]
local HTF_PAGE = [==[<p><a href="//freetp.org/getfile-20386">Скачать How to Fish v1.1.3 Portable.torrent</a></p>
<p><a href="//freetp.org/getfile-20149">Скачать How to Fish-Multiplayer-Fix-Online-v1.5</a></p>]==]
local function htf_get(body)
  return function(url)
    if url:find("do=search", 1, true) then return { status = 200, body = HTF_SEARCH } end
    if url:find("/po%-seti/") then return { status = 200, body = HTF_PAGE } end
    return { status = 200, body = body }
  end
end
local htf_paths = {}
local dl_htf = download_fix(4001890, "How to Fish", {
  get = htf_get("MZ" .. string.rep("X", 50)), dl_dir = "/tmp/ftdl",
  mkdir = function() return true end,
  write_file = function(p) htf_paths[#htf_paths + 1] = p; return true end,
})
check("download: unlabelled fix typed by its signature (exe)",
  dl_htf.success == true and htf_paths[1] == "/tmp/ftdl/4001890-freetp-fix.exe")
local dl_htf_txt = download_fix(4001890, "How to Fish", {
  get = htf_get("just a readme"), dl_dir = "/tmp/ftdl",
  mkdir = function() return true end, write_file = function() return true end,
})
check("download: unlabelled non-installable body refused",
  dl_htf_txt.success == false and dl_htf_txt.errorCode == "wrong_content")

local dl_down = download_fix(4312190, "CRACK", {
  get = (fake_chain({ article = GETFILE_PAGE_HTML,
    download = { status = 404, body = "" } })),
  dl_dir = "/tmp/ftdl",
  mkdir = function() return true end,
  write_file = function() return true end,
})
check("download: a failed fetch -> download_failed",
  dl_down.success == false and dl_down.errorCode == "download_failed")

local dl_page_down = download_fix(4312190, "CRACK", {
  get = function(url)
    if url:find("do=search", 1, true) then return { status = 200, body = SEARCH_HTML } end
    return { status = 503, body = "" }
  end,
  dl_dir = "/tmp/ftdl", mkdir = function() return true end,
  write_file = function() return true end, remove_file = function() end,
})
check("download: an unreadable article reports page_failed, not no_fix_file",
  dl_page_down.success == false and dl_page_down.errorCode == "page_failed")

-- A failed download leaves no file of the game in the download dir: neither
-- the one an earlier download stored nor one written only in part.
do
  local dir = "/tmp/lumen_freetp_test_dl"
  os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")
  local function dir_listing()
    local p = io.popen("ls -A '" .. dir .. "'")
    local out = p:read("*a")
    p:close()
    return out
  end
  local stored = download_fix(4312190, "CRACK", {
    get = (fake_chain({ article = GETFILE_PAGE_HTML })), dl_dir = dir })
  local f = io.open(dir .. "/4312190-freetp-fix.exe", "rb")
  local body = f and f:read("*a")
  if f then f:close() end
  check("download: the file is stored whole in the download dir",
    stored.success == true and body == "MZ" .. string.rep("X", 100))
  local wrong = download_fix(4312190, "CRACK", {
    get = (fake_chain({ article = GETFILE_PAGE_HTML,
      download = { status = 200, body = "<html>not a file</html>" } })),
    dl_dir = dir })
  check("download: a wrong_content download leaves no file of the game behind",
    wrong.errorCode == "wrong_content" and dir_listing() == "")
  local partial = download_fix(4312190, "CRACK", {
    get = (fake_chain({ article = GETFILE_PAGE_HTML })), dl_dir = dir,
    write_file = function(p, data)
      local out = io.open(p, "wb")
      out:write(data:sub(1, 10))
      out:close()
      return false
    end })
  check("download: a file that could not be written in full is deleted",
    partial.errorCode == "write_failed" and dir_listing() == "")
  os.execute("rm -rf '" .. dir .. "'")
end

-- ── register (RPC shape, table form, injected effects) ─────────────────────
local json = require("json")
local reg = {}
ft.register(reg, as_job({ get = search_then_page(CRACK_PAGE_HTML),
  dl_dir = "/tmp/ftdl", mkdir = function() return true end,
  write_file = function() return true end, remove_file = function() end }))
check("register: exposes LumenDownloadFreeTPFix and LumenDiscardFreeTPDownload",
  type(reg.LumenDownloadFreeTPFix) == "function"
    and type(reg.LumenDiscardFreeTPDownload) == "function")
-- The bridge passes {appid, contentScriptQuery, gameName} alphabetically as
-- positional args; the table form is tolerated too.
-- The injected server answers the file request with the article HTML, so the
-- download fails after the article was found.
local dec_pos = json.decode(reg.LumenDownloadFreeTPFix(4312190, "", "CRACK"))
check("register: positional form", dec_pos.success == false and dec_pos.errorCode == "wrong_content")
local dec_tbl = json.decode(reg.LumenDownloadFreeTPFix({ appid = 4312190, gameName = "CRACK" }))
check("register: table form", dec_tbl.success == false and dec_tbl.errorCode == "wrong_content")
local dec_odd = json.decode(reg.LumenDownloadFreeTPFix({ appid = "bad", gameName = {} }))
check("register: odd input answers invalid_appid instead of crashing",
  dec_odd.success == false and dec_odd.errorCode == "invalid_appid")

-- The file transfer outlives one RPC: each call advances it until it is done.
do
  local polls, starts, stored, removed = 0, 0, {}, {}
  local arrived = false
  -- The fake timer only moves while the job sleeps between polls.
  local clock_now, timer_now, slept = 0, 0, 0
  local preg = {}
  local deps = {
    get = (fake_chain({ article = GETFILE_PAGE_HTML })),
    start = function(url, opts) starts = starts + 1; return { url = url, opts = opts } end,
    poll = function(h)
      polls = polls + 1
      if not arrived then return false end
      return true, { status = 200, body = "MZ" .. string.rep("X", 10) }
    end,
    now = function() return timer_now end,
    sleep = function(s) slept = slept + s; timer_now = timer_now + s end,
    clock = function() return clock_now end,
    dl_dir = "/tmp/ftdl", mkdir = function() return true end,
    write_file = function(p) stored[#stored + 1] = p; return true end,
    remove_file = function(p) removed[#removed + 1] = p end,
  }
  ft.register(preg, deps)
  local first = json.decode(preg.LumenDownloadFreeTPFix(4312190, "", "CRACK"))
  local first_polls, first_slept = polls, slept
  local second = json.decode(preg.LumenDownloadFreeTPFix(4312190, "", "CRACK"))
  arrived = true
  local third = json.decode(preg.LumenDownloadFreeTPFix(4312190, "", "CRACK"))
  check("register: the download answers pending until the transfer is done, then the file",
    first.pending == true and second.pending == true and third.pending == nil
      and third.success == true and third.path == "/tmp/ftdl/4312190-freetp-fix.exe"
      and starts == 1 and #stored == 1)
  check("register: one call keeps polling the transfer, for no longer than POLL_BUDGET",
    first_polls > 1 and first_slept > 0 and first_slept <= ft.POLL_BUDGET
      and polls - first_polls > first_polls)

  arrived = false
  json.decode(preg.LumenDownloadFreeTPFix(4312190, "", "CRACK"))
  clock_now = 100
  json.decode(preg.LumenDownloadFreeTPFix(4312190, "", "CRACK"))
  check("register: a download nobody polled for a while starts over", starts == 3)

  local disc = json.decode(preg.LumenDiscardFreeTPDownload(4312190, ""))
  local found = false
  for _, p in ipairs(removed) do
    if p == "/tmp/ftdl/4312190-freetp-fix.exe" then found = true end
  end
  check("register: discard deletes the stored download (positional form)", disc.success == true and found)
  json.decode(preg.LumenDownloadFreeTPFix(4312190, "", "CRACK"))
  check("register: discard drops the running job too", starts == 4)
end

-- A transfer that ends in an error fails the download and discards the file.
do
  local function failed_poll(name, poll)
    local removed = {}
    local deps = {
      get = (fake_chain({ article = GETFILE_PAGE_HTML })),
      start = function(url, opts) return { url = url, opts = opts } end,
      poll = poll,
      now = function() return 0 end, sleep = function() end,
      dl_dir = "/tmp/ftdl", mkdir = function() return true end,
      write_file = function() error("nothing is written for a failed transfer") end,
      remove_file = function(p) removed[#removed + 1] = p end,
    }
    local res = ft.poll_download(ft.start_download(4312190, "CRACK", deps), deps)
    local discarded = false
    for _, p in ipairs(removed) do
      if p == "/tmp/ftdl/4312190-freetp-fix.exe" then discarded = true end
    end
    check("download: " .. name .. " -> download_failed, and the file is discarded",
      res ~= nil and res.success == false and res.errorCode == "download_failed" and discarded)
  end
  failed_poll("a poll that throws", function() error("transfer crashed") end)
  failed_poll("a poll answering true, nil, err", function() return true, nil, "connection reset" end)
  failed_poll("a poll answering nil, err", function() return nil, "connection reset" end)
end

-- A wall clock that steps back cannot stretch one call past its poll budget.
do
  local polls, t = 0, 1000
  local deps = {
    get = (fake_chain({ article = GETFILE_PAGE_HTML })),
    start = function(url, opts) return { url = url, opts = opts } end,
    -- An unbounded loop ends in an error here instead of hanging the suite.
    poll = function()
      polls = polls + 1
      if polls > 10000 then error("runaway poll loop") end
      return false
    end,
    now = function() t = t - 1; return t end,
    sleep = function() end,
    dl_dir = "/tmp/ftdl", mkdir = function() return true end,
    write_file = function() return true end, remove_file = function() end,
  }
  local res = ft.poll_download(ft.start_download(4312190, "CRACK", deps), deps)
  check("download: a clock stepping back still ends the call after a bounded number of polls",
    res == nil and polls == math.ceil(ft.POLL_BUDGET / ft.POLL_INTERVAL) + 1)
end

-- ── parse_page_updated / fix_revision (freshness decoration) ───────────────
local UPD_BLOCK = '<div class="game-card__update game-page__update">'
  .. ' <span class="game-card__update-track"> <span>3-12-2024, 18:38</span>'
  .. ' <b>новый клиент и патч</b> </span> </div>'
local upd = ft.parse_page_updated(UPD_BLOCK)
check("updated: marker parsed with note", upd ~= nil and upd.text == "3-12-2024, 18:38"
  and upd.note == "новый клиент и патч")
check("updated: epoch is the stated day",
  upd ~= nil and os.date("%Y-%m-%d", upd.epoch) == "2024-12-03")
check("updated: no marker -> nil", ft.parse_page_updated("<p>none</p>") == nil
  and ft.parse_page_updated(nil) == nil)

check("revision: fix label's Online-v3 -> 3",
  ft.fix_revision("Скачать Left_4_Dead_2_Multiplayer Fix Online-v3") == "3")
check("revision: dotted revision", ft.fix_revision("How to Fish-Multiplayer-Fix-Online-v1.5") == "1.5")
check("revision: an extension's dot is not part of the version",
  ft.fix_revision("Скачать CRACK Simulator Multiplayer Fix Online-v2.exe") == "2")
check("revision: repack/update versions are not fix revisions",
  ft.fix_revision("Скачать Left_4_Dead_2_Repack_by_Pioneer_v2243 v03.12.2024.torrent") == nil
  and ft.fix_revision("Скачать Left_4_Dead_2_Update-v2220-2243.exe") == nil)
check("revision: non-string -> nil", ft.fix_revision(nil) == nil)

check("resolve: a page without the marker carries no updated field",
  r.updated == nil and r.updatedNote == nil)
local r_upd = ft.resolve("CRACK", search_then_page(CRACK_PAGE_HTML .. UPD_BLOCK))
check("resolve: the page's update marker rides along at no extra cost",
  r_upd.errorCode == nil and r_upd.updated ~= nil
  and os.date("%Y-%m-%d", r_upd.updated) == "2024-12-03"
  and r_upd.updatedNote == "новый клиент и патч")

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
