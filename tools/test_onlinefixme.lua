-- Host tests for onlinefixme.lua: the Online Fix tile's online-fix.me path —
-- search/article parsing with REAL page shapes, the Fix Repair pick out of
-- real `aria2c -S` output, and start()/status() with injected effects (no
-- network, no aria2c).
-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_onlinefixme.lua
package.path = "lua/?.lua;" .. package.path

local of = require("onlinefixme")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.write("FAIL: " .. name .. "\n") end
end

-- ── fixtures (verbatim shapes from online-fix.me, 2026-11-08) ───────────────
-- Searching "Lethal Company" lists Terrorbytes FIRST.
local SEARCH_HTML = [==[
<a class="big-link" href="https://online-fix.me/games/horror/17689-terrorbytes-po-seti.html"></a>
<a href="https://online-fix.me/games/horror/17689-terrorbytes-po-seti.html"><h2 class="title">
Terrorbytes по сети
</h2></a>
<a class="big-link" href="https://online-fix.me/games/survival/17365-lethal-company-po-seti.html"></a>
<a href="https://online-fix.me/games/survival/17365-lethal-company-po-seti.html"><h2 class="title">
Lethal Company по сети
</h2></a>
]==]
local ARTICLE_HTML = [==[
<a href="https://uploads.online-fix.me:2053/torrents/Lethal%20Company/" class="btn">Torrent</a>
<a href="https://uploads.online-fix.me:2053/uploads/Lethal%20Company/" class="btn">Server</a>
]==]
local DIR_HTML = [==[<a href="../">../</a>
<a href="Lethal.Company.v81-OFME.torrent">Lethal.Company.v81-OFME.torrent</a>]==]
-- `aria2c -S` lists the full game first for some games, the fix first for others.
local LISTING_GAME_FIRST = [==[
idx|path/length
===+===========================================================================
  1|./Lethal Company/Lethal.Company.v81-OFME.rar
   |902MiB (946,700,000)
---+---------------------------------------------------------------------------
  2|./Lethal Company/Fix Repair/LethalCompany_Fix_Repair_Steam_Generic.rar
   |11MiB (11,300,000)
---+---------------------------------------------------------------------------
]==]
local LISTING_NO_FIX = [==[
  1|./Some Game/Some.Game.v1-OFME.rar
   |4GiB (4,500,000,000)
]==]

-- ── parsers ───────────────────────────────────────────────────────────────
local entries = of.parse_search(SEARCH_HTML)
check("search: both result titles parsed", #entries == 2
  and entries[2].url == "https://online-fix.me/games/survival/17365-lethal-company-po-seti.html")
check("search: the exact game wins, not the first hit",
  require("freetp").pick_article(entries, "Lethal Company").url == entries[2].url)
check("search: malformed -> empty", #of.parse_search(nil) == 0)
check("article: torrent folder found",
  of.torrent_dir(ARTICLE_HTML) == "https://uploads.online-fix.me:2053/torrents/Lethal%20Company/")
check("article: none -> nil", of.torrent_dir("<p>no links</p>") == nil)

local idx, path = of.pick_fix_index(LISTING_GAME_FIRST)
check("pick: the Fix Repair archive, never the full-game -OFME.rar",
  idx == 2 and path == "Lethal Company/Fix Repair/LethalCompany_Fix_Repair_Steam_Generic.rar")
check("pick: a torrent without a Fix Repair file -> nil", of.pick_fix_index(LISTING_NO_FIX) == nil)

-- ── start / status (injected effects) ─────────────────────────────────────
local function fake(state)
  local files, cmds = state.files or {}, {}
  return {
    dl_root = "/dl",
    get = function(url)
      if url:find("do=search", 1, true) then return { status = 200, body = SEARCH_HTML } end
      if url:find("/games/", 1, true) then return { status = 200, body = ARTICLE_HTML } end
      if url:sub(-1) == "/" then return { status = 200, body = DIR_HTML } end
      return { status = 200, body = state.torrent or "d8:announce..." }
    end,
    execute = function(cmd) cmds[#cmds + 1] = cmd; return true end,
    read_pipe = function(cmd)
      if cmd:find("command -v aria2c", 1, true) then return state.no_aria2 and "" or "/usr/bin/aria2c\n" end
      if cmd:find(" -S ", 1, true) then return state.listing or LISTING_GAME_FIRST end
      if cmd:find("pgrep", 1, true) then return state.running and "4242\n" or "" end
      if cmd:find("stat -c", 1, true) then return state.size or "" end
      return ""
    end,
    read_file = function(p) return files[p] end,
    write_file = function(p, d) files[p] = d; return true end,
  }, cmds, files
end

local deps, cmds, files = fake({})
local s = of.start(1966720, "Lethal Company", deps)
local bg = cmds[#cmds] or ""
check("start: runs aria2c in the background on the Fix Repair index only",
  s.success == true and bg:find("--select-file=2", 1, true) ~= nil
    and bg:find("--seed-time=0", 1, true) ~= nil and bg:sub(-1) == "&")
check("start: target recorded for status()",
  files["/dl/1966720/target"] == "/dl/1966720/Lethal Company/Fix Repair/LethalCompany_Fix_Repair_Steam_Generic.rar")

check("start: no aria2c -> no_aria2", of.start(1, "Lethal Company", (fake({ no_aria2 = true }))).reason == "no_aria2")
check("start: game not on the site -> no_page", of.start(1, "Zzqx", (fake({}))).reason == "no_page")
check("start: torrent without a Fix Repair file -> no_fix_file",
  of.start(1, "Lethal Company", (fake({ listing = LISTING_NO_FIX }))).reason == "no_fix_file")
check("start: a non-torrent body -> no_torrent",
  of.start(1, "Lethal Company", (fake({ torrent = "<html>401</html>" }))).reason == "no_torrent")

local T = "/dl/7/Game/Fix Repair/x.rar"
local running, rcmds = fake({ running = true, files = { ["/dl/7/target"] = T } })
local again = of.start(7, "Lethal Company", running)
check("start: a running download is reused, not restarted",
  again.success == true and again.path == T and #rcmds == 0)

local finished, fcmds = fake({ size = "11300000\n",
  files = { ["/dl/7/target"] = T, ["/dl/7/exit"] = "0\n" } })
check("start: a finished download is reused, not fetched again",
  of.start(7, "Lethal Company", finished).path == T and #fcmds == 0)
local cdeps, ccmds = fake({})
of.cancel(7, cdeps)
check("cancel: kills only this appid's aria2c job",
  ccmds[1] == "pkill -f -- '[a]ria2c .*/dl/7/fix.torrent'")

check("status: nothing started -> idle", of.status(9, (fake({}))).state == "idle")
check("status: aria2c alive -> downloading",
  of.status(7, (fake({ running = true, size = "1048576\n", files = { ["/dl/7/target"] = T } }))).bytes == 1048576)
check("status: exit 0 with the file -> done",
  of.status(7, (fake({ size = "11300000\n", files = { ["/dl/7/target"] = T, ["/dl/7/exit"] = "0\n" } }))).state == "done")
check("status: non-zero exit -> failed",
  of.status(7, (fake({ size = "0\n", files = { ["/dl/7/target"] = T, ["/dl/7/exit"] = "7\n" } }))).state == "failed")
check("status: aria2c gone without an exit code -> failed",
  of.status(7, (fake({ files = { ["/dl/7/target"] = T } }))).state == "failed")

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
