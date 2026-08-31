/* Lumen entrypoint: boot Lua, expose ./lua/ modules, run the injector loop. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

/* Statically-linked C modules: declare their openers. LuaSocket's core
 * (luaopen_socket_core) registers tcp/udp/select + sleep/gettime directly into
 * the module table, so we expose it as the "socket" module — the injector only
 * uses socket.tcp() and socket.sleep(), both present in the core table. */
int luaopen_socket_core(lua_State *L);
int luaopen_cjson(lua_State *L);
int luaopen_lfs(lua_State *L);
int luaopen_lumen_http(lua_State *L);
int luaopen_lumen_privfs(lua_State *L);

static int singleton_fd = -1;

static void print_usage(FILE *stream, const char *program) {
    fprintf(stream, "Usage: %s [--help | --test <path> | --eval <javascript>]\n",
            program);
}

/* Keep exactly one injector attached per desktop session. flock is released by
 * the kernel when the process exits, including crashes, so no stale PID cleanup
 * is needed. Tests isolate the lock naturally through XDG_RUNTIME_DIR. */
static int acquire_singleton(void) {
    char path[4096];
    const char *override = getenv("LUMEN_SINGLETON_LOCK");
    int length;
    if (override && *override) {
        if (*override != '/') {
            fprintf(stderr, "lumen: singleton lock override must be absolute\n");
            return -1;
        }
        length = snprintf(path, sizeof(path), "%s", override);
    } else {
        /* Derive the normal path from the uid, not XDG_RUNTIME_DIR: launchers
         * and terminals may carry different environment subsets. */
        length = snprintf(path, sizeof(path), "/run/user/%lu/lumen.lock",
                          (unsigned long)getuid());
    }
    if (length < 0 || (size_t)length >= sizeof(path)) {
        fprintf(stderr, "lumen: singleton lock path is too long\n");
        return -1;
    }

    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0 && (!override || !*override) && errno == ENOENT) {
        const char *home = getenv("HOME");
        if (!home || !*home) {
            fprintf(stderr, "lumen: cannot locate singleton lock directory\n");
            return -1;
        }
        length = snprintf(path, sizeof(path),
                          "%s/.local/share/Lumen/lumen.lock", home);
        if (length < 0 || (size_t)length >= sizeof(path)) {
            fprintf(stderr, "lumen: singleton lock path is too long\n");
            return -1;
        }
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    }
    if (fd < 0) {
        fprintf(stderr, "lumen: cannot open singleton lock: %s\n",
                strerror(errno));
        return -1;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid()) {
        fprintf(stderr, "lumen: refusing unsafe singleton lock\n");
        close(fd);
        return -1;
    }
    if (fchmod(fd, 0600) != 0) {
        fprintf(stderr, "lumen: cannot secure singleton lock: %s\n",
                strerror(errno));
        close(fd);
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK || errno == EAGAIN) {
            fprintf(stderr, "lumen: already running\n");
            close(fd);
            return 0;
        }
        fprintf(stderr, "lumen: cannot lock singleton file: %s\n",
                strerror(errno));
        close(fd);
        return -1;
    }

    if (ftruncate(fd, 0) == 0) dprintf(fd, "%ld\n", (long)getpid());
    singleton_fd = fd;
    return 1;
}

int main(int argc, char **argv) {
    enum { MODE_RUN, MODE_TEST, MODE_EVAL } mode = MODE_RUN;
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        print_usage(stdout, argv[0]);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--test") == 0) mode = MODE_TEST;
    else if (argc == 3 && strcmp(argv[1], "--eval") == 0) mode = MODE_EVAL;
    else if (argc != 1) {
        print_usage(stderr, argv[0]);
        return 2;
    }

    if (mode == MODE_RUN) {
        int lock_status = acquire_singleton();
        if (lock_status <= 0) return lock_status == 0 ? 0 : 1;
    }

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
    luaL_requiref(L, "lumen_privfs", luaopen_lumen_privfs, 0);
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
    if (mode == MODE_TEST) {
        if (luaL_dofile(L, argv[2]) != LUA_OK) {
            fprintf(stderr, "lumen: %s\n", lua_tostring(L, -1));
            return 1;
        }
        lua_close(L);
        return 0;
    }

    /* Debug: `lumen --eval "<expr>"` evaluates JS in SharedJSContext. */
    if (mode == MODE_EVAL) {
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
