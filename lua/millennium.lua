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
  -- Only accept a candidate that is a REAL, bootstrapped Steam root. Steam's
  -- launcher drops steam.sh at the data-dir root on first run; its presence
  -- means the dir is a genuine install and not an empty/phantom path. We must
  -- NOT return a non-existent path here: callers (e.g. copy_webkit_files) will
  -- mkdir under whatever we return, and creating ~/.steam/steam as a real
  -- directory blocks Valve's bootstrap (it needs to put a SYMLINK there),
  -- breaking Steam with "Couldn't set up Steam data".
  for _, p in ipairs(candidates) do
    if fs.exists(fs.join(p, "steam.sh")) then return p end
  end
  -- No bootstrapped Steam found. Return empty so callers skip rather than
  -- materializing a phantom directory.
  return ""
end

return millennium
