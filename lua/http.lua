-- http shim: maps the backend's m_http.get/head/post/request onto lumen_http.
-- Response table shape the backend expects: { status = <int>, body = <string> }.
local core = require("lumen_http")
local http = {}

local function perform(url, options, method, body)
  options = options or {}
  return core.perform({
    url = url,
    method = method or options.method or "GET",
    body = body or options.data,
    headers = options.headers,
    timeout = options.timeout or 30,
  })
end

function http.get(url, options)  return perform(url, options, options and options.method or "GET") end
function http.head(url, options) return perform(url, options, "HEAD") end
function http.post(url, data, options) return perform(url, options, "POST", data) end

-- request{ url=, method=, headers=, data=, timeout= }
function http.request(opts)
  opts = opts or {}
  return perform(opts.url, opts, opts.method, opts.data)
end

return http
