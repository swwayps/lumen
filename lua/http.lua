-- http shim: maps the backend's m_http.get/head/post/request onto lumen_http.
-- Response table shape the backend expects: { status = <int>, body = <string> }.
local core = require("lumen_http")
local http = {}

-- The C binding (curl_slist) only understands an ARRAY of "Key: Value" strings.
-- The LuaTools backend, mirroring Millennium's m_http, passes a key->value MAP
-- (e.g. { ["User-Agent"] = "..." }). Translate maps to the array form so the
-- header actually reaches the wire; otherwise UA-gated APIs (TwentyTwo Cloud)
-- reject every request with 401. Array entries (numeric keys) pass through.
local function normalize_headers(headers)
  if type(headers) ~= "table" then return headers end
  local arr = {}
  for k, v in pairs(headers) do
    if type(k) == "number" then
      arr[#arr + 1] = tostring(v)
    else
      arr[#arr + 1] = tostring(k) .. ": " .. tostring(v)
    end
  end
  return arr
end

local function request_options(url, options, method, body)
  options = options or {}
  return {
    url = url,
    method = method or options.method or "GET",
    body = body or options.data,
    headers = normalize_headers(options.headers),
    timeout = options.timeout or 30,
    follow_redirects = options.follow_redirects,
    https_only = options.https_only,
    max_bytes = options.max_bytes,
  }
end

local function perform(url, options, method, body)
  local r, err = core.perform(request_options(url, options, method, body))
  if os.getenv("LUMEN_HTTP_DEBUG") then
    io.stderr:write("[lumen-http] " .. (method or "GET") .. " " .. tostring(url) ..
      " -> " .. (r and ("status=" .. tostring(r.status)) or ("nil err=" .. tostring(err))) .. "\n")
    io.stderr:flush()
  end
  return r, err
end

function http.get(url, options)  return perform(url, options, options and options.method or "GET") end
function http.head(url, options) return perform(url, options, "HEAD") end
function http.post(url, data, options) return perform(url, options, "POST", data) end

-- Non-blocking request used by the browser gateway. Progress is made by
-- repeatedly calling poll(); ordinary backend callers keep the synchronous API.
function http.start(url, options)
  options = options or {}
  return core.start(request_options(url, options, options.method or "GET", options.data))
end

function http.poll(request)
  return core.poll(request)
end

-- request{ url=, method=, headers=, data=, timeout= }
function http.request(opts)
  opts = opts or {}
  return perform(opts.url, opts, opts.method, opts.data)
end

return http
