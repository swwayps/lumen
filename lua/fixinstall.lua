-- fixinstall.lua — install a user-downloaded fix archive into a Steam game
-- WITH a manifest, so Un-fix can revert it.
--
-- Why: fixes from outside lua.tools (FreeTP's setup .exe, an archive the user
-- downloaded) would otherwise be extracted by hand, which leaves NO record —
-- Un-fix then cannot know which files to remove, and the fix's own overwrite
-- of a game DLL is invisible. This module runs that same manual flow through
-- Lumen: list the archive, note which game files it overwrites, extract it
-- into the game folder, and record everything under
--   ~/.local/share/Lumen/fix_installs/<appid>/manifest.json
-- Un-fix then removes the added files. No backups are kept: the overwritten
-- game files are Steam's own, so Steam's "Verify integrity of game files"
-- restores them (revert reports needsVerify and the menu offers it).
--
-- Pure helpers are unit-tested (tools/test_fixinstall.lua); the install and
-- revert paths take injectable deps and never touch Millennium in tests.

local fixinstall = {}

fixinstall.MAX_ARCHIVES_LISTED = 12
-- Each probe is a synchronous innoextract run on the single-threaded RPC loop.
fixinstall.MAX_SETUPS_PROBED = 8
-- Extraction is synchronous too: a multi-GB repack would stall every RPC.
fixinstall.MAX_ARCHIVE_BYTES = 512 * 1024 * 1024

local json = require("json")

