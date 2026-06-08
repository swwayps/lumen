/* lumen_http: minimal libcurl easy-interface binding.
 * Lua: lumen_http.perform{ url=, method=, body=, headers={..}, timeout= }
 *   -> { status = <int>, body = <string> }  on success
 *   -> nil, "<error>"                        on failure
 */
#include <lua.h>
#include <lauxlib.h>
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>

struct membuf { char *data; size_t len; };

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *ud) {
    size_t add = size * nmemb;
    struct membuf *m = (struct membuf *)ud;
    char *p = realloc(m->data, m->len + add + 1);
    if (!p) return 0;
    m->data = p;
    memcpy(m->data + m->len, ptr, add);
    m->len += add;
    m->data[m->len] = '\0';
    return add;
}

static int l_perform(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "url");
    const char *url = luaL_checkstring(L, -1);
    lua_getfield(L, 1, "method");
    const char *method = lua_isstring(L, -1) ? lua_tostring(L, -1) : "GET";
    lua_getfield(L, 1, "body");
    const char *body = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
    size_t body_len = body ? strlen(body) : 0;
    lua_getfield(L, 1, "timeout");
    long timeout = lua_isnumber(L, -1) ? (long)lua_tointeger(L, -1) : 30;

    CURL *c = curl_easy_init();
    if (!c) { lua_pushnil(L); lua_pushstring(L, "curl_easy_init failed"); return 2; }

    struct membuf mb = { NULL, 0 };
    struct curl_slist *hdrs = NULL;

    lua_getfield(L, 1, "headers");
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            /* headers as an array of "Key: Value" strings */
            if (lua_isstring(L, -1)) hdrs = curl_slist_append(hdrs, lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    }

    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);          /* slsteam-moon lesson */
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, timeout);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &mb);
    if (hdrs) curl_easy_setopt(c, CURLOPT_HTTPHEADER, hdrs);
    if (strcmp(method, "HEAD") == 0) {
        curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
    } else if (strcmp(method, "POST") == 0) {
        curl_easy_setopt(c, CURLOPT_POST, 1L);
        curl_easy_setopt(c, CURLOPT_POSTFIELDS, body ? body : "");
        curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE, (long)body_len);
    } else if (strcmp(method, "GET") != 0) {
        curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, method);
    }

    CURLcode rc = curl_easy_perform(c);
    long status = 0;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);

    int nret;
    if (rc != CURLE_OK) {
        lua_pushnil(L);
        lua_pushstring(L, curl_easy_strerror(rc));
        nret = 2;
    } else {
        lua_newtable(L);
        lua_pushinteger(L, status); lua_setfield(L, -2, "status");
        lua_pushlstring(L, mb.data ? mb.data : "", mb.len); lua_setfield(L, -2, "body");
        nret = 1;
    }
    if (hdrs) curl_slist_free_all(hdrs);
    free(mb.data);
    curl_easy_cleanup(c);
    return nret;
}

static const luaL_Reg fns[] = { { "perform", l_perform }, { NULL, NULL } };

int luaopen_lumen_http(lua_State *L) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    luaL_newlib(L, fns);
    return 1;
}
