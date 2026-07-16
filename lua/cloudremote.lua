-- cloudremote: enumerate REMOTE cloud-save app folders for the Cloud Saves tab.
--
-- The Cloud Saves list merges local storage (cloudsettings.list_apps) with the
-- games that exist in the user's cloud. This module ports the minimal slice of
-- CloudRedirect's Google Drive + OneDrive providers needed to list the app-id
-- folders under a Steam account, plus the OAuth token refresh — talking to the
-- SAME cloud layout the hook uses: root "CloudRedirect" / <steamAccountId> /
-- <appId>. Read-only; no writes and no save-blob downloads.
--
-- The hook itself is 32-bit and file-based on Linux, so this never touches the
-- hook; it just re-reads the same refresh token and hits the provider's REST
-- API over the http shim. Pure helpers (body/URL/response parsing) are split
-- from the IO so the multi-step flows stay host-testable with a fake http.
local json = require("json")

local cloudremote = {}

-- Public client credentials — the same clasp/rclone IDs the hook and flatpak
-- ship (not account-specific), reused verbatim.
local PROV = {
  gdrive = {
    client_id = "1072944905499-vm2v2i5dvn0a0d2o4ca36i1vge8cvbn0.apps.googleusercontent.com",
    client_secret = "v6V3fKV_zWU7iw1DrpO1rknX",
    token_url = "https://oauth2.googleapis.com/token",
    scope = nil,
  },
  onedrive = {
    client_id = "b15665d9-eda6-4092-8539-0eec376afd59",
    client_secret = "qtyfaBBYA403=unZUP40~_#",
    token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    scope = "Files.ReadWrite offline_access",
  },
}

local GDRIVE_FOLDER_MIME = "application/vnd.google-apps.folder"

-- ── pure helpers ────────────────────────────────────────────────────────────

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

