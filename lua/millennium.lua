-- millennium shim: replaces the Millennium native module. Only the 5 functions
-- the backend uses. add_browser_css/js enqueue files for the CDP injector
-- (Phase 3 consumes the queue); steam_path resolves the Steam install root.
local fs = require("fs")
local millennium = {}

local browser_css = {}
local browser_js = {}

function millennium.add_browser_css(path) browser_css[#browser_css + 1] = path end
function millennium.add_browser_js(path)  browser_js[#browser_js + 1] = path end

-- Exposed so the injector (Phase 3) can read what to inject.
function millennium.queued_css() return browser_css end
function millennium.queued_js()  return browser_js end

function millennium.version() return os.getenv("LUMEN_VERSION") or "lumen-dev" end

function millennium.ready() return true end

function millennium.steam_path()
  local home = os.getenv("HOME") or ""
  local candidates = {
    home .. "/.steam/steam",
    home .. "/.local/share/Steam",
    home .. "/.steam/debian-installation",
  }
  for _, p in ipairs(candidates) do
    if fs.exists(p) then return p end
  end
  return candidates[1]
end

return millennium
