-- onlinefixme.lua — the Online Fix tile's online-fix.me path.
--
-- online-fix.me pages and its uploads server's folder listings open without
-- an account, but the files themselves answer 401 unless logged in. Each
-- game's .torrent is public, though, and every one carries two files:
-- "Fix Repair/<Game>_Fix_Repair_Steam_..._Generic.rar" (~11 MB, the fix for a
-- Steam copy) and "<Game>.vX-OFME.rar" (the full game, GBs). Only the Fix
-- Repair file is fetched, by aria2c in the background so the download never
-- blocks the single-threaded daemon loop (only the page lookups do: four
-- small requests, 6 s cap each); the frontend polls status() and installs
-- the result through fixinstall (recorded, so Un-fix reverts it).
--
-- Pure parsers are unit-tested with real page shapes (tools/test_onlinefixme.lua);
-- start()/status() take injectable deps and never touch the network in tests.

local freetp = require("freetp")

local ofme = {}

ofme.BASE_URL = "https://online-fix.me"
ofme.SEARCH_URL = ofme.BASE_URL .. "/index.php?do=search&subaction=search&story="

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

-- pgrep/pkill pattern for one appid's aria2c job; "[a]ria2c" keeps it from
-- matching the shell that runs pgrep.
local function job_pattern(dir)
  return shell_quote("[a]ria2c .*" .. dir .. "/fix.torrent")
end

