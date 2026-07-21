/* lumen_http: minimal libcurl easy/multi binding.
 * Lua:
 *   lumen_http.perform{...} -> response | nil, error
 *   lumen_http.start{...}   -> request | nil, error
 *   lumen_http.poll(request)-> false
 *                            | true, response
 *                            | true, nil, error
 *
 * Request options:
 *   url=, method=, body=, headers={..}, timeout=,
 *   follow_redirects=, https_only=, max_bytes=
 *
 * Response:
 *   { status=, body=, content_type=, redirect_url=, effective_url= }
 */
#include <lua.h>
#include <lauxlib.h>
#include <curl/curl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ASYNC_META "lumen_http.async_request"

struct membuf {
    char *data;
    size_t len;
    size_t max;
    int overflow;
};

struct transfer {
    CURL *easy;
    struct membuf body;
    struct curl_slist *headers;
    char *url;
    char *method;
    char *upload;
    size_t upload_len;
    char error[CURL_ERROR_SIZE];
};

struct async_request {
    struct transfer transfer;
    CURLM *multi;
    int finished;
};

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *ud) {
    struct membuf *m = (struct membuf *)ud;
    if (size != 0 && nmemb > SIZE_MAX / size) {
        m->overflow = 1;
        return 0;
    }
    size_t add = size * nmemb;
    if (m->len > m->max || add > m->max - m->len ||
        m->len > SIZE_MAX - add - 1) {
        m->overflow = 1;
        return 0;
    }
    char *next = realloc(m->data, m->len + add + 1);
    if (!next) return 0;
    m->data = next;
    memcpy(m->data + m->len, ptr, add);
    m->len += add;
    m->data[m->len] = '\0';
    return add;
}

static void transfer_cleanup(struct transfer *t) {
    if (t->easy) curl_easy_cleanup(t->easy);
    if (t->headers) curl_slist_free_all(t->headers);
    free(t->body.data);
    free(t->url);
    free(t->method);
    free(t->upload);
    memset(t, 0, sizeof(*t));
}

static int copy_lua_string(lua_State *L, int index, char **out, size_t *len) {
    size_t n = 0;
    const char *value = lua_tolstring(L, index, &n);
    char *copy = malloc(n + 1);
    if (!copy) return 0;
    memcpy(copy, value, n);
    copy[n] = '\0';
    *out = copy;
    if (len) *len = n;
    return 1;
}

