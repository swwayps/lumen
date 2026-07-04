-- Run: lua5.4 tools/test_cloudremote.lua
-- Remote save enumeration for the Cloud Saves tab (phase 2). Ports CloudRedirect's
-- Google Drive + OneDrive "list app-id folders under an account" and the OAuth
-- token refresh into Lua, talking to the same cloud folder layout the hook uses
-- (root "CloudRedirect" / <steamAccountId> / <appId>). Pure helpers + a fake
-- HTTP layer keep the multi-step flows host-testable (no live API).
package.path = "lua/?.lua;" .. package.path
local cr = require("cloudremote")
local json = require("json")

local function ok(c, m) if not c then error("FAIL: " .. (m or "")) end end
local function eq(g, w, m)
  if g ~= w then error("FAIL: " .. (m or "") .. " (got=" .. tostring(g) ..
    " want=" .. tostring(w) .. ")") end
end
local function has(arr, v)
  for _, x in ipairs(arr) do if tostring(x) == tostring(v) then return true end end
  return false
end

-- ── pure: refresh body ──────────────────────────────────────────────────────
do
  local g = cr.build_refresh_body("gdrive", "RT1")
  ok(g:find("grant_type=refresh_token", 1, true), "gdrive refresh grant")
  ok(g:find("refresh_token=RT1", 1, true), "gdrive refresh token")
  ok(g:find("client_id=", 1, true), "gdrive client id")
  ok(not g:find("scope=", 1, true), "gdrive refresh omits scope")
  local o = cr.build_refresh_body("onedrive", "RT2")
  ok(o:find("scope=", 1, true), "onedrive refresh includes scope")
end

-- ── pure: parse access token ────────────────────────────────────────────────
do
  eq(cr.parse_access_token('{"access_token":"AT","expires_in":3599}'), "AT", "parse access token")
  eq(cr.parse_access_token("garbage"), nil, "bad token body -> nil")
end

-- ── pure: parse Drive folder listing (folders only) ─────────────────────────
do
  local body = json.encode({ files = {
    { id = "a", name = "220200", mimeType = "application/vnd.google-apps.folder" },
    { id = "b", name = "readme.txt", mimeType = "text/plain" },
    { id = "c", name = "413150", mimeType = "application/vnd.google-apps.folder" },
  }, nextPageToken = "" })
  local folders, next_tok = cr.parse_drive_folders(body)
  ok(has(folders, "220200") and has(folders, "413150"), "drive folder names extracted")
  ok(not has(folders, "readme.txt"), "non-folders excluded")
  eq(next_tok, nil, "no next page token")
end

-- ── pure: parse OneDrive children (folder facet) ────────────────────────────
do
  local body = json.encode({ value = {
    { name = "620", folder = { childCount = 2 } },
    { name = "file.sav", file = { mimeType = "x" } },
    { name = "700", folder = { childCount = 0 } },
  }, ["@odata.nextLink"] = "https://graph/next" })
  local folders, nextlink = cr.parse_onedrive_folders(body)
  ok(has(folders, "620") and has(folders, "700"), "onedrive folder names extracted")
  ok(not has(folders, "file.sav"), "files excluded")
  eq(nextlink, "https://graph/next", "next link surfaced")
end

-- ── gdrive end-to-end flow with a fake HTTP layer ───────────────────────────
do
  local calls = {}
  local fake = {
    post = function(url, body, opts)
      calls[#calls + 1] = { m = "POST", url = url }
      ok(url:find("oauth2.googleapis.com/token", 1, true), "refresh posts to token endpoint")
      ok(body:find("refresh_token=RTgd", 1, true), "refresh uses stored token")
      return { status = 200, body = '{"access_token":"ATOK","expires_in":3599}' }
    end,
    get = function(url, opts)
      calls[#calls + 1] = { m = "GET", url = url }
      ok(opts and opts.headers and opts.headers["Authorization"] == "Bearer ATOK",
        "bearer token on API call")
      if url:find("CloudRedirect", 1, true) and url:find("root", 1, true) then
        return { status = 200, body = json.encode({ files = { { id = "ROOTID", name = "CloudRedirect",
          mimeType = "application/vnd.google-apps.folder" } } }) }
      elseif url:find("ROOTID", 1, true) then
        return { status = 200, body = json.encode({ files = { { id = "ACCTID", name = "1052518393",
          mimeType = "application/vnd.google-apps.folder" } } }) }
      elseif url:find("ACCTID", 1, true) then
        return { status = 200, body = json.encode({ files = {
          { id = "x", name = "220200", mimeType = "application/vnd.google-apps.folder" },
          { id = "y", name = "413150", mimeType = "application/vnd.google-apps.folder" },
        } }) }
      end
      return { status = 404, body = "{}" }
    end,
  }
  local appids, err = cr.list_appids("gdrive", "RTgd", 1052518393, { http = fake })
  ok(appids, "gdrive list_appids returned (" .. tostring(err) .. ")")
  ok(has(appids, 220200) and has(appids, 413150), "gdrive remote appids enumerated")
end

-- ── onedrive end-to-end flow ────────────────────────────────────────────────
do
  local fake = {
    post = function(url, body, opts)
      ok(url:find("login.microsoftonline.com", 1, true), "onedrive refresh endpoint")
      return { status = 200, body = '{"access_token":"OD","expires_in":3599}' }
    end,
    get = function(url, opts)
      ok(url:find("graph.microsoft.com", 1, true), "graph host")
      ok(url:find("CloudRedirect/720044628", 1, true), "children of the account folder")
      return { status = 200, body = json.encode({ value = {
        { name = "489830", folder = {} }, { name = "367520", folder = {} },
      } }) }
    end,
  }
  local appids = cr.list_appids("onedrive", "RTod", 720044628, { http = fake })
  ok(appids and has(appids, 489830) and has(appids, 367520), "onedrive remote appids enumerated")
end

-- ── auth failure surfaces an error, not a crash ─────────────────────────────
do
  local fake = { post = function() return { status = 400, body = '{"error":"invalid_grant"}' } end,
                 get = function() error("should not reach API without a token") end }
  local appids, err = cr.list_appids("gdrive", "BAD", 1, { http = fake })
  eq(appids, nil, "no appids on auth failure")
  ok(err ~= nil, "auth failure returns an error")
end

print("test_cloudremote: ALL PASS")
