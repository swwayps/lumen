#!/usr/bin/env node

// Contract test: every static RPC invoked by the assembled Lumen menu must be
// reachable through the plugin allowlist, a native registry module, or an
// injector control relay. Otherwise the UI can only answer "unknown method".

const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const luaDir = path.join(root, "lua");

function read(file) {
  return fs.readFileSync(file, "utf8");
}

function matches(source, regex, group = 1) {
  return [...source.matchAll(regex)].map((match) => match[group]);
}

function luaSources(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return luaSources(full);
    return entry.isFile() && entry.name.endsWith(".lua") ? [read(full)] : [];
  });
}

const boot = read(path.join(luaDir, "boot.lua"));
const injector = read(path.join(luaDir, "injector.lua"));
const menu = fs.readdirSync(path.join(luaDir, "menu"))
  .filter((name) => name.endsWith(".js"))
  .sort()
  .map((name) => read(path.join(luaDir, "menu", name)))
  .join("\n");

const allowlistBlock = boot.match(/local ALLOWLIST\s*=\s*\{([\s\S]*?)\n\}/);
if (!allowlistBlock) throw new Error("plugin ALLOWLIST not found in lua/boot.lua");

const allowlisted = new Set(matches(allowlistBlock[1], /["']([^"']+)["']/g));
if (!boot.includes("lifecycle.rpc_methods")) {
  throw new Error("Lumen does not consume the plugin-owned RPC contract");
}
const registered = new Set(
  luaSources(luaDir).flatMap((source) =>
    matches(source, /registry\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*function\b/g),
  ),
);
const controls = new Set(matches(injector, /req\.fn\s*==\s*["']([^"']+)["']/g));

const calls = new Set([
  ...matches(menu, /(?:^|[^.A-Za-z0-9_])call\(\s*["']([^"']+)["']/gm),
  ...matches(menu, /(?:^|[^.A-Za-z0-9_])relay\(\s*["']([^"']+)["']/gm),
]);
const unexpectedDynamicCalls = menu.split("\n").filter((line) =>
  /(?:^|[^.A-Za-z0-9_])call\(\s*(?!["'])/.test(line)
  && !/^\s*(?:\/\/|\/\*|\*)/.test(line)
  && !/function\s+call\s*\(/.test(line)
  && !/call\(fn\)/.test(line),
);
const available = new Set([...allowlisted, ...registered, ...controls]);
const missing = [...calls].filter((name) => !available.has(name)).sort();

if (unexpectedDynamicCalls.length) {
  throw new Error(
    `Lumen menu has RPC method names the contract audit cannot resolve:\n${unexpectedDynamicCalls.join("\n")}`,
  );
}
if (missing.length) {
  throw new Error(
    `Lumen menu RPCs would return unknown method: ${missing.join(", ")}`,
  );
}

console.log(`ok   ${calls.size} Lumen menu RPC methods are registered`);
