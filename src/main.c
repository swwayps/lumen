/* Lumen entrypoint: boot Lua, expose ./lua/ modules, run the injector loop. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Statically-linked C modules: declare their openers. LuaSocket's core
 * (luaopen_socket_core) registers tcp/udp/select + sleep/gettime directly into
 * the module table, so we expose it as the "socket" module — the injector only
 * uses socket.tcp() and socket.sleep(), both present in the core table. */
int luaopen_socket_core(lua_State *L);
int luaopen_cjson(lua_State *L);
int luaopen_lfs(lua_State *L);
int luaopen_lumen_http(lua_State *L);

int main(int argc, char **argv) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* Preload the C modules so require("socket")/require("cjson") resolve
     * without any .so files on disk. */
    luaL_requiref(L, "socket", luaopen_socket_core, 0);
    lua_pop(L, 1);
    luaL_requiref(L, "cjson", luaopen_cjson, 0);
    lua_pop(L, 1);
    luaL_requiref(L, "lfs", luaopen_lfs, 0);
    lua_pop(L, 1);
    luaL_requiref(L, "lumen_http", luaopen_lumen_http, 0);
    lua_pop(L, 1);

    /* Make the bundled lua/ directory importable. For the spike we resolve it
     * relative to the working dir or an env override. */
    const char *luadir = getenv("LUMEN_LUA_DIR");
    if (!luadir) luadir = "lua";
    char setpath[1024];
    snprintf(setpath, sizeof(setpath),
             "package.path = '%s/?.lua;' .. package.path", luadir);
    if (luaL_dostring(L, setpath) != LUA_OK) {
        fprintf(stderr, "lumen: failed to set package.path: %s\n",
                lua_tostring(L, -1));
        return 1;
    }

    /* Generic test runner: `lumen --test <path>` dofiles a test script with the
     * binary's C modules (lfs/cjson/socket) available. */
    if (argc > 2 && strcmp(argv[1], "--test") == 0) {
        if (luaL_dofile(L, argv[2]) != LUA_OK) {
            fprintf(stderr, "lumen: %s\n", lua_tostring(L, -1));
            return 1;
        }
        lua_close(L);
        return 0;
    }

    /* Debug: `lumen --eval "<expr>"` evaluates JS in SharedJSContext. */
    if (argc > 2 && strcmp(argv[1], "--eval") == 0) {
        setenv("LUMEN_EVAL_EXPR", argv[2], 1);
        char epath[1024];
        snprintf(epath, sizeof(epath), "%s/../tools/eval_shared.lua", luadir);
        if (luaL_dofile(L, epath) != LUA_OK) {
            fprintf(stderr, "lumen: %s\n", lua_tostring(L, -1));
            return 1;
        }
        lua_close(L);
        return 0;
    }

    /* Default mode: load the LuaTools backend behind the shims and run the
     * injector loop (lua/boot.lua). */
    char bootpath[1024];
    snprintf(bootpath, sizeof(bootpath), "%s/boot.lua", luadir);
    if (luaL_dofile(L, bootpath) != LUA_OK) {
        fprintf(stderr, "lumen: %s\n", lua_tostring(L, -1));
        return 1;
    }
    lua_close(L);
    return 0;
}
