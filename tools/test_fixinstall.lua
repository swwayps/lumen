-- Host tests for fixinstall.lua: the recorded install of a user-downloaded
-- fix archive (manifest so Un-fix reverts manual fixes) — pure
-- helpers plus a REAL end-to-end with a tiny zip built and reverted in /tmp.
-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_fixinstall.lua
package.path = "lua/?.lua;" .. package.path

local fi = require("fixinstall")
local json = require("json")

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; io.write("FAIL: " .. name .. "\n") end
end
local function q(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end
local function read_file(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end
local function write_file(p, s)
  local f = io.open(p, "wb"); if not f then return false end
  f:write(s); f:close(); return true
end

-- ── pure helpers ────────────────────────────────────────────────────────────
check("archive name: zip/rar/7z, case-insensitive",
  fi.is_archive_name("Fix.ZIP") and fi.is_archive_name("a.rar") and fi.is_archive_name("b.7z"))
check("archive name: non-archives rejected",
  not fi.is_archive_name("notes.txt") and not fi.is_archive_name(nil) and not fi.is_archive_name("zip"))

do
  local entries = {}
  for i = 1, 15 do
    entries[#entries + 1] = { name = "f" .. i .. ".zip", path = "/d/f" .. i .. ".zip",
      size = i, mtime = 1000 + i }
  end
  entries[#entries + 1] = { name = "readme.txt", path = "/d/readme.txt", size = 1, mtime = 9999 }
  entries[#entries + 1] = { name = "f2.zip", path = "/d/f2.zip", size = 2, mtime = 9999 } -- dup
  local out = fi.filter_archives(entries)
  check("filter: capped at MAX_ARCHIVES_LISTED", #out == fi.MAX_ARCHIVES_LISTED)
  check("filter: newest first", out[1].name == "f15.zip" and out[1].mtime == 1015)
  check("filter: non-archives dropped",
    (function() for _, e in ipairs(out) do if e.name == "readme.txt" then return false end end return true end)())
  local seen_paths, unique = {}, true
  for _, e in ipairs(out) do
    if seen_paths[e.path] then unique = false end
    seen_paths[e.path] = true
  end
  check("filter: duplicate paths dropped", unique)
  check("filter: malformed input -> empty", #fi.filter_archives(nil) == 0 and #fi.filter_archives("x") == 0)
  local sized = fi.filter_archives({
    { name = "fix.rar", path = "/d/fix.rar", size = fi.MAX_ARCHIVE_BYTES, mtime = 1 },
    { name = "repack.exe", path = "/d/repack.exe", size = fi.MAX_ARCHIVE_BYTES + 1, mtime = 2 },
  })
  check("filter: archives too big to extract on the RPC loop are dropped",
    #sized == 1 and sized[1].name == "fix.rar")
end

do
  local listing = table.concat({
    "Path = CRACK_Data", "Folder = +", "", -- directory: no Size
    "", "Path = OnlineFix.ini", "Size = 464", "Attributes = A_ -rwxrwxrwx", "",
    "Path = sub/deep dll file.txt", "Size = 10", "Attributes = A_", "",
    "Path = bad", "Size = 3", "Attributes = D_", "",
  }, "\n") .. "\n"
  local parsed = fi.parse_7z_listing(listing)
  check("listing: files parsed, dirs skipped", #parsed == 2
    and parsed[1].path == "OnlineFix.ini" and parsed[1].size == 464
    and parsed[2].path == "sub/deep dll file.txt")
  check("listing: empty/malformed -> nothing", #fi.parse_7z_listing("") == 0
    and #fi.parse_7z_listing(nil) == 0)
  local safe, bad = fi.safe_entries(parsed)
  check("safe: nested paths with spaces pass", safe ~= nil and #safe == 2)
  local bad_abs = fi.safe_entries({ { path = "/etc/passwd" } })
  check("safe: absolute entry refused", bad_abs == nil)
  local bad_up = fi.safe_entries({ { path = "a/../../b.txt" } })
  check("safe: parent escape refused", bad_up == nil)
  local bad_win = fi.safe_entries({ { path = "C:/evil.txt" } })
  check("safe: windows drive refused", bad_win == nil)
end

check("under_home: own downloads ok", fi.under_home("/home/me/Downloads/a.zip", "/home/me") == true)
check("under_home: sibling prefix refused", fi.under_home("/home/mex/a.zip", "/home/me") == false)
check("under_home: escape refused", fi.under_home("/home/me/../root/a.zip", "/home/me") == false)
check("under_home: empty -> false", fi.under_home("", "/home/me") == false)

-- ── Inno Setup listing (fixtures verbatim from a real fix setup) ──────────
do
  local listing = table.concat({
    'Listing "CRACK" - setup data version 5.5.0.1 (unicode)',
    ' - "tmp/botva2.dll" [temp] (32 KiB)',
    ' - "tmp/WizardImage.jpg" [temp] (62.6 KiB)',
    ' - "app/favicon.ico" (15 KiB)',
    ' - "app/CRACK_Data/Plugins/x86_64/steam_api64.dll" (293 KiB)',
    ' - "app/SteamFix.ini" (284 B)',
    ' - "app/SteamFix64.dll" (1.32 MiB)',
    ' - "app/winmm.dll" (22.5 KiB)',
    ' - "app/winmm.txt" (14 B)',
    'Done.',
  }, "\n") .. "\n"
  local parsed = fi.parse_inno_listing(listing)
  check("inno: app payload parsed, temp skipped", #parsed == 6)
  check("inno: app/ prefix stripped",
    parsed[1].path == "favicon.ico" and parsed[6].path == "winmm.txt")
  check("inno: size units converted (MiB/KiB/B)",
    parsed[3].size == 284 and parsed[4].size == math.floor(1.32 * 1048576)
      and parsed[5].size == math.floor(22.5 * 1024))
  check("inno: paths survive safe_entries",
    (function() local safe = fi.safe_entries(parsed)
      return safe ~= nil and #safe == 6 end)())
  check("inno: malformed -> empty", #fi.parse_inno_listing("") == 0
    and #fi.parse_inno_listing("no listing here") == 0
    and #fi.parse_inno_listing(nil) == 0)
  check("inno: exe names installable, others not",
    fi.installable_name("CRACK-Multiplayer-Fix-Online.exe") == true
      and fi.installable_name("setup.msi") == false
      and fi.is_inno_name("a.EXE") == true)
  check("filter: exe setups pass the installable gate",
    #fi.filter_archives({ { name = "fix.exe", path = "/d/fix.exe", size = 1, mtime = 2 } }) == 1)
end

-- ── list_archives ──────────────────────────────────────────────────────────
do
  -- Lua's '.' also matches newlines: an unstripped find line would make every
  -- name end in ".zip\n" and the archive filter would drop everything.
  local tmpd = "/tmp/lumen_fixinstall_list_test"
  os.execute("rm -rf -- " .. q(tmpd) .. " && mkdir -p -- " .. q(tmpd))
  local fake = "11581994|1794094118.5473931040|" .. tmpd .. "/4312190.zip\n"
    .. "502272|1794093000.0000000000|" .. tmpd .. "/test.rar\n"
  local out = fi.list_archives("/home/user", {
    downloads_dir = tmpd,
    read_line = function() return nil end,
    read_pipe = function(cmd) return fake end,
  })
  check("list: newline stripped, entries kept", #out == 2
    and out[1].name == "4312190.zip" and out[2].name == "test.rar")
  check("list: names pass the archive filter",
    fi.is_archive_name(out[1].name) and fi.is_archive_name(out[2].name))
  check("list: newest first across dirs", out[1].mtime >= out[2].mtime)
  local xdg_out = fi.list_archives("/home/user", {
    read_line = function() return tmpd end,
    read_pipe = function(cmd)
      if cmd:find(tmpd, 1, true) then return fake end
      return ""
    end,
  })
  check("list: xdg DOWNLOAD dir is scanned first", #xdg_out == 2)

  -- Beyond the probe cap, the setup just downloaded must still be listed.
  local lines, probed = {}, {}
  for i = 1, fi.MAX_SETUPS_PROBED + 2 do
    lines[#lines + 1] = string.format("100|%d|%s/setup%02d.exe", 1000 + i, tmpd, i)
  end
  local setups = fi.list_archives("/home/user", {
    downloads_dir = tmpd,
    read_line = function() return nil end,
    read_pipe = function(cmd)
      if cmd:find("^find ") then return table.concat(lines, "\n") .. "\n" end
      probed[#probed + 1] = cmd:match("(setup%d+)%.exe")
      return ' - "app/fix.dll" (1 KiB)\n'
    end,
  })
  if fi.find_inno() then
    check("list: the newest setups are the ones probed and listed",
      #probed == fi.MAX_SETUPS_PROBED
        and setups[1].name == string.format("setup%02d.exe", fi.MAX_SETUPS_PROBED + 2)
        and #setups == fi.MAX_SETUPS_PROBED)
  else
    check("list: without innoextract no setup is listed", #setups == 0 and #probed == 0)
  end
  os.execute("rm -rf -- " .. q(tmpd))
end

-- ── detect_local (the false-positive gate) ─────────────────────────────────
do
  local function fake_fs(files)
    return { list = function(dir)
      assert(dir == "/g", "a root without subfolders is the only listing")
      local out = {}
      for _, f in ipairs(files) do
        out[#out + 1] = { name = f, path = "/g/" .. f, is_directory = false }
      end
      return out
    end }
  end
  local function det(files) return fi.detect_local("/g", { fs = fake_fs(files) }) end
  check("detect: proxy + loader list -> a working fix",
    det({ "winmm.dll", "winmm.txt" }).found and not det({ "winmm.dll", "winmm.txt" }).broken)
  check("detect: loader list whose proxy DLL was deleted -> broken",
    det({ "SteamFix.ini", "SteamFix64.dll", "winmm.txt" }).broken == true)
  check("detect: fix ini or payload alone -> found, not broken",
    det({ "OnlineFix.ini" }).found and det({ "SteamFix64.dll" }).found
      and not det({ "OnlineFix64.dll", "OnlineFix.ini" }).broken)
  -- A game-shipped DirectX redist (D3D12/D3D12Core.dll) or an ordinary game
  -- DLL is not fix evidence.
  check("detect: game DLLs are not a fix",
    fi.detect_local("/g", { fs = fake_fs({ "UnityPlayer.dll", "steam_api64.dll" }) }).found == false)
  -- A mod loader (BepInEx) ships a lone proxy DLL in the game root.
  check("detect: a proxy DLL alone is not a fix", det({ "winhttp.dll", "doorstop_config.ini" }).found == false)
  check("detect: no files -> not found", fi.detect_local("/g", { fs = fake_fs({}) }).found == false)
  -- A tree: dirs map to their listings; deeper levels must never be read.
  local function tree_fs(t)
    return { list = function(dir)
      assert(t[dir], "listed beyond one subfolder level: " .. dir)
      return t[dir]
    end }
  end
  local d, f = function(n) return { name = n, is_directory = true } end,
    function(n) return { name = n, is_directory = false } end
  check("detect: fix in a nested game folder is found",
    fi.detect_local("/g", { fs = tree_fs({
      ["/g"] = { d("How to Fish") },
      ["/g/How to Fish"] = { f("How to Fish.exe"), f("winmm.dll"), f("winmm.txt"), d("How to Fish_Data") },
    }) }).found == true)
  check("detect: a subfolder DirectX redist is still not a fix",
    fi.detect_local("/g", { fs = tree_fs({
      ["/g"] = { f("CRACK.exe"), d("D3D12") },
      ["/g/D3D12"] = { f("D3D12Core.dll") },
    }) }).found == false)

  -- game_root: where a fix archive's top-level names already live
  local entries = { { path = "How to Fish.exe" }, { path = "winmm.dll" },
    { path = "How to Fish_Data/Plugins/x86_64/steam_api64.dll" } }
  local nested = {
    ["/g"] = { d("How to Fish") },
    ["/g/How to Fish"] = { f("How to Fish.exe"), d("How to Fish_Data"), d("D3D12") },
  }
  check("root: nested depot -> the subfolder holding the game exe",
    fi.game_root("/g", entries, tree_fs(nested).list) == "/g/How to Fish")
  check("root: flat depot -> the install dir",
    fi.game_root("/g", entries, tree_fs({
      ["/g"] = { f("How to Fish.exe"), d("How to Fish_Data"), d("Mods") },
      ["/g/How to Fish_Data"] = {}, ["/g/Mods"] = {},
    }).list) == "/g")
  check("root: nothing matches anywhere -> the install dir",
    fi.game_root("/g", { { path = "SteamFix64.dll" } }, tree_fs(nested).list) == "/g")
  check("detect: missing dir / no fs -> not found",
    fi.detect_local("/nope", { fs = { list = function() error("x") end } }).found == false
      and fi.detect_local("", { fs = fake_fs({ "winmm.dll" }) }).found == false
      and fi.detect_local("/g", {}).found == false)
end

-- ── register (RPC shape, injected deps) ──────────────────────────────────────
do
  local reg = {}
  fi.register(reg)
  check("register: four RPCs", type(reg.LumenListFixArchives) == "function"
    and type(reg.LumenInstallFixArchive) == "function"
    and type(reg.LumenRevertFixInstall) == "function"
    and type(reg.LumenDetectLocalFix) == "function")
  local dec_det = json.decode(reg.LumenDetectLocalFix({ appid = 123456, installPath = "/nowhere" }))
  check("register: uninstalled game reports no fix",
    dec_det.success == true and dec_det.found == false)
  local dec = json.decode(reg.LumenRevertFixInstall({ appid = 123 }))
  check("register: revert with no record no-ops", dec.success == true and dec.reverted == false)
  -- The bridge sorts {appid, archivePath, contentScriptQuery, installPath}:
  -- the 4th positional value is the install-path hint, and a hint that is
  -- not the game's own folder must be refused.
  local saved_su = package.loaded.steam_utils
  package.loaded.steam_utils = { get_game_install_path_response = function()
    return { success = true, installPath = "/games/real" } end }
  local dec_inst = json.decode(reg.LumenInstallFixArchive(
    123, (os.getenv("HOME") or "") .. "/fix.zip", "", "/games/other"))
  package.loaded.steam_utils = saved_su
  check("register: positional install refuses a foreign install path",
    dec_inst.success == false and dec_inst.errorCode == "invalid_destination")
end

-- ── real end-to-end (skips without a 7-zip binary) ─────────────────────────
local bin = fi.find_7z()
if not bin then
  io.write("(e2e skipped: no 7-zip binary)\n")
else
  local tmp = "/tmp/lumen_fixinstall_e2e"
  local game, dl, store = tmp .. "/game", tmp .. "/dl", tmp .. "/store"
  os.execute("rm -rf -- " .. q(tmp))
  os.execute("mkdir -p -- " .. q(game) .. " " .. q(dl) .. " " .. q(store))

  -- a "game" with files one of which the fix overwrites
  os.execute("mkdir -p -- " .. q(game .. "/sub"))
  write_file(game .. "/untouched.txt", "GAME")
  write_file(game .. "/keep_me.txt", "ORIGINAL")
  write_file(game .. "/sub/replace_me.dll", "ORIGINAL-DLL")

  -- a "fix archive": one new file at root, one replacing sub/replace_me.dll,
  -- one in a nested dir the game does not have
  local src = tmp .. "/fixroot"
  os.execute("mkdir -p -- " .. q(src) .. " " .. q(src .. "/sub") .. " " .. q(src .. "/deep"))
  write_file(src .. "/added_fix.dll", "FIX-NEW")
  write_file(src .. "/sub/replace_me.dll", "FIX-REPLACED")
  write_file(src .. "/deep/nested.txt", "FIX-NESTED")
  local zip = dl .. "/testfix.zip"
  check("e2e: test archive created",
    os.execute(q(bin) .. " a -tzip " .. q(zip) .. " " .. q(src) .. "/* >/dev/null 2>&1") == true)

  -- the listing parser against REAL 7-zip output
  local pipe = io.popen(q(bin) .. " l -ba -slt -- " .. q(zip), "r")
  local text = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end
  local real = fi.safe_entries(fi.parse_7z_listing(text))
  check("e2e: listing parsed from real 7-zip output",
    real ~= nil and #real == 3
    and (function() for _, e in ipairs(real) do
      if e.path ~= "added_fix.dll" and e.path ~= "sub/replace_me.dll"
        and e.path ~= "deep/nested.txt" then return false end
    end return true end)())

  local deps = {
    home = tmp,
    resolve_install = function() return { success = true, installPath = game } end,
    store_root = function() return store end,
    bin = bin,
  }
  local r = fi.install(4312190, zip, game, deps)
  check("e2e: install succeeds", r.success == true and r.added == 2 and r.replaced == 1)
  check("e2e: files landed",
    read_file(game .. "/added_fix.dll") == "FIX-NEW"
      and read_file(game .. "/deep/nested.txt") == "FIX-NESTED"
      and read_file(game .. "/sub/replace_me.dll") == "FIX-REPLACED")
  check("e2e: untouched game file intact", read_file(game .. "/untouched.txt") == "GAME")
  local man = json.decode(read_file(store .. "/4312190/manifest.json") or "{}")
  check("e2e: manifest recorded", #man.added == 2 and #man.replaced == 1
    and man.replaced[1] == "sub/replace_me.dll")
  local rv = fi.revert(4312190, { store_root = function() return store end })
  check("e2e: revert removes added files and asks Steam for the replaced one",
    rv.reverted == true and rv.removed == 2 and rv.replacedCount == 1
      and rv.needsVerify == true
      and read_file(game .. "/added_fix.dll") == nil
      and read_file(game .. "/deep/nested.txt") == nil
      and read_file(game .. "/untouched.txt") == "GAME")
  check("e2e: a folder only the fix brought is removed, game folders stay",
    os.execute("test -d " .. q(game .. "/deep")) ~= true
      and os.execute("test -d " .. q(game .. "/sub")) == true)
  check("e2e: revert drops the record", read_file(store .. "/4312190/manifest.json") == nil)
  check("e2e: revert is a no-op without a record",
    fi.revert(4312190, { store_root = function() return store end }).reverted == false)

  local bad_home = fi.install(4312190, "/somewhere/else/testfix.zip", game, deps)
  check("e2e: archive outside home refused", bad_home.success == false
    and bad_home.errorCode == "invalid_archive")
  local bad_hint = fi.install(4312190, zip, game .. "/../wrong", deps)
  check("e2e: install-path hint mismatch refused", bad_hint.success == false
    and bad_hint.errorCode == "invalid_destination")
  local bad_notinstalled = fi.install(4312190, zip, game, {
    home = tmp, resolve_install = function() return { success = false } end,
    store_root = function() return store end, bin = bin,
  })
  check("e2e: not-installed refused", bad_notinstalled.success == false
    and bad_notinstalled.errorCode == "not_installed")

  local function manifest() return json.decode(read_file(store .. "/4312190/manifest.json") or "{}") end
  local function archive(name, files, flags)
    local d = tmp .. "/src_" .. name
    os.execute("rm -rf -- " .. q(d) .. " && mkdir -p -- " .. q(d))
    for p, body in pairs(files) do write_file(d .. "/" .. p, body) end
    local out = dl .. "/" .. name
    os.execute("cd " .. q(d) .. " && " .. q(bin) .. " a " .. (flags or "") .. " " .. q(out)
      .. " . >/dev/null 2>&1")
    return out
  end

  -- A second install reverts the first, but the game file the first one
  -- overwrote still holds fix content, so Unfix must still offer verify.
  fi.install(4312190, zip, game, deps)
  local other = archive("other.zip", { ["other_fix.dll"] = "OTHER" })
  check("e2e: a second install keeps the first one's overwritten files listed",
    fi.install(4312190, other, game, deps).success == true
      and manifest().replaced[1] == "sub/replace_me.dll"
      and read_file(game .. "/added_fix.dll") == nil)
  check("e2e: ...so its revert still asks for verify",
    fi.revert(4312190, deps).needsVerify == true)

  -- On a nested depot the second archive can pick another game root; the
  -- first one's overwritten exe must stay recorded.
  local nested = tmp .. "/nested"
  os.execute("mkdir -p -- " .. q(nested .. "/G"))
  write_file(nested .. "/G/G.exe", "GAME-EXE")
  local nested_deps = { home = tmp, bin = bin, store_root = deps.store_root,
    resolve_install = function() return { success = true, installPath = nested } end }
  local exe_fix = archive("exe_fix.zip", { ["G.exe"] = "FIX-EXE" })
  local dll_fix = archive("dll_fix.zip", { ["SteamFix64.dll"] = "FIX" })
  fi.install(4312190, exe_fix, nested, nested_deps)
  fi.install(4312190, dll_fix, nested, nested_deps)
  check("e2e: an overwritten file stays recorded when the next install picks another root",
    manifest().installPath == nested and manifest().replaced[1] == "G.exe"
      and fi.revert(4312190, nested_deps).needsVerify == true)

  local wrong = archive("wrong.zip", { ["half_fix.dll"] = "HALF" }, "-tzip -p" .. q("some-password"))
  local wr = fi.install(4312190, wrong, game, deps)
  check("e2e: an encrypted archive fails instead of waiting for a password; it stays recorded, so Un-fix can clean it up",
    wr.success == false and wr.errorCode == "extract_failed"
      and manifest().added[1] == "half_fix.dll")
  fi.revert(4312190, deps)

  write_file(tmp .. "/outside.txt", "KEEP")
  os.execute("mkdir -p -- " .. q(store .. "/4312190"))
  write_file(store .. "/4312190/manifest.json", json.encode({
    installPath = game, added = { "../outside.txt" }, replaced = {} }))
  check("e2e: a tampered record never deletes outside the game folder",
    fi.revert(4312190, deps).reverted == false and read_file(tmp .. "/outside.txt") == "KEEP")

  os.execute("rm -rf -- " .. q(tmp))
end

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