static const char *transfer_init(lua_State *L, int table_index,
                                 struct transfer *t) {
    memset(t, 0, sizeof(*t));
    table_index = lua_absindex(L, table_index);

    lua_getfield(L, table_index, "url");
    if (!lua_isstring(L, -1)) {
        lua_pop(L, 1);
        return "url must be a string";
    }
    if (!copy_lua_string(L, -1, &t->url, NULL)) {
        lua_pop(L, 1);
        return "out of memory";
    }
    lua_pop(L, 1);

    lua_getfield(L, table_index, "method");
    if (lua_isstring(L, -1)) {
        if (!copy_lua_string(L, -1, &t->method, NULL)) {
            lua_pop(L, 1);
            return "out of memory";
        }
    } else {
        t->method = strdup("GET");
        if (!t->method) {
            lua_pop(L, 1);
            return "out of memory";
        }
    }
    lua_pop(L, 1);

    lua_getfield(L, table_index, "body");
    if (lua_isstring(L, -1) &&
        !copy_lua_string(L, -1, &t->upload, &t->upload_len)) {
        lua_pop(L, 1);
        return "out of memory";
    }
    lua_pop(L, 1);

    lua_getfield(L, table_index, "timeout");
    long timeout = lua_isnumber(L, -1) ? (long)lua_tointeger(L, -1) : 30;
    lua_pop(L, 1);
    if (timeout <= 0) timeout = 30;

    lua_getfield(L, table_index, "follow_redirects");
    int follow_redirects = lua_isnil(L, -1) ? 1 : lua_toboolean(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, table_index, "https_only");
    int https_only = lua_toboolean(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, table_index, "max_bytes");
    lua_Integer requested_max = lua_isnumber(L, -1) ? lua_tointeger(L, -1) : 0;
    lua_pop(L, 1);
    t->body.max = requested_max > 0 ? (size_t)requested_max : SIZE_MAX;

    lua_getfield(L, table_index, "headers");
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            if (lua_isstring(L, -1)) {
                struct curl_slist *next =
                    curl_slist_append(t->headers, lua_tostring(L, -1));
                if (!next) {
                    lua_pop(L, 2);
                    return "out of memory";
                }
                t->headers = next;
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    t->easy = curl_easy_init();
    if (!t->easy) return "curl_easy_init failed";
    t->error[0] = '\0';

#define SETOPT(option, value) do {                                      \
    CURLcode setopt_rc = curl_easy_setopt(t->easy, option, value);      \
    if (setopt_rc != CURLE_OK) return curl_easy_strerror(setopt_rc);    \
} while (0)

    SETOPT(CURLOPT_URL, t->url);
    SETOPT(CURLOPT_NOSIGNAL, 1L);
    SETOPT(CURLOPT_FOLLOWLOCATION, follow_redirects ? 1L : 0L);
    if (https_only) {
        SETOPT(CURLOPT_PROTOCOLS_STR, "https");
        SETOPT(CURLOPT_REDIR_PROTOCOLS_STR, "https");
    }
    SETOPT(CURLOPT_TIMEOUT, timeout);
    SETOPT(CURLOPT_WRITEFUNCTION, write_cb);
    SETOPT(CURLOPT_WRITEDATA, &t->body);
    SETOPT(CURLOPT_ERRORBUFFER, t->error);
    if (t->headers) SETOPT(CURLOPT_HTTPHEADER, t->headers);
    if (strcmp(t->method, "HEAD") == 0) {
        SETOPT(CURLOPT_NOBODY, 1L);
    } else if (strcmp(t->method, "POST") == 0) {
        SETOPT(CURLOPT_POST, 1L);
        SETOPT(CURLOPT_POSTFIELDS, t->upload ? t->upload : "");
        SETOPT(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)t->upload_len);
    } else if (strcmp(t->method, "GET") != 0) {
        SETOPT(CURLOPT_CUSTOMREQUEST, t->method);
    }
#undef SETOPT

    return NULL;
}

