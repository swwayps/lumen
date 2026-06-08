# Lumen build. `make` builds bin/lumen on the host; scripts/_build-portable.sh
# runs the same target inside the glibc-2.34 container.
CC      ?= cc
LUA_CFLAGS := $(shell pkg-config --cflags lua5.4 2>/dev/null || echo -I/usr/include/lua5.4)

# Link liblua STATICALLY so the binary has no liblua runtime dependency (users'
# distros won't ship liblua5.4.so). glibc stays dynamic (static glibc is fragile,
# esp. getaddrinfo) with a 2.34 floor from the build container -> portable across
# distros without a Lua runtime dep. Fall back to dynamic -llua5.4 only if the
# static archive isn't found (host dev convenience).
LUA_LIBDIR := $(shell pkg-config --variable=libdir lua5.4 2>/dev/null)
LUA_A      := $(firstword $(wildcard $(LUA_LIBDIR)/liblua5.4.a) \
                          $(wildcard /usr/lib/x86_64-linux-gnu/liblua5.4.a) \
                          $(wildcard /usr/lib/liblua5.4.a))
ifeq ($(LUA_A),)
LUA_LIBS   := $(shell pkg-config --libs lua5.4 2>/dev/null || echo -llua5.4) -ldl
else
LUA_LIBS   := $(LUA_A) -ldl
endif

# Vendored C modules (pinned: LuaSocket 3.1.0, lua-cjson 2.1.0.10).
#   vendor/luasocket/*.c -> socket.core (Linux usocket backend)
#   vendor/lua-cjson/*.c -> cjson (system strtod/snprintf fpconv; no dtoa/g_fmt)
SOCKET_SRC := vendor/luasocket/luasocket.c vendor/luasocket/timeout.c \
              vendor/luasocket/buffer.c vendor/luasocket/io.c \
              vendor/luasocket/auxiliar.c vendor/luasocket/compat.c \
              vendor/luasocket/options.c vendor/luasocket/inet.c \
              vendor/luasocket/usocket.c vendor/luasocket/except.c \
              vendor/luasocket/select.c vendor/luasocket/tcp.c \
              vendor/luasocket/udp.c
CJSON_SRC  := vendor/lua-cjson/lua_cjson.c vendor/lua-cjson/strbuf.c \
              vendor/lua-cjson/fpconv.c

SRC        := src/main.c $(SOCKET_SRC) $(CJSON_SRC)

CFLAGS     := -O2 -DLUASOCKET_DEBUG -DNDEBUG \
              -Ivendor/luasocket -Ivendor/lua-cjson $(LUA_CFLAGS)

bin/lumen: $(SRC)
	mkdir -p bin
	$(CC) $(CFLAGS) $(SRC) -o bin/lumen $(LUA_LIBS) -lm
	@echo "built bin/lumen"

clean:
	rm -rf bin *.o

.PHONY: clean
