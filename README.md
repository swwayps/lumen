# Lumen

A lightweight, millennium-less bridge for slsteam-moon: a single static Lua
binary that injects the LuaTools frontend through Steam's CEF remote-debugging
endpoint (CDP) and hosts the Lua backend over a loopback RPC.

## Build (portable, any x86_64 distro, glibc >= 2.34)
    scripts/_build-portable.sh    # outputs bin/lumen

## Optional tools
The Fixes Menu installs fixes from outside lua.tools with `7z`/`7zz` (archives;
the LuaTools plugin's 7zz is the fallback) and `innoextract` (FreeTP's setup .exe files).
Each is only needed for its source.

## Host unit tests
    lua5.4 tools/test_wsframe.lua && lua5.4 tools/test_cdp.lua && lua5.4 tools/test_inject.lua