static int push_transfer_result(lua_State *L, struct transfer *t, CURLcode rc) {
    if (rc != CURLE_OK) {
        lua_pushnil(L);
        if (t->body.overflow) {
            lua_pushstring(L, "response exceeds max_bytes");
        } else if (t->error[0] != '\0') {
            lua_pushstring(L, t->error);
        } else {
            lua_pushstring(L, curl_easy_strerror(rc));
        }
        return 2;
    }

    long status = 0;
    char *content_type = NULL;
    char *redirect_url = NULL;
    char *effective_url = NULL;
    curl_easy_getinfo(t->easy, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_getinfo(t->easy, CURLINFO_CONTENT_TYPE, &content_type);
    curl_easy_getinfo(t->easy, CURLINFO_REDIRECT_URL, &redirect_url);
    curl_easy_getinfo(t->easy, CURLINFO_EFFECTIVE_URL, &effective_url);

    lua_newtable(L);
    lua_pushinteger(L, status);
    lua_setfield(L, -2, "status");
    lua_pushlstring(L, t->body.data ? t->body.data : "", t->body.len);
    lua_setfield(L, -2, "body");
    if (content_type) {
        lua_pushstring(L, content_type);
        lua_setfield(L, -2, "content_type");
    }
    if (redirect_url) {
        lua_pushstring(L, redirect_url);
        lua_setfield(L, -2, "redirect_url");
    }
    if (effective_url) {
        lua_pushstring(L, effective_url);
        lua_setfield(L, -2, "effective_url");
    }
    return 1;
}

static int l_perform(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    struct transfer transfer;
    const char *init_err = transfer_init(L, 1, &transfer);
    if (init_err) {
        transfer_cleanup(&transfer);
        lua_pushnil(L);
        lua_pushstring(L, init_err);
        return 2;
    }
    CURLcode rc = curl_easy_perform(transfer.easy);
    int results = push_transfer_result(L, &transfer, rc);
    transfer_cleanup(&transfer);
    return results;
}

static int l_async_gc(lua_State *L) {
    struct async_request *request =
        (struct async_request *)luaL_checkudata(L, 1, ASYNC_META);
    if (request->multi) {
        if (request->transfer.easy)
            curl_multi_remove_handle(request->multi, request->transfer.easy);
        curl_multi_cleanup(request->multi);
        request->multi = NULL;
    }
    transfer_cleanup(&request->transfer);
    request->finished = 1;
    return 0;
}

static int l_start(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    /* Build the transfer in its final userdata storage. libcurl keeps raw
     * pointers to body/error buffers configured by transfer_init(); creating
     * it on the stack and copying the struct would leave those pointers aimed
     * at dead stack memory for the lifetime of the asynchronous request. */
    struct async_request *request =
        (struct async_request *)lua_newuserdatauv(L, sizeof(*request), 0);
    memset(request, 0, sizeof(*request));
    const char *init_err = transfer_init(L, 1, &request->transfer);
    if (init_err) {
        transfer_cleanup(&request->transfer);
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushstring(L, init_err);
        return 2;
    }

    CURLM *multi = curl_multi_init();
    if (!multi) {
        transfer_cleanup(&request->transfer);
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushstring(L, "curl_multi_init failed");
        return 2;
    }
    CURLMcode add_rc = curl_multi_add_handle(multi, request->transfer.easy);
    if (add_rc != CURLM_OK) {
        curl_multi_cleanup(multi);
        transfer_cleanup(&request->transfer);
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushstring(L, curl_multi_strerror(add_rc));
        return 2;
    }

    request->multi = multi;
    luaL_getmetatable(L, ASYNC_META);
    lua_setmetatable(L, -2);
    return 1;
}

static int l_poll(lua_State *L) {
    struct async_request *request =
        (struct async_request *)luaL_checkudata(L, 1, ASYNC_META);
    if (request->finished || !request->multi || !request->transfer.easy) {
        lua_pushboolean(L, 1);
        lua_pushnil(L);
        lua_pushstring(L, "request already completed");
        return 3;
    }

    int running = 0;
    CURLMcode multi_rc;
    do {
        multi_rc = curl_multi_perform(request->multi, &running);
    } while (multi_rc == CURLM_CALL_MULTI_PERFORM);
    if (multi_rc != CURLM_OK) {
        lua_pushboolean(L, 1);
        lua_pushnil(L);
        lua_pushstring(L, curl_multi_strerror(multi_rc));
        l_async_gc(L);
        return 3;
    }

    CURLcode result = CURLE_OK;
    int complete = 0;
    int remaining = 0;
    CURLMsg *message;
    while ((message = curl_multi_info_read(request->multi, &remaining)) != NULL) {
        if (message->msg == CURLMSG_DONE &&
            message->easy_handle == request->transfer.easy) {
            result = message->data.result;
            complete = 1;
            break;
        }
    }
    if (!complete) {
        lua_pushboolean(L, 0);
        return 1;
    }

    curl_multi_remove_handle(request->multi, request->transfer.easy);
    curl_multi_cleanup(request->multi);
    request->multi = NULL;
    lua_pushboolean(L, 1);
    int results = push_transfer_result(L, &request->transfer, result);
    transfer_cleanup(&request->transfer);
    request->finished = 1;
    return 1 + results;
}

static const luaL_Reg fns[] = {
    { "perform", l_perform },
    { "start", l_start },
    { "poll", l_poll },
    { NULL, NULL },
};

int luaopen_lumen_http(lua_State *L) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    if (luaL_newmetatable(L, ASYNC_META)) {
        lua_pushcfunction(L, l_async_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    luaL_newlib(L, fns);
    return 1;
}
