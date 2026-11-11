-- Host tests for fixfresh.lua: the "which source has the newer fix" lookup —
-- day-granularity comparison, both source fetchers with an injected two-site
-- get (no real http), failure isolation, and the session cache.
-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_fixfresh.lua
package.path = "lua/?.lua;" .. package.path

local ff = require("fixfresh")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.write("FAIL: " .. name .. "\n") end
end

local function day(y, m, d) return os.time({ year = y, month = m, day = d, hour = 12 }) end

-- ── compare ─────────────────────────────────────────────────────────────────
check("compare: ofme newer", ff.compare(day(2026, 11, 4), day(2024, 12, 3)) == "ofme")
check("compare: freetp newer", ff.compare(day(2024, 12, 3), day(2026, 11, 4)) == "freetp")
check("compare: same day -> equal", ff.compare(day(2026, 11, 4), day(2026, 11, 4)) == "equal")
check("compare: a missing side -> unknown", ff.compare(nil, day(2026, 11, 4)) == "unknown"
  and ff.compare(day(2026, 11, 4), nil) == "unknown" and ff.compare(nil, nil) == "unknown")

-- ── fixtures (verbatim shapes; see test_onlinefixme/test_freetp) ─────────────
local OFME_SEARCH = [==[<a href="https://online-fix.me/games/adventures/18293-crack-po-seti.html"><h2 class="title">
CRACK по сети
</h2></a>]==]
local OFME_ARTICLE = [==[<a href="https://uploads.online-fix.me:2053/torrents/CRACK/" class="btn">Torrent</a>]==]
local OFME_LISTING = [==[<a href="../">../</a>
<a href="CRACK.v1.1.29-OFME.torrent">CRACK.v1.1.29-OFME.torrent</a>                         04-Nov-2026 15:04     37K
]==]
local FREETP_SEARCH = [==[<div class="search-results">
<h2><a href="https://freetp.org/po-seti/7365-crack-po-seti-besplatno.html">CRACK играть по сети и интернету Онлайн</a></h2>
</div>]==]
local FREETP_ARTICLE = [==[<div class="game-card__update game-page__update"> <span class="game-card__update-track"> <span>3-12-2024, 18:38</span> <b>новый клиент и патч</b> </span> </div>
<p><a href="//freetp.org/getfile-20665" target="_blank">Скачать CRACK Simulator Multiplayer Fix Online-v2.exe</a></p>]==]

local function two_site_get(log)
  return function(url)
    log[#log + 1] = url
    if url:find("online%-fix%.me/index.php") then return { status = 200, body = OFME_SEARCH } end
    if url:find("online%-fix%.me/games/") then return { status = 200, body = OFME_ARTICLE } end
    if url:find("uploads%.online%-fix%.me") then return { status = 200, body = OFME_LISTING } end
    if url:find("freetp%.org/index.php") then return { status = 200, body = FREETP_SEARCH } end
    if url:find("freetp%.org/po%-seti/") then return { status = 200, body = FREETP_ARTICLE } end
    return { status = 404, body = "" }
  end
end

-- ── get: both sides, verdict, cache ─────────────────────────────────────────
ff._reset()
local log = {}
local res = ff.get(4312190, "CRACK", { get = two_site_get(log), clock = function() return 100000 end })
check("get: success with both sides", res.success == true and res.ofme ~= nil and res.freetp ~= nil)
check("get: ofme carries version + display date",
  res.ofme.version == "1.1.29" and res.ofme.dateText == "04.11.2026")
check("get: freetp carries fix revision + display date",
  res.freetp.revision == "2" and res.freetp.dateText == "03.12.2024")
check("get: the newer source is named", res.newer == "ofme")
check("get: a fresh answer is not flagged cached", res.cached == nil)
local hits = #log
local res2 = ff.get(4312190, "CRACK", { get = two_site_get(log), clock = function() return 100000 + 60 end })
check("get: cache serves within TTL without new requests",
  res2.cached == true and #log == hits and res2.newer == "ofme")

-- ── get: failure isolation ──────────────────────────────────────────────────
ff._reset()
local only_freetp = ff.get(1, "CRACK", { get = function(url)
  if url:find("freetp.org", 1, true) then
    if url:find("index.php", 1, true) then return { status = 200, body = FREETP_SEARCH } end
    return { status = 200, body = FREETP_ARTICLE }
  end
  return { status = 500, body = "" }
end })
check("get: ofme down drops only its side, verdict honest",
  only_freetp.success == true and only_freetp.ofme == nil
  and only_freetp.freetp ~= nil and only_freetp.newer == "unknown")
ff._reset()
local none = ff.get(2, "CRACK", { get = function() return { status = 500, body = "" } end })
check("get: both down -> success with no sides, unknown",
  none.success == true and none.ofme == nil and none.freetp == nil and none.newer == "unknown")
check("get: empty name -> no_name",
  ff.get(3, "", { get = function() end }).errorCode == "no_name")
check("get: bad appid -> no_name",
  ff.get("nan", "CRACK", { get = function() end }).errorCode == "no_name")

-- ── get: cache expiry ───────────────────────────────────────────────────────
ff._reset()
local t, l3 = 300000, {}
local clk = function() return t end
ff.get(4, "CRACK", { get = two_site_get(l3), clock = clk })
t = t + ff.CACHE_TTL + 1
ff.get(4, "CRACK", { get = two_site_get(l3), clock = clk })
check("get: an expired cache refetches (3 ofme + 2 freetp requests per pass)", #l3 == 10)

-- ── register ────────────────────────────────────────────────────────────────
ff._reset()
local reg = ff.register({}, { get = two_site_get({}), clock = function() return 400000 end })
local out = reg.LumenGetFixFreshness({ appid = 4312190, gameName = "CRACK" })
check("register: table form encodes the verdict",
  type(out) == "string" and out:find('"newer":"ofme"', 1, true) ~= nil)
ff._reset()
local out2 = reg.LumenGetFixFreshness(4312190, "", "CRACK")
check("register: positional bridge args work too",
  type(out2) == "string" and out2:find('"success":true', 1, true) ~= nil)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
