-- Regression coverage for slsteam-moon notifications in Steam's Gamepad UI.
-- Run: LUMEN_LUA_DIR=lua ./bin/lumen --test tools/test_gamepad_notify.lua

package.path = "lua/?.lua;" .. package.path

local json = require("json")
local injector = require("injector")
local queue = require("notifyqueue")

local failures = 0
local function check(name, cond)
  if cond then print("ok:   " .. name)
  else print("FAIL: " .. name); failures = failures + 1 end
end

-- Detect the Steam UI mode, never a distribution name. This covers SteamOS,
-- Bazzite, ChimeraOS and ordinary Big Picture sessions using the same client.
check("Steam Big Picture title is Gamepad UI",
  injector.targets_have_gamepad_ui({
    { title = "Steam Big Picture Mode", url = "https://steamloopback.host/" },
  }))
check("IN_GAMEPADUI target is Gamepad UI",
  injector.targets_have_gamepad_ui({
    { title = "Steam", url = "https://steamloopback.host/?IN_GAMEPADUI=true" },
  }))
check("IN_GAMESCOPE target is Gamepad UI",
  injector.targets_have_gamepad_ui({
    { title = "Steam", url = "https://steamloopback.host/?IN_GAMESCOPE=true" },
  }))
check("desktop shell is not Gamepad UI",
  not injector.targets_have_gamepad_ui({
    { title = "Steam", url = "https://steamloopback.host/?browserType=4" },
    { title = "SharedJSContext", url = "https://steamloopback.host/routes/steamweb" },
  }))
check("Big Picture shell marks the Steam UI ready",
  injector.targets_ui_ready({
    { title = "Steam Big Picture Mode", url = "about:blank?browserType=4" },
  }))
check("Quick Access popup marks the Steam UI ready",
  injector.targets_ui_ready({
    { title = "QuickAccess_uid2", url = "about:blank?browserviewpopup=1" },
  }))
check("SharedJSContext alone is not a ready shell",
  not injector.targets_ui_ready({
    { title = "SharedJSContext", url = "https://steamloopback.host/routes/steamweb" },
  }))

local valid = queue.decode_event(json.encode({
  version = 1,
  created_ms = 100000,
  title = "SLSsteam-moon",
  body = "Ready",
  timeout_ms = 10000,
}), 105000)
check("fresh queue event is accepted",
  valid and valid.title == "SLSsteam-moon" and valid.body == "Ready")
check("timeout is preserved", valid and valid.timeout_ms == 10000)

check("stale queue event is rejected",
  queue.decode_event(json.encode({
    version = 1, created_ms = 1000, title = "x", body = "y", timeout_ms = 10000,
  }), 200000) == nil)
check("future-dated queue event is rejected",
  queue.decode_event(json.encode({
    version = 1, created_ms = 300000, title = "x", body = "y", timeout_ms = 10000,
  }), 200000) == nil)
check("oversized body is rejected",
  queue.decode_event(json.encode({
    version = 1, created_ms = 100000, title = "x", body = string.rep("z", 5000), timeout_ms = 10000,
  }), 105000) == nil)
check("invalid timeout is rejected",
  queue.decode_event(json.encode({
    version = 1, created_ms = 100000, title = "x", body = "y", timeout_ms = -1,
  }), 105000) == nil)
check("malformed JSON is rejected", queue.decode_event("not json", 105000) == nil)

-- drain() consumes only complete *.json files, returns valid events in stable
-- filename order, removes stale/invalid files, and leaves producer temp files.
local dir = "/tmp/lumen-notify-test-" .. tostring(math.random(100000, 999999))
lfs = require("lfs")
lfs.mkdir(dir)
local function write(name, body)
  local f = assert(io.open(dir .. "/" .. name, "wb")); f:write(body); f:close()
end
write("event-2.json", json.encode({
  version = 1, created_ms = 100000, title = "second", body = "b", timeout_ms = 10000,
}))
write("event-1.json", json.encode({
  version = 1, created_ms = 100000, title = "first", body = "a", timeout_ms = 10000,
}))
write("event-stale.json", json.encode({
  version = 1, created_ms = 1, title = "stale", body = "x", timeout_ms = 10000,
}))
write(".event-partial.tmp", "{")
local drained = queue.drain(dir, 200000)
check("drain returns complete fresh events", #drained == 2)
check("drain uses stable filename order",
  drained[1] and drained[1].title == "first" and drained[2].title == "second")
check("drain removes consumed event", lfs.attributes(dir .. "/event-1.json") == nil)
check("drain removes rejected event", lfs.attributes(dir .. "/event-stale.json") == nil)
check("drain leaves producer temp file", lfs.attributes(dir .. "/.event-partial.tmp") ~= nil)
os.remove(dir .. "/.event-partial.tmp")
lfs.rmdir(dir)

if failures > 0 then
  error(tostring(failures) .. " check(s) failed")
end
print("ALL PASS")