function cloudremote.build_refresh_body(provider, refresh_token)
  local p = PROV[provider]
  if not p then return nil end
  local parts = {
    "client_id=" .. urlencode(p.client_id),
    "client_secret=" .. urlencode(p.client_secret),
    "refresh_token=" .. urlencode(refresh_token),
    "grant_type=refresh_token",
  }
  if p.scope then parts[#parts + 1] = "scope=" .. urlencode(p.scope) end
  return table.concat(parts, "&")
end

function cloudremote.parse_access_token(body)
  local ok, t = pcall(json.decode, body or "")
  if not ok or type(t) ~= "table" then return nil end
  local at = t.access_token
  if type(at) == "string" and at ~= "" then return at end
  return nil
end

local function logical_stats(files, honor_persist_state)
  if type(files) ~= "table" then return nil end
  local count, size = 0, 0
  for _, entry in pairs(files) do
    if type(entry) == "table" then
      local persisted = not honor_persist_state or entry.ps == nil or tonumber(entry.ps) == 0
      if persisted then
        count = count + 1
        local bytes = tonumber(entry.size)
        if bytes and bytes >= 0 then size = size + bytes end
      end
    end
  end
  return { files = count, size = size }
end

function cloudremote.parse_state_stats(body)
  local ok, state = pcall(json.decode, body or "")
  if not ok or type(state) ~= "table" then return nil end
  return logical_stats(state.files, true)
end

function cloudremote.parse_manifest_stats(body)
  local ok, manifest = pcall(json.decode, body or "")
  if not ok or type(manifest) ~= "table" then return nil end
  return logical_stats(manifest, false)
end

-- Google Drive files.list query for folders named `name` under `parent_id`
-- (or Drive root when parent_id is nil/empty). Returned UNENCODED.
function cloudremote.gdrive_query(name, parent_id)
  local esc = function(s) return (tostring(s):gsub("\\", "\\\\"):gsub("'", "\\'")) end
  local q = "name='" .. esc(name) .. "' and mimeType='" .. GDRIVE_FOLDER_MIME ..
    "' and trashed=false"
  if parent_id and parent_id ~= "" then
    q = q .. " and '" .. esc(parent_id) .. "' in parents"
  else
    q = q .. " and 'root' in parents"
  end
  return q
end

-- Query listing every child of a folder (folders + files); we filter to folders.
function cloudremote.gdrive_children_query(parent_id)
  local esc = (tostring(parent_id):gsub("\\", "\\\\"):gsub("'", "\\'"))
  return "'" .. esc .. "' in parents and trashed=false"
end

-- parse_drive_folder_entries(body) -> {{id,name}...}, next_page_token(or nil)
function cloudremote.parse_drive_folder_entries(body)
  local ok, j = pcall(json.decode, body or "")
  if not ok or type(j) ~= "table" then return {}, nil end
  local entries = {}
  for _, f in ipairs(j.files or {}) do
    if f.mimeType == GDRIVE_FOLDER_MIME and f.name then
      entries[#entries + 1] = { id = f.id, name = f.name }
    end
  end
  local tok = j.nextPageToken
  if tok == "" then tok = nil end
  return entries, tok
end

-- parse_drive_folders(body) -> {names...}, next_page_token(or nil)
function cloudremote.parse_drive_folders(body)
  local entries, tok = cloudremote.parse_drive_folder_entries(body)
  local names = {}
  for _, entry in ipairs(entries) do names[#names + 1] = entry.name end
  return names, tok
end

-- parse_onedrive_folder_entries(body) -> {{name}...}, next_link(or nil)
function cloudremote.parse_onedrive_folder_entries(body)
  local ok, j = pcall(json.decode, body or "")
  if not ok or type(j) ~= "table" then return {}, nil end
  local entries = {}
  for _, it in ipairs(j.value or {}) do
    if it.folder ~= nil and it.name then entries[#entries + 1] = { name = it.name } end
  end
  return entries, j["@odata.nextLink"]
end

-- parse_onedrive_folders(body) -> {names...}, next_link(or nil)
function cloudremote.parse_onedrive_folders(body)
  local entries, next_link = cloudremote.parse_onedrive_folder_entries(body)
  local names = {}
  for _, entry in ipairs(entries) do names[#names + 1] = entry.name end
  return names, next_link
end

-- ── IO layer ────────────────────────────────────────────────────────────────

local function resolve_http(deps)
  deps = deps or {}
  return deps.http or require("http")
end

-- Refresh the access token for a provider. Returns access_token or nil, err.
local function get_access_token(http, provider, refresh_token)
  local p = PROV[provider]
  if not p then return nil, "unknown provider" end
  if type(refresh_token) ~= "string" or refresh_token == "" then
    return nil, "no refresh token"
  end
  local body = cloudremote.build_refresh_body(provider, refresh_token)
  local r, herr = http.post(p.token_url, body, {
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    timeout = 30,
  })
  if not r then return nil, "token request failed: " .. tostring(herr) end
  if r.status and r.status >= 400 then
    return nil, "token refresh HTTP " .. tostring(r.status)
  end
  local at = cloudremote.parse_access_token(r.body)
  if not at then return nil, "no access token in response" end
  return at
end

local function gdrive_get(http, token, url)
  return http.get(url, { headers = { ["Authorization"] = "Bearer " .. token }, timeout = 30 })
end

-- Find a Drive folder id by name under a parent (nil parent = Drive root).
local function gdrive_find_folder(http, token, name, parent_id)
  local q = cloudremote.gdrive_query(name, parent_id)
  local url = "https://www.googleapis.com/drive/v3/files?q=" .. urlencode(q) ..
    "&fields=" .. urlencode("files(id,name,mimeType)") .. "&pageSize=10"
  local r = gdrive_get(http, token, url)
  if not r or r.status ~= 200 then return nil end
  local ok, j = pcall(json.decode, r.body or "")
  if not ok or type(j) ~= "table" or not j.files or not j.files[1] then return nil end
  return j.files[1].id
end

local function gdrive_list_app_folders(http, token, account_id)
  local root = gdrive_find_folder(http, token, "CloudRedirect", nil)
  if not root then return {} end -- no CloudRedirect folder yet => nothing remote
  local acct = gdrive_find_folder(http, token, tostring(account_id), root)
  if not acct then return {} end
  local folders, page = {}, nil
  repeat
    local q = cloudremote.gdrive_children_query(acct)
    local url = "https://www.googleapis.com/drive/v3/files?q=" .. urlencode(q) ..
      "&fields=" .. urlencode("nextPageToken,files(id,name,mimeType)") .. "&pageSize=1000"
    if page then url = url .. "&pageToken=" .. urlencode(page) end
    local r = gdrive_get(http, token, url)
    if not r or r.status ~= 200 then break end
    local entries, nexttok = cloudremote.parse_drive_folder_entries(r.body)
    for _, entry in ipairs(entries) do folders[#folders + 1] = entry end
    page = nexttok
  until not page
  return folders
end

local function onedrive_list_app_folders(http, token, account_id)
  local folders = {}
  local url = "https://graph.microsoft.com/v1.0/me/drive/root:/CloudRedirect/" ..
    tostring(account_id) .. ":/children?$select=name,folder&$top=1000"
  repeat
    local r = http.get(url, { headers = { ["Authorization"] = "Bearer " .. token }, timeout = 30 })
    if not r then break end
    if r.status == 404 then return {} end -- account folder absent => nothing remote
    if r.status ~= 200 then break end
    local entries, nextlink = cloudremote.parse_onedrive_folder_entries(r.body)
    for _, entry in ipairs(entries) do folders[#folders + 1] = entry end
    url = nextlink
  until not url
  return folders
end

local METADATA_PRIORITY = {
  "state.cloudredirect",
  "manifest.cloudredirect",
  "manifest.dat",
}

local function parse_metadata_stats(name, body)
  if name == "state.cloudredirect" then
    return cloudremote.parse_state_stats(body)
  end
  return cloudremote.parse_manifest_stats(body)
end

local function gdrive_read_stats(http, token, folder_id)
  local metadata, page = {}, nil
  repeat
    local q = cloudremote.gdrive_children_query(folder_id)
    local url = "https://www.googleapis.com/drive/v3/files?q=" .. urlencode(q) ..
      "&fields=" .. urlencode("nextPageToken,files(id,name,mimeType)") .. "&pageSize=100"
    if page then url = url .. "&pageToken=" .. urlencode(page) end
    local r = gdrive_get(http, token, url)
    if not r or r.status ~= 200 then break end
    local ok, j = pcall(json.decode, r.body or "")
    if not ok or type(j) ~= "table" then break end
    for _, file in ipairs(j.files or {}) do
      if file.id and file.name then metadata[file.name] = file.id end
    end
    page = j.nextPageToken
    if page == "" then page = nil end
  until not page

  for _, name in ipairs(METADATA_PRIORITY) do
    local id = metadata[name]
    if id then
      local url = "https://www.googleapis.com/drive/v3/files/" .. urlencode(id) .. "?alt=media"
      local r = gdrive_get(http, token, url)
      if r and r.status == 200 then
        local stats = parse_metadata_stats(name, r.body)
        if stats then return stats end
      end
    end
  end
  return { files = 0, size = 0 }
end

local function onedrive_get(http, token, url)
  return http.get(url, { headers = { ["Authorization"] = "Bearer " .. token }, timeout = 30 })
end

local function onedrive_read_stats(http, token, account_id, appid)
  local base = "https://graph.microsoft.com/v1.0/me/drive/root:/CloudRedirect/" ..
    tostring(account_id) .. "/" .. tostring(appid)
  local metadata = {}
  local url = base .. ":/children?$select=name,file&$top=100"
  repeat
    local r = onedrive_get(http, token, url)
    if not r or r.status ~= 200 then break end
    local ok, j = pcall(json.decode, r.body or "")
    if not ok or type(j) ~= "table" then break end
    for _, file in ipairs(j.value or {}) do
      if file.file ~= nil and file.name then metadata[file.name] = true end
    end
    url = j["@odata.nextLink"]
  until not url

  for _, name in ipairs(METADATA_PRIORITY) do
    if metadata[name] then
      local r = onedrive_get(http, token, base .. "/" .. name .. ":/content")
      if r and r.status == 200 then
        local stats = parse_metadata_stats(name, r.body)
        if stats then return stats end
      end
    end
  end
  return { files = 0, size = 0 }
end

local function numeric_app_folders(folders)
  local apps, seen = {}, {}
  for _, folder in ipairs(folders) do
    local id = math.tointeger(tonumber(folder.name))
    -- Skip the account-scope folder (appId 0), where the hook stores account-
    -- wide data (stats.json) rather than a real game's saves.
    if id and id ~= 0 and not seen[id] then
      seen[id] = true
      apps[#apps + 1] = { appid = id, folder = folder }
    end
  end
  table.sort(apps, function(a, b) return a.appid < b.appid end)
  return apps
end

local function local_appid_set(local_appids)
  local set = {}
  for _, id in ipairs(local_appids or {}) do
    local n = math.tointeger(tonumber(id))
    if n then set[n] = true end
  end
  return set
end

-- list_apps(provider, refresh_token, account_id, local_appids[, deps]) ->
-- {{appid,files,size}...} or nil, err. Remote metadata is fetched only for
-- AppIDs that are not present in local_appids.
function cloudremote.list_apps(provider, refresh_token, account_id, local_appids, deps)
  if provider ~= "gdrive" and provider ~= "onedrive" then
    return nil, "unsupported provider"
  end
  local http = resolve_http(deps)
  local token, terr = get_access_token(http, provider, refresh_token)
  if not token then return nil, terr end

  local folders
  if provider == "gdrive" then
    folders = gdrive_list_app_folders(http, token, account_id)
  else
    folders = onedrive_list_app_folders(http, token, account_id)
  end

  local local_set = local_appid_set(local_appids)
  local apps = {}
  for _, entry in ipairs(numeric_app_folders(folders)) do
    local stats = { files = 0, size = 0 }
    if not local_set[entry.appid] then
      if provider == "gdrive" then
        stats = gdrive_read_stats(http, token, entry.folder.id)
      else
        stats = onedrive_read_stats(http, token, account_id, entry.appid)
      end
    end
    apps[#apps + 1] = {
      appid = entry.appid,
      files = stats.files,
      size = stats.size,
    }
  end
  return apps
end

-- list_appids(provider, refresh_token, account_id[, deps]) -> {appid(number)...}
-- or nil, err. `deps.http` is injectable for tests.
function cloudremote.list_appids(provider, refresh_token, account_id, deps)
  if provider ~= "gdrive" and provider ~= "onedrive" then
    return nil, "unsupported provider"
  end
  local http = resolve_http(deps)
  local token, terr = get_access_token(http, provider, refresh_token)
  if not token then return nil, terr end

  local folders
  if provider == "gdrive" then
    folders = gdrive_list_app_folders(http, token, account_id)
  else
    folders = onedrive_list_app_folders(http, token, account_id)
  end

  local appids = {}
  for _, entry in ipairs(numeric_app_folders(folders)) do appids[#appids + 1] = entry.appid end
  return appids
end

return cloudremote
