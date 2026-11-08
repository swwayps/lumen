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
check("pick: a labelled installable still beats the unlabelled fallback",
  ft.pick_fix_file({ htf_files[2], { id = "5", label = "Скачать fix.zip" } }).id == "5")

-- ── download_fix (injected get: search -> article -> file) ──────────────────
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
local dl = ft.download_fix(4312190, "CRACK", {
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

local dl_noexe = ft.download_fix(4312190, "CRACK", {
  get = (fake_chain({ article = DISCORD_ONLY_PAGE_HTML })),
  dl_dir = "/tmp/ftdl",
  mkdir = function() return true end,
  write_file = function() return true end,
})
check("download: article without an on-site fix -> no_fix_file",
  dl_noexe.success == false and dl_noexe.errorCode == "no_fix_file")

local dl_html = ft.download_fix(4312190, "CRACK", {
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
local dl_htf = ft.download_fix(4001890, "How to Fish", {
  get = htf_get("MZ" .. string.rep("X", 50)), dl_dir = "/tmp/ftdl",
  mkdir = function() return true end,
  write_file = function(p) htf_paths[#htf_paths + 1] = p; return true end,
})
check("download: unlabelled fix typed by its signature (exe)",
  dl_htf.success == true and htf_paths[1] == "/tmp/ftdl/4001890-freetp-fix.exe")
local dl_htf_txt = ft.download_fix(4001890, "How to Fish", {
  get = htf_get("just a readme"), dl_dir = "/tmp/ftdl",
  mkdir = function() return true end, write_file = function() return true end,
})
check("download: unlabelled non-installable body refused",
  dl_htf_txt.success == false and dl_htf_txt.errorCode == "wrong_content")

local dl_down = ft.download_fix(4312190, "CRACK", {
  get = (fake_chain({ article = GETFILE_PAGE_HTML,
    download = { status = 404, body = "" } })),
  dl_dir = "/tmp/ftdl",
  mkdir = function() return true end,
  write_file = function() return true end,
})
check("download: a failed fetch -> download_failed",
  dl_down.success == false and dl_down.errorCode == "download_failed")

local dl_page_down = ft.download_fix(4312190, "CRACK", {
  get = function(url)
    if url:find("do=search", 1, true) then return { status = 200, body = SEARCH_HTML } end
    return { status = 503, body = "" }
  end })
check("download: an unreadable article reports page_failed, not no_fix_file",
  dl_page_down.success == false and dl_page_down.errorCode == "page_failed")

-- ── register (RPC shape, table form, injected effects) ─────────────────────
local json = require("json")
local reg = {}
ft.register(reg, { get = search_then_page(CRACK_PAGE_HTML) })
check("register: exposes LumenDownloadFreeTPFix",
  type(reg.LumenDownloadFreeTPFix) == "function")
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

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
