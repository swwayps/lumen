-- fixfresh.lua — "which source has the newer fix" for the Fixes Menu tiles.
--
-- online-fix.me stamps every game's torrent with the game build it targets
-- ("CRACK.v1.1.29-OFME.torrent") and the uploads server's autoindex shows the
-- upload time; freetp.org's game pages carry a "last update" marker
-- (game-card__update-track) and the fix attachment's label carries the fix
-- revision ("…Multiplayer Fix Online-v3"). get() looks both up (a handful of
-- small requests with tight timeouts, cached per appid for the session) and
-- compares the two dates at day granularity: cross-source version NUMBERS are
-- not comparable (a game build vs a fix revision), dates are.
--
-- Pure parts (compare) and fetchers with injected get/clock are unit-tested
-- in tools/test_fixfresh.lua; the network is never touched there.

local ofme = require("onlinefixme")
local freetp = require("freetp")

local fixfresh = {}

-- Session cache: the menu re-opens far more often than the sites re-stamp,
-- and every lookup is a few blocking requests on the single-threaded loop.
fixfresh.CACHE_TTL = 6 * 3600
local cache = {} -- appid -> { at = epoch, result = table }

-- compare(ofme_epoch, freetp_epoch) -> "ofme" | "freetp" | "equal" |
-- "unknown". Same local calendar day reads "equal" — finer precision would
-- pretend the two sites' clocks agree. PURE.
function fixfresh.compare(a, b)
  if type(a) ~= "number" or type(b) ~= "number" then return "unknown" end
  local ka, kb = os.date("%Y-%m-%d", a), os.date("%Y-%m-%d", b)
  if ka == kb then return "equal" end
  return ka > kb and "ofme" or "freetp"
end

-- fetch_ofme(game_name, get) -> { name, version?, epoch? } or nil, reason.
-- Three small GETs (search, article, folder), 3 s caps; the .torrent itself
-- is never fetched — the folder line already names and dates it.
function fixfresh.fetch_ofme(game_name, get)
  local function fetch(url)
    local ok, r = pcall(get, url, { timeout = 3 })
    if ok and type(r) == "table" and r.status == 200 and type(r.body) == "string" then
      return r.body
    end
  end
  local article = freetp.pick_article(
    ofme.parse_search(fetch(ofme.SEARCH_URL .. freetp.urlencode(game_name))), game_name)
  if not article then return nil, "no_page" end
  local tdir = ofme.torrent_dir(fetch(article.url))
  if not tdir then return nil, "no_torrent_dir" end
  local info = ofme.parse_torrent_listing(fetch(tdir))
  if not info then return nil, "no_torrent" end
  return info
end

-- fetch_freetp(game_name, get, clock) -> { revision?, epoch?, note? } or nil,
-- reason. resolve()'s 15 s search budget is sized for a user staring at a
-- busy tile; this decoration gets 6 — the injected clock is simply shifted,
-- so resolve's own accounting does the truncating.
function fixfresh.fetch_freetp(game_name, get, clock)
  clock = clock or os.time
  local shift = freetp.SEARCH_BUDGET - 6
  local res = freetp.resolve(game_name, get, function() return clock() - shift end)
  if res.errorCode then return nil, res.errorCode end
  local fix = freetp.pick_fix_file(res.files)
  return { revision = fix and freetp.fix_revision(fix.label) or nil,
    epoch = res.updated, note = res.updatedNote }
end

local function side(epoch, extra)
  local t = extra or {}
  t.date = epoch
  t.dateText = epoch and os.date("%d.%m.%Y", epoch) or nil
  return t
end

-- get(appid, game_name, deps) -> { success, ofme?, freetp?, newer, cached? }.
-- deps: get / clock, injectable for tests. One side's network failure just
-- drops that side; only the total absence of an http client fails the call.
function fixfresh.get(appid, game_name, deps)
  deps = deps or {}
  local clock = deps.clock or os.time
  appid = tonumber(appid)
  if not appid or type(game_name) ~= "string" or game_name == "" then
    return { success = false, errorCode = "no_name" }
  end
  local hit = cache[appid]
  if hit and clock() - hit.at < fixfresh.CACHE_TTL then
    hit.result.cached = true
    return hit.result
  end
  local get = deps.get
  if not get then
    local ok, http = pcall(require, "http")
    get = ok and type(http) == "table" and http.get or nil
  end
  if not get then return { success = false, errorCode = "http_unavailable" } end
  local res = { success = true, newer = "unknown" }
  local o = fixfresh.fetch_ofme(game_name, get)
  if o then res.ofme = side(o.epoch, { version = o.version }) end
  local f = fixfresh.fetch_freetp(game_name, get, clock)
  if f then res.freetp = side(f.epoch, { revision = f.revision }) end
  res.newer = fixfresh.compare(o and o.epoch, f and f.epoch)
  cache[appid] = { at = clock(), result = res }
  return res
end

-- register(registry, deps): LumenGetFixFreshness. The bridge passes
-- {appid, contentScriptQuery, gameName} alphabetically positional; the table
-- form is tolerated too.
function fixfresh.register(registry, deps)
  local json = require("json")
  registry.LumenGetFixFreshness = function(appid, contentScriptQuery, gameName)
    if type(appid) == "table" then gameName, appid = appid.gameName, appid.appid end
    local ok, res = pcall(fixfresh.get, appid, gameName, deps)
    return json.encode(ok and res or { success = false, error = tostring(res) })
  end
  return registry
end

-- Tests reset the cache between cases.
function fixfresh._reset() for k in pairs(cache) do cache[k] = nil end end

return fixfresh
