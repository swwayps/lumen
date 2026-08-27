/* lumen_privfs: create files and directories that only their owner can touch.
 *
 * Lua's io.open cannot express O_EXCL or O_NOFOLLOW, and its mode is whatever
 * the process umask leaves of 0666. That matters for the files Lumen writes and
 * then EXECUTES (the update / auto-fix scripts handed to a terminal) and for the
 * files that hold secrets (OAuth refresh tokens):
 *
 *   * without O_NOFOLLOW, a symlink pre-created at the destination redirects the
 *     write onto its target;
 *   * without O_EXCL, an attacker who pre-creates the file keeps ownership, so
 *     it can rewrite the contents between our write and the terminal's exec;
 *   * without an explicit mode, a token file is briefly world-readable before a
 *     later chmod narrows it.
 *
 * Lua:
 *   lumen_privfs.write(path, data, mode) -> true | nil, errmsg
 *   lumen_privfs.mkdir(path, mode)       -> true | nil, errmsg
 *   lumen_privfs.is_private_dir(path)    -> true | false, reason
 */
#include <lua.h>
#include <lauxlib.h>

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int push_errno(lua_State *L, const char *what) {
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", what, strerror(errno));
    return 2;
}

/* write(path, data [, mode]) — fails if the path already exists (O_EXCL) or is a
 * symlink (O_NOFOLLOW). Mode defaults to 0600 and is applied at creation, not
 * after, so there is no window in which the file is more permissive. */
static int fs_write(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    size_t len = 0;
    const char *data = luaL_checklstring(L, 2, &len);
    lua_Integer mode = luaL_optinteger(L, 3, 0600);

    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                  (mode_t)mode);
    if (fd < 0) return push_errno(L, "open");

    /* The umask does not apply to an explicit fchmod, so ask for the mode again:
     * open() intersects with the umask, which would otherwise strip the owner
     * execute bit we need for a script. */
    if (fchmod(fd, (mode_t)mode) != 0) {
        int saved = errno;
        close(fd);
        unlink(path);
        errno = saved;
        return push_errno(L, "fchmod");
    }

    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, data + written, len - written);
        if (n < 0) {
            if (errno == EINTR) continue;
            int saved = errno;
            close(fd);
            unlink(path);
            errno = saved;
            return push_errno(L, "write");
        }
        written += (size_t)n;
    }
    if (close(fd) != 0) {
        int saved = errno;
        unlink(path);
        errno = saved;
        return push_errno(L, "close");
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* mkdir(path [, mode]) — creates the directory with an explicit mode. An
 * existing directory is reported as EEXIST so the caller can decide whether it
 * is acceptable (is_private_dir answers that). */
static int fs_mkdir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_Integer mode = luaL_optinteger(L, 2, 0700);
    if (mkdir(path, (mode_t)mode) != 0) return push_errno(L, "mkdir");
    /* Same reason as above: mkdir intersects the requested mode with the umask. */
    if (chmod(path, (mode_t)mode) != 0) return push_errno(L, "chmod");
    lua_pushboolean(L, 1);
    return 1;
}

/* is_private_dir(path) -> true | false, reason
 * A usable private directory is a real directory (not a symlink), owned by us,
 * and inaccessible to group and others. */
static int fs_is_private_dir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    struct stat st;
    if (lstat(path, &st) != 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "missing");
        return 2;
    }
    if (S_ISLNK(st.st_mode)) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "symlink");
        return 2;
    }
    if (!S_ISDIR(st.st_mode)) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "not a directory");
        return 2;
    }
    if (st.st_uid != geteuid()) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "wrong owner");
        return 2;
    }
    if (st.st_mode & (S_IRWXG | S_IRWXO)) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "accessible to others");
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static const luaL_Reg privfs[] = {
    { "write", fs_write },
    { "mkdir", fs_mkdir },
    { "is_private_dir", fs_is_private_dir },
    { NULL, NULL },
};

int luaopen_lumen_privfs(lua_State *L) {
    luaL_newlib(L, privfs);
    return 1;
}