-- parse_search(html) -> { { url, title } } for the result titles. PURE.
function ofme.parse_search(html)
  local out, seen = {}, {}
  if type(html) ~= "string" then return out end
  for url, title in html:gmatch(
      'href="(https://online%-fix%.me/games/[^"]+%.html)"><h2 class="title">%s*([^<]-)%s*</h2>') do
    if not seen[url] then
      seen[url] = true
      out[#out + 1] = { url = url, title = title }
    end
  end
  return out
end

-- torrent_dir(html) -> the article's uploads-server torrent folder, or nil. PURE.
function ofme.torrent_dir(html)
  return type(html) == "string"
    and html:match('href="(https://uploads%.online%-fix%.me:2053/torrents/[^"]+)"') or nil
end

-- pick_fix_index(listing) -> index, path of the Fix Repair archive in
-- `aria2c -S` output ("  1|./Game/Fix Repair/X.rar"), or nil. The full-game
-- -OFME.rar is never picked. PURE.
function ofme.pick_fix_index(listing)
  if type(listing) ~= "string" then return nil end
  for line in (listing .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local idx, path = line:match("^%s*(%d+)|%./(.+)$")
    local low = path and path:lower() or ""
    if idx and low:find("fix repair/", 1, true)
        and (low:match("%.rar$") or low:match("%.zip$") or low:match("%.7z$")) then
      return tonumber(idx), path
    end
  end
  return nil
end

-- Months as the uploads server's nginx autoindex prints them.
local AUTOINDEX_MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
  Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

-- parse_torrent_listing(html) -> { name, version?, epoch? } for the folder's
-- .torrent, or nil. The uploads server is an nginx autoindex — one line per
-- file: '<a href="CRACK.v1.1.29-OFME.torrent">…</a>  04-Nov-2026 15:04  37K'.
-- The name carries the game build the fix targets, the stamp the upload
-- moment (server-local, read as local time: the freshness compare only asks
-- for day granularity). PURE.
function ofme.parse_torrent_listing(html)
  if type(html) ~= "string" then return nil end
  for line in (html .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local name = line:match('href="([^"]+%.torrent)"')
    if name then
      local base = name:match("([^/]+)$") or name
      local res = { name = base,
        version = base:match("%.v([%d%.]+)%-OFME%.torrent$")
          or base:match("%.v([%d%.]+)%.torrent$") }
      local d, mon, y, hh, mm = line:match("(%d+)%-(%a+)%-(%d+)%s+(%d+):(%d+)")
      if d and AUTOINDEX_MONTHS[mon] then
        res.epoch = os.time({ year = tonumber(y), month = AUTOINDEX_MONTHS[mon],
          day = tonumber(d), hour = tonumber(hh), min = tonumber(mm), sec = 0 })
      end
      return res
    end
  end
  return nil
end

local function default_deps(deps)
  deps = deps or {}
  deps.execute = deps.execute or os.execute
  deps.read_pipe = deps.read_pipe or function(cmd)
    local p = io.popen(cmd, "r")
    if not p then return "" end
    local out = p:read("*a")
    p:close()
    return out or ""
  end
  deps.read_file = deps.read_file or function(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
  end
  deps.write_file = deps.write_file or function(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
  end
  deps.dl_root = deps.dl_root
    or ((os.getenv("HOME") or "") .. "/.local/share/Lumen/onlinefix_dl")
  return deps
end

-- start(appid, game_name, deps) -> { success, path } once aria2c is running
-- in the background (or already was), else { success = false, reason }.
function ofme.start(appid, game_name, deps)
  deps = default_deps(deps)
  local res = { success = false }
  appid = tonumber(appid)
  if not appid or type(game_name) ~= "string" or game_name == "" then
    res.reason = "no_name"
    return res
  end
  local dir = deps.dl_root .. "/" .. appid
  local state = ofme.status(appid, deps).state
  if state == "downloading" or state == "done" then
    res.success, res.path = true, deps.read_file(dir .. "/target")
    return res
  end
  local aria2 = deps.read_pipe("command -v aria2c 2>/dev/null"):match("^(%S+)")
  if not aria2 then
    res.reason = "no_aria2"
    return res
  end
  local get = deps.get
  if not get then
    local ok, http = pcall(require, "http")
    if not ok or type(http) ~= "table" or type(http.get) ~= "function" then
      res.reason = "http_unavailable"
      return res
    end
    get = http.get
  end
  local function fetch(url)
    local ok, r = pcall(get, url, { timeout = 6 })
    if ok and type(r) == "table" and r.status == 200 and type(r.body) == "string" then
      return r.body
    end
  end

  local article = freetp.pick_article(
    ofme.parse_search(fetch(ofme.SEARCH_URL .. freetp.urlencode(game_name))), game_name)
  local tdir = article and ofme.torrent_dir(fetch(article.url))
  local tname = tdir and (fetch(tdir) or ""):match('href="([^"]+%.torrent)"')
  local torrent = tname and fetch(tdir .. tname)
  if not (torrent and torrent:sub(1, 1) == "d") then
    res.reason = article and "no_torrent" or "no_page"
    return res
  end

  deps.execute("rm -rf -- " .. shell_quote(dir) .. " && mkdir -p -- " .. shell_quote(dir))
  local tfile = dir .. "/fix.torrent"
  if not deps.write_file(tfile, torrent) then
    res.reason = "write_failed"
    return res
  end
  local idx, path = ofme.pick_fix_index(
    deps.read_pipe(shell_quote(aria2) .. " -S " .. shell_quote(tfile) .. " 2>/dev/null"))
  if not idx then
    res.reason = "no_fix_file"
    return res
  end
  local target = dir .. "/" .. path
  deps.write_file(dir .. "/target", target)
  -- Background job: stop when the file is complete (no seeding) or after
  -- 2 minutes without progress; the exit code lands in dir/exit for status().
  deps.execute("( timeout 900 " .. shell_quote(aria2) .. " --select-file=" .. idx
    .. " --seed-time=0 --bt-stop-timeout=120 --file-allocation=none"
    .. " --summary-interval=0 --console-log-level=warn --dir=" .. shell_quote(dir)
    .. " " .. shell_quote(tfile) .. " > " .. shell_quote(dir .. "/aria2.log") .. " 2>&1;"
    .. " echo $? > " .. shell_quote(dir .. "/exit") .. " ) >/dev/null 2>&1 &")
  res.success, res.path = true, target
  return res
end

-- status(appid, deps) -> { state = "downloading" | "done" | "failed" | "idle",
-- bytes? (downloading), path? (done) }.
function ofme.status(appid, deps)
  deps = default_deps(deps)
  local dir = deps.dl_root .. "/" .. tostring(tonumber(appid) or "")
  local target = deps.read_file(dir .. "/target")
  if not target then return { success = true, state = "idle" } end
  local exit = deps.read_file(dir .. "/exit")
  local bytes = tonumber(deps.read_pipe("stat -c %s -- " .. shell_quote(target)
    .. " 2>/dev/null"):match("%d+")) or 0
  if not exit and deps.read_pipe("pgrep -f -- " .. job_pattern(dir)) ~= "" then
    return { success = true, state = "downloading", bytes = bytes }
  end
  if exit and exit:match("^%s*0%s*$") and bytes > 0 then
    return { success = true, state = "done", path = target }
  end
  return { success = true, state = "failed" }
end

-- cancel(appid, deps): stop a running download; status() then reads failed.
function ofme.cancel(appid, deps)
  deps = default_deps(deps)
  deps.execute("pkill -f -- " .. job_pattern(deps.dl_root .. "/" .. tostring(tonumber(appid) or "")))
  return { success = true }
end

-- register(registry, deps): LumenStartOnlineFix / LumenOnlineFixStatus /
-- LumenCancelOnlineFix. The
-- bridge passes {appid, contentScriptQuery, gameName} alphabetically
-- positional; the table form is tolerated too.
function ofme.register(registry, deps)
  local json = require("json")
  local function wrap(fn, ...)
    local ok, res = pcall(fn, ...)
    return json.encode(ok and res or { success = false, error = tostring(res) })
  end
  registry.LumenStartOnlineFix = function(appid, contentScriptQuery, gameName)
    if type(appid) == "table" then gameName, appid = appid.gameName, appid.appid end
    return wrap(ofme.start, appid, gameName, deps)
  end
  registry.LumenOnlineFixStatus = function(appid)
    if type(appid) == "table" then appid = appid.appid end
    return wrap(ofme.status, appid, deps)
  end
  registry.LumenCancelOnlineFix = function(appid)
    if type(appid) == "table" then appid = appid.appid end
    return wrap(ofme.cancel, appid, deps)
  end
  return registry
end

return ofme