-- Single-quote a value for the shell ('' escaping), like the rest of Lumen.
local function shq(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

-- download_dir(home) -> where Lumen stores a fix it downloaded itself; install
-- deletes an archive from here once it is extracted.
function fixinstall.download_dir(home)
  return home .. "/.local/share/Lumen/freetp_dl"
end

function fixinstall.is_archive_name(name)
  if type(name) ~= "string" then return false end
  local low = name:lower()
  return low:match("%.zip$") ~= nil or low:match("%.rar$") ~= nil
    or low:match("%.7z$") ~= nil
end

-- Inno Setup installers are how fix sites commonly ship their payload
-- ("CRACK-Multiplayer-Fix-Online.exe" style). innoextract reads them.
function fixinstall.is_inno_name(name)
  return type(name) == "string" and name:lower():match("%.exe$") ~= nil
end

function fixinstall.installable_name(name)
  return fixinstall.is_archive_name(name) or fixinstall.is_inno_name(name)
end

-- filter_archives(entries) -> installable entries no larger than
-- MAX_ARCHIVE_BYTES, newest-first, deduped, capped. Each entry:
-- { name, path, size, mtime }.
function fixinstall.filter_archives(entries)
  local out, seen = {}, {}
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    if type(e) == "table" and fixinstall.installable_name(e.name)
        and (tonumber(e.size) or 0) <= fixinstall.MAX_ARCHIVE_BYTES
        and not seen[e.path or e.name] then
      seen[e.path or e.name] = true
      out[#out + 1] = {
        name = tostring(e.name),
        path = tostring(e.path or ""),
        size = tonumber(e.size) or 0,
        mtime = math.floor(tonumber(e.mtime) or 0),
      }
    end
  end
  table.sort(out, function(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return a.name < b.name
  end)
  while #out > fixinstall.MAX_ARCHIVES_LISTED do table.remove(out) end
  return out
end

-- parse_7z_listing(text) -> { { path, size } } from `7zz l -ba -slt` output.
-- Directory entries (Attributes containing D) are skipped; blocks are
-- separated by "Path = ..." lines. PURE.
function fixinstall.parse_7z_listing(text)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  local path, size, is_dir
  local function flush()
    if path and not is_dir then
      out[#out + 1] = { path = path, size = tonumber(size) or 0 }
    end
    path, size, is_dir = nil, nil, nil
  end
  for line in text:gmatch("([^\r\n]*)\r?\n") do
    local k, v = line:match("^([%w_]+) = (.-)%s*$")
    if k == "Path" then
      flush(); path = v
    elseif k == "Size" and path then
      size = v
    elseif k == "Folder" and path and v:find("+", 1, true) then
      is_dir = true
    elseif k == "Attributes" and path then
      is_dir = v:find("D", 1, true) ~= nil
    end
  end
  flush()
  return out
end

-- safe_entries(entries) -> normalized list, or nil + reason when the archive
-- carries an absolute path or a ".." segment (zip-slip: the extractor would
-- write outside the game folder), or a backslash: 7-Zip on Linux extracts
-- "sub\fix.dll" as ONE file of that name in the game root, which neither the
-- game loads nor a "sub/fix.dll" record would let Un-fix remove. PURE.
function fixinstall.safe_entries(entries)
  local out = {}
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    local p = tostring(type(e) == "table" and e.path or "")
    if p ~= "" and not p:find("[\0\r\n]") then
      if p:find("\\", 1, true) then return nil, "backslash_path" end
      if p:sub(1, 1) == "/" or p:match("^%a:") then
        return nil, "absolute_path"
      end
      for seg in p:gmatch("[^/]+") do
        if seg == ".." then return nil, "parent_escape" end
      end
      if p:sub(-1) == "/" then p = p:sub(1, -2) end
      if p ~= "" then out[#out + 1] = { path = p, size = tonumber(e.size) or 0 } end
    end
  end
  return out
end

-- The game-folder file LuaTools' fix_overlays reads a fix's DLLs from.
local FIX_DLL_LIST = ".slssteam_fix_dlls"

-- fix_dll_list(entries) -> that file's text: the base name of each .dll the
-- archive ships, one per line, deduplicated ignoring case. PURE.
function fixinstall.fix_dll_list(entries)
  local lines, seen = {}, {}
  for _, e in ipairs(entries) do
    local name = e.path:match("[^/]+$")
    if name:lower():match("%.dll$") and not seen[name:lower()] then
      seen[name:lower()] = true
      lines[#lines + 1] = name .. "\n"
    end
  end
  return table.concat(lines)
end

-- parse_inno_listing(text) -> { { path, size } } from `innoextract -l`
-- output. Only the {app} payload matters: lines like
--   - "app/SteamFix.ini" (284 B)
--   - "tmp/botva2.dll" [temp] (32 KiB)
-- Entries carrying a flag ([temp], [lang:..] — Lua patterns cannot make a
-- group optional, and the unflagged form below simply never matches a
-- flagged line) are installer machinery, never payload; non-app/ destina-
-- tions are dropped, and the "app/" prefix is stripped so paths match the
-- game folder. PURE.
function fixinstall.parse_inno_listing(text)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  local units = { B = 1, KiB = 1024, MiB = 1048576, GiB = 1073741824 }
  for line in text:gmatch("([^\r\n]*)\r?\n") do
    local path, num, unit = line:match(
      '^%s*%-%s+"([^"]+)"%s+%(([%d%.]+)%s+([BKMG]i?B?)%)$')
    if path and path:sub(1, 4) == "app/" then
      local p = path:sub(5)
      if p ~= "" and not p:find("[\0\r\n]") and units[unit] then
        out[#out + 1] = { path = p, size = math.floor(tonumber(num) * units[unit]) }
      end
    end
  end
  return out
end

-- under_home(path, home) -> path lies inside home and carries no ".." segment.
-- The install RPC only accepts archives the user could have downloaded. PURE.
function fixinstall.under_home(path, home)
  path, home = tostring(path or ""), tostring(home or "")
  if path == "" or home == "" then return false end
  if path:sub(1, #home) ~= home then return false end
  local rest = path:sub(#home + 1)
  if rest:sub(1, 1) ~= "/" then return false end
  for seg in rest:gmatch("[^/]+") do
    if seg == ".." then return false end
  end
  return true
end

local function store_root()
  return (os.getenv("HOME") or "") .. "/.local/share/Lumen/fix_installs"
end

local function popen_read(cmd)
  local p = io.popen(cmd, "r")
  if not p then return "" end
  local out = p:read("*a")
  p:close()
  return out or ""
end

local function popen_line(cmd)
  local p = io.popen(cmd, "r")
  if not p then return nil end
  local l = p:read("*l")
  p:close()
  return l
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

-- The LuaTools plugin's 7zz, or "" without the plugin.
local function shipped_7zz()
  local backend = require("utils").get_backend_path()
  return backend ~= "" and backend .. "/bin/7zz" or ""
end

-- read_manifest(root) -> the record, or nil + errorCode when one exists but
-- cannot be read or decoded (nil alone: there is none).
local function read_manifest(root)
  local f, _, errno = io.open(root .. "/manifest.json", "rb")
  if not f then return nil, errno ~= 2 and "record_unreadable" or nil end
  local raw = f:read("*a")
  f:close()
  if not raw then return nil, "record_unreadable" end
  local ok, m = pcall(json.decode, raw)
  if not (ok and type(m) == "table") then return nil, "record_invalid" end
  return m
end

-- first_bin(candidates) -> the first candidate that exists: absolute paths
-- are probed directly, bare names resolved through PATH; nil when none.
local function first_bin(candidates)
  for _, c in ipairs(candidates) do
    if c:sub(1, 1) == "/" then
      if exists(c) then return c end
    else
      local out = popen_line("command -v -- " .. shq(c) .. " 2>/dev/null")
      if out and out ~= "" then return out end
    end
  end
  return nil
end

-- find_7z() -> absolute path of a 7-zip binary, or nil.
function fixinstall.find_7z()
  return first_bin({ "7zz", "7z", shipped_7zz() })
end

-- find_inno() -> absolute path of innoextract, or nil.
function fixinstall.find_inno()
  return first_bin({ "innoextract" })
end

-- list_archives(home, deps) -> recent archives from the user's real
-- downloads directory (xdg-user-dir DOWNLOAD, e.g. Turkish "İndirilenler"),
-- with ~/Downloads as a fallback; both are scanned and merged when distinct.
-- deps.read_pipe(cmd) -> text and deps.downloads_dir (single dir override)
-- are injectable for tests.
function fixinstall.list_archives(home, deps)
  deps = deps or {}
  home = home or os.getenv("HOME") or ""
  if home == "" then return {} end
  local read_pipe = deps.read_pipe or popen_read
  local read_line = deps.read_line or popen_line

  -- The dirs to scan: the explicit override, else xdg DOWNLOAD + ~/Downloads.
  local dirs = {}
  if deps.downloads_dir then
    dirs[#dirs + 1] = deps.downloads_dir
  else
    local xdg = read_line("xdg-user-dir DOWNLOAD 2>/dev/null")
    if type(xdg) == "string" and xdg:sub(1, 1) == "/" then dirs[#dirs + 1] = xdg end
    if dirs[1] ~= home .. "/Downloads" then dirs[#dirs + 1] = home .. "/Downloads" end
  end

  local entries = {}
  for _, dir in ipairs(dirs) do
    if os.execute("test -d " .. shq(dir) .. " 2>/dev/null") == true then
      local text = read_pipe(
        "find -- " .. shq(dir) .. " -maxdepth 1 -type f "
        .. "\\( -iname '*.zip' -o -iname '*.rar' -o -iname '*.7z' "
        .. "-o -iname '*.exe' \\) "
        .. "-printf '%s|%T@|%p\\n' 2>/dev/null | sort -t'|' -k2 -nr | head -60")
      -- Lua's '.' also matches newlines, so a single greedy (.+) would glue
      -- every find line into one bogus entry. Split into
      -- lines first (the same line splitter parse_7z_listing uses), then
      -- parse each line with an anchored pattern.
      if text:sub(-1) ~= "\n" then text = text .. "\n" end
      for line in text:gmatch("([^\r\n]*)\r?\n") do
        local size, mtime, path = line:match("^(%d+)%|([%d%.]+)%|(.+)$")
        if size and mtime and path and path ~= "" then
          entries[#entries + 1] = {
            name = path:match("([^/]+)$") or path,
            path = path,
            size = tonumber(size) or 0,
            mtime = math.floor(tonumber(mtime) or 0),
          }
        end
      end
    end
  end
  -- Classify exes: keep only Inno Setup installers innoextract can actually
  -- read — a random downloaded program must never appear in the fix picker.
  -- Newest first, so the setup just downloaded is always among those probed;
  -- setups too big to list are skipped before probing, so they never use up
  -- the probe budget.
  table.sort(entries, function(a, b) return a.mtime > b.mtime end)
  local inno_bin = fixinstall.find_inno()
  local kept, probed = {}, 0
  for _, e in ipairs(entries) do
    if not fixinstall.is_inno_name(e.name) then
      kept[#kept + 1] = e
    elseif inno_bin and probed < fixinstall.MAX_SETUPS_PROBED
        and e.size <= fixinstall.MAX_ARCHIVE_BYTES then
      probed = probed + 1
      local ltext = read_pipe(shq(inno_bin) .. " -l -- " .. shq(e.path) .. " 2>/dev/null")
      if #fixinstall.parse_inno_listing(ltext) > 0 then kept[#kept + 1] = e end
    end
  end
  return fixinstall.filter_archives(kept)
end

-- detect_local(install_path, deps) -> { found, broken }: is a REAL fix
-- installed in this game folder? A fix announces itself with a loader list
-- file (winmm.txt / dlllist.txt), a fix config (onlinefix.ini /
-- steamfix.ini), or a fix payload DLL (onlinefix*/steamfix*). A proxy DLL
-- (winmm/winhttp/version) alone is not enough: mod loaders such as BepInEx
-- ship one too. Only the install root and its direct subfolders (depots that
-- nest the game one level down) are scanned, and only for these fix-specific
-- names: a game-shipped DirectX redist (D3D12/D3D12Core.dll) must NEVER read
-- as "a fix is installed". deps.fs is injectable for tests.
function fixinstall.detect_local(install_path, deps)
  deps = deps or {}
  local res = { found = false, broken = false }
  if type(install_path) ~= "string" or install_path == "" then return res end
  local fs_mod = deps.fs
  if not fs_mod then
    local ok, f = pcall(require, "fs")
    fs_mod = ok and f or nil
  end
  if type(fs_mod) ~= "table" or type(fs_mod.list) ~= "function" then return res end
  local ok, entries = pcall(fs_mod.list, install_path)
  if not ok or type(entries) ~= "table" then return res end
  local files = {}
  for _, e in ipairs(entries) do
    if type(e) == "table" and e.is_directory then
      local ok_sub, sub = pcall(fs_mod.list, install_path .. "/" .. tostring(e.name))
      for _, s in ipairs(ok_sub and type(sub) == "table" and sub or {}) do
        if type(s) == "table" and not s.is_directory then files[#files + 1] = s end
      end
    elseif type(e) == "table" then
      files[#files + 1] = e
    end
  end
  local proxies = { winmm = true, winhttp = true, version = true }
  local proxy, loader = false, false
  for _, e in ipairs(files) do
    local low = tostring(e.name or ""):lower()
    local stem = low:match("^(.-)%.dll$")
    if stem and proxies[stem] then proxy = true end
    if low == "winmm.txt" or low == "dlllist.txt" then loader = true end
    if low == "onlinefix.ini" or low == "steamfix.ini"
        or (stem and (stem:match("^onlinefix%d*$") or stem:match("^steamfix%d*$"))) then
      res.found = true
    end
  end
  res.found = res.found or loader
  -- A loader list without its proxy DLL cannot load (LuaTools' UnFixGame
  -- deletes winmm.dll even when no fix of its own is recorded).
  res.broken = loader and not proxy
  return res
end

-- game_root(install_dir, entries, list_dir) -> the folder the fix belongs
-- in. Some depots nest the game one level down ("How to Fish/How to Fish/
-- How to Fish.exe"), so the target is whichever of the install dir and its
-- direct subfolders already holds the most of the archive's top-level names
-- (the game exe, its _Data folder); ties keep the install dir.
-- list_dir(path) -> { { name, is_directory } } (lumen fs.list contract).
function fixinstall.game_root(install_dir, entries, list_dir)
  local tops = {}
  for _, e in ipairs(entries) do tops[e.path:match("^[^/]+")] = true end
  local function score(dir)
    local ok, list = pcall(list_dir, dir)
    local n = 0
    for _, x in ipairs(ok and type(list) == "table" and list or {}) do
      if tops[x.name] then n = n + 1 end
    end
    return n, ok and list or {}
  end
  local best, best_n, list = install_dir, score(install_dir)
  for _, x in ipairs(list) do
    if x.is_directory then
      local n = score(install_dir .. "/" .. x.name)
      if n > best_n then best, best_n = install_dir .. "/" .. x.name, n end
    end
  end
  return best
end

local function resolve_install_default(appid)
  local ok, su = pcall(require, "steam_utils")
  if ok and su and su.get_game_install_path_response then
    return su.get_game_install_path_response(appid)
  end
  return nil
end

-- trusted_install_dir(appid, hint, resolve) -> Steam's own install dir for
-- appid, or nil + errorCode when the game is not installed or the frontend's
-- hint names another folder.
local function trusted_install_dir(appid, hint, resolve)
  local info = (resolve or resolve_install_default)(appid)
  if type(info) ~= "table" or info.success ~= true
      or type(info.installPath) ~= "string" or info.installPath == "" then
    return nil, "not_installed"
  end
  hint = tostring(hint or "")
  if hint ~= "" and hint ~= info.installPath then return nil, "invalid_destination" end
  return info.installPath
end

-- remove_added(m) -> how many of record m's added files were removed from its
-- game folder, or nil for no record or one naming a path outside that folder.
local function remove_added(m)
  local install_dir = m and tostring(m.installPath or "") or ""
  if install_dir == "" then return nil end
  local added = {}
  for _, p in ipairs(type(m.added) == "table" and m.added or {}) do
    added[#added + 1] = { path = tostring(p) }
  end
  -- A tampered record must never delete outside the game folder.
  added = fixinstall.safe_entries(added)
  if not added then return nil end

  for _, e in ipairs(added) do
    local p = e.path
    os.execute("rm -f -- " .. shq(install_dir .. "/" .. p))
    -- Folders the fix brought along go too, but only once empty.
    local parent = p:match("^(.*)/[^/]+$")
    if parent then
      os.execute("cd " .. shq(install_dir) .. " && rmdir -p --ignore-fail-on-non-empty -- "
        .. shq(parent) .. " 2>/dev/null")
    end
  end
  return #added
end

-- write_manifest(root, data, open) -> true once data is root/manifest.json in
-- full. It goes to a temporary file renamed over the record, so a failed
-- write (unwritable folder, full disk) leaves the previous record whole.
local function write_manifest(root, data, open)
  local tmp = root .. "/manifest.json.tmp"
  local f = open(tmp, "wb")
  if not f then return false end
  local written = f:write(data)
  local closed = f:close()
  if not (written and closed and os.rename(tmp, root .. "/manifest.json")) then
    os.remove(tmp)
    return false
  end
  return true
end

local function install_archive(appid, archive_path, install_path_hint, deps)
  local res = { success = false }
  appid = tonumber(appid)
  if not appid or appid <= 0 or appid ~= math.floor(appid) then
    res.errorCode = "invalid_appid"
    return res
  end

  local install_dir, why = trusted_install_dir(appid, install_path_hint, deps.resolve_install)
  if not install_dir then
    res.errorCode = why
    return res
  end

  archive_path = tostring(archive_path or "")
  local home = deps.home or os.getenv("HOME") or ""
  if not fixinstall.under_home(archive_path, home)
      or not fixinstall.installable_name(archive_path) then
    res.errorCode = "invalid_archive"
    return res
  end
  if not exists(archive_path) then
    res.errorCode = "archive_missing"
    return res
  end

  local is_inno = fixinstall.is_inno_name(archive_path)
  local bin = deps.bin or (not is_inno and fixinstall.find_7z()) or nil
  if not is_inno and not bin then
    res.errorCode = "no_extractor"
    return res
  end
  local inno_bin = is_inno and fixinstall.find_inno() or nil
  if is_inno and not inno_bin then
    res.errorCode = "no_extractor_inno"
    return res
  end

  -- The extractor commands run through deps.read_pipe / deps.execute
  -- (injectable for tests).
  local read_pipe, execute = deps.read_pipe or popen_read, deps.execute or os.execute
  -- 7-Zip waits on stdin for the password of an encrypted archive, which
  -- would stall the single-threaded RPC loop; with no stdin it fails at once.
  local function list_7z(b)
    return fixinstall.safe_entries(fixinstall.parse_7z_listing(read_pipe(shq(b)
      .. " l -ba -slt -- " .. shq(archive_path) .. " </dev/null 2>/dev/null")))
  end
  local entries
  if is_inno then
    local itext = read_pipe(shq(inno_bin) .. " -l -- " .. shq(archive_path) .. " 2>/dev/null")
    entries = fixinstall.safe_entries(fixinstall.parse_inno_listing(itext))
  else
    entries = list_7z(bin)
    -- A PATH 7z without the RAR codec lists nothing; the bundled 7zz has it.
    if entries and #entries == 0 and not deps.bin and bin ~= shipped_7zz()
        and exists(shipped_7zz()) then
      bin = shipped_7zz()
      entries = list_7z(bin)
    end
  end
  if not entries then
    res.errorCode = "unsafe_archive"
    return res
  end
  if #entries == 0 then
    res.errorCode = "bad_archive"
    return res
  end

  -- A previous install of ours is removed first so records stay truthful;
  -- the game files IT overwrote still hold fix content, so they stay listed.
  -- Its record stays until the new one replaces it.
  local root = (deps.store_root or store_root)() .. "/" .. appid
  local prev = read_manifest(root)
  remove_added(prev)
  install_dir = fixinstall.game_root(install_dir, entries,
    function(p) return require("fs").list(p) end)
  local stage = root .. "/stage"
  os.execute("mkdir -p -- " .. shq(root))
  os.execute("rm -rf -- " .. shq(stage))

  -- Which game files will be overwritten: decided BEFORE any file lands.
  local added, replaced, replaced_set = {}, {}, {}
  for _, e in ipairs(entries) do
    if exists(install_dir .. "/" .. e.path) then
      replaced[#replaced + 1] = e.path
      replaced_set[e.path] = true
    end
  end
  for _, e in ipairs(entries) do
    if not replaced_set[e.path] then added[#added + 1] = e.path end
  end
  -- The fix's DLL list for the launch options, as LuaTools' downloader writes
  -- it: without one, its fix_overlays derives overrides from every DLL in the
  -- game folder (the game's own D3D12/D3D12Core.dll included). It is written
  -- even when empty, which reads as "no override needed". One already there
  -- belongs to a LuaTools fix and is left alone.
  local dll_list = install_dir .. "/" .. FIX_DLL_LIST
  local write_dll_list = not exists(dll_list)
  if write_dll_list then added[#added + 1] = FIX_DLL_LIST end
  -- Even when this archive picks another game root: revert only counts them.
  if prev and type(prev.replaced) == "table" then
    for _, p in ipairs(prev.replaced) do
      if not replaced_set[p] then
        replaced[#replaced + 1] = p
        replaced_set[p] = true
      end
    end
  end

  -- Recorded BEFORE extraction: a half-finished extract stays revertible.
  if not write_manifest(root, json.encode({
    installedAt = os.time(),
    archive = archive_path:match("([^/]+)$") or archive_path,
    installPath = install_dir,
    added = added,
    replaced = replaced,
  }), deps.open_file or io.open) then
    res.errorCode = "record_failed"
    return res
  end

  if is_inno then
    -- innoextract recreates app/ (the {app} payload) and tmp/ (wizard
    -- resources) under the stage; only app/* moves into the game folder.
    if execute(shq(inno_bin) .. " -d " .. shq(stage) .. " -- "
        .. shq(archive_path) .. " >/dev/null 2>&1") ~= true then
      res.errorCode = "extract_failed"
      return res
    end
    for _, e in ipairs(entries) do
      local dst = install_dir .. "/" .. e.path
      local parent = dst:match("^(.*)/[^/]+$")
      if parent then os.execute("mkdir -p -- " .. shq(parent) .. " 2>/dev/null") end
      os.execute("mv -f -- " .. shq(stage .. "/app/" .. e.path) .. " " .. shq(dst))
    end
    os.execute("rm -rf -- " .. shq(stage))
  elseif execute(shq(bin) .. " x -y -o" .. shq(install_dir) .. " -- "
      .. shq(archive_path) .. " </dev/null >/dev/null 2>&1") ~= true then
    res.errorCode = "extract_failed"
    return res
  end
  if write_dll_list then
    local f = io.open(dll_list, "wb")
    if f then
      f:write(fixinstall.fix_dll_list(entries))
      f:close()
    end
  end

  res.success = true
  res.added = #added
  res.replaced = #replaced
  return res
end

-- install(appid, archive_path, install_path_hint, deps)
--   -> { success, added, replaced } or { success=false, errorCode }
-- The install dir is always re-derived from Steam's own manifests; the
-- frontend's hint must agree with it or the call is refused. A file Lumen
-- downloaded itself (download_dir) is deleted afterwards, installed or not:
-- Un-fix works from the manifest, and a failed one is downloaded again.
function fixinstall.install(appid, archive_path, install_path_hint, deps)
  deps = deps or {}
  local res = install_archive(appid, archive_path, install_path_hint, deps)
  local path, home = tostring(archive_path or ""), deps.home or os.getenv("HOME") or ""
  if fixinstall.under_home(path, home)
      and path:find(fixinstall.download_dir(home) .. "/", 1, true) == 1 then
    os.execute("rm -f -- " .. shq(path))
  end
  return res
end

-- revert(appid, deps) -> { success, reverted, removed, replacedCount,
-- needsVerify }. Removes the files the fix added; game files it overwrote
-- come back only through Steam's verify (needsVerify). With no recorded
-- install it reports reverted=false and touches nothing; a record it cannot
-- read or use (bad JSON, a path outside the game folder) fails with an
-- errorCode, as its files may still be in place.
function fixinstall.revert(appid, deps)
  deps = deps or {}
  local res = { success = true, reverted = false, removed = 0,
    replacedCount = 0, needsVerify = false }
  appid = tonumber(appid)
  if not appid then return res end
  local root = (deps.store_root or store_root)() .. "/" .. appid
  local m, why = read_manifest(root)
  if why then
    res.success = false
    res.errorCode = why
    return res
  end
  if not m then return res end
  local removed = remove_added(m)
  if not removed then
    res.success = false
    res.errorCode = "record_invalid"
    return res
  end
  res.removed = removed
  res.replacedCount = #(type(m.replaced) == "table" and m.replaced or {})
  res.needsVerify = res.replacedCount > 0
  os.execute("rm -rf -- " .. shq(root))
  res.reverted = true
  return res
end

-- register(registry, deps): `deps` reaches install and revert — inject it
-- from tests; production leaves it nil.
function fixinstall.register(registry, deps)
  -- Bridge contract: JS object keys arrive alphabetically positional; the
  -- table form is tolerated too.
  registry.LumenDetectLocalFix = function(appid, contentScriptQuery, installPath)
    if type(appid) == "table" then
      installPath = appid.installPath
      appid = appid.appid
    end
    appid = tonumber(appid)
    local res = { success = true, found = false }
    local dir = appid and trusted_install_dir(appid, installPath)
    if not dir then return json.encode(res) end
    local ok, det = pcall(fixinstall.detect_local, dir)
    res.found = ok and type(det) == "table" and det.found == true
    res.broken = res.found and det.broken == true
    return json.encode(res)
  end
  registry.LumenListFixArchives = function()
    local ok, res = pcall(fixinstall.list_archives, nil, {})
    if not ok then
      return json.encode({ success = false, error = tostring(res) })
    end
    return json.encode({ success = true, archives = res })
  end
  -- {appid, archivePath, contentScriptQuery, installPath} sorted.
  registry.LumenInstallFixArchive = function(appid, archivePath, contentScriptQuery, installPath)
    if type(appid) == "table" then
      archivePath = appid.archivePath
      installPath = appid.installPath
      appid = appid.appid
    end
    local ok, res = pcall(fixinstall.install, appid, archivePath, installPath, deps)
    if not ok then
      return json.encode({ success = false, errorCode = "crash", error = tostring(res) })
    end
    return json.encode(res)
  end
  registry.LumenRevertFixInstall = function(appid, contentScriptQuery)
    if type(appid) == "table" then appid = appid.appid end
    local ok, res = pcall(fixinstall.revert, appid, deps)
    if not ok then
      return json.encode({ success = false, error = tostring(res) })
    end
    return json.encode(res)
  end
  return registry
end

return fixinstall
