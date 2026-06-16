-- Resolves Steam's CEF remote-debugging port. slsteam-moon rewrites Steam's
-- hard-coded 8080 to a free loopback port and writes it to the contract file
-- ~/.local/share/Lumen/cef_port. The injector reads it from here; if the file
-- is absent or invalid we fall back to 8080 (vanilla Steam / slsteam-moon off).
local cefport = {}

cefport.FALLBACK = 8080

-- Path of the contract file slsteam-moon writes ("" if HOME unset).
function cefport.contract_path()
  local home = os.getenv("HOME") or ""
  if home == "" then return "" end
  return home .. "/.local/share/Lumen/cef_port"
end

-- parse_port(s) -> integer in [1024,65535] or nil. Tolerates surrounding
-- whitespace / trailing newline; rejects non-integers and out-of-range values.
function cefport.parse_port(s)
  if type(s) ~= "string" then return nil end
  local n = tonumber(s)
  if not n then return nil end
  if n < 1024 or n > 65535 then return nil end
  if n ~= math.floor(n) then return nil end
  return math.floor(n)
end

-- resolve(read_fn, fallback) -> port, from_file
--   read_fn  : function returning the file's contents (string) or nil.
--   fallback : port to use when the file is missing/invalid (default 8080).
-- read_fn errors are caught and treated as "no file".
function cefport.resolve(read_fn, fallback)
  fallback = fallback or cefport.FALLBACK
  local ok, content = pcall(read_fn)
  if ok and content then
    local p = cefport.parse_port(content)
    if p then return p, true end
  end
  return fallback, false
end

-- read_contract() -> contents of the contract file, or nil. Plain io so the
-- pure logic above stays testable without a filesystem.
function cefport.read_contract()
  local path = cefport.contract_path()
  if path == "" then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*l")
  f:close()
  return s
end

return cefport
