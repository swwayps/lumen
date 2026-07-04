// test_fixes_menu.js — pure helpers behind the library-page Fixes Menu
// (menu/10-fixes-menu.js): appid extraction from the focused game's asset URLs
// and the gear pick from action-row icon-button candidates. Both must be
// locale- and class-name-independent (Steam's classes are hashed).
// Run: node tools/test_fixes_menu.js
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const MENU_DIR = path.join(__dirname, "..", "lua", "menu");
const PARTS = [
  "01-core.js", "02-i18n.js", "03-styles.js", "04-overlay-helpers.js",
  "05-config-tab.js", "06-updates-helpers.js", "07-updates-tab.js",
  "08-about-tab.js", "09-overlay.js", "10-fixes-menu.js", "12-cloud-tab.js",
  "11-menubar.js",
];
const SOURCE = PARTS.map((p) => fs.readFileSync(path.join(MENU_DIR, p), "utf8")).join("\n");

// Minimal context: the menubar bootstrap calls document.querySelectorAll once;
// return [] so it no-ops. We only need the window-exposed pure helpers.
const win = {};
const ctx = {
  window: win,
  document: {
    querySelectorAll: () => [],
    getElementById: () => null,
    createElement: () => ({ style: {}, classList: { add() {}, remove() {} }, addEventListener() {}, appendChild() {}, querySelector() { return null; } }),
    addEventListener() {}, head: null, documentElement: null, body: null,
  },
  location: { hostname: "steamloopback.host" },
  navigator: { language: "pt-BR" },
  console: { log() {} },
  setTimeout: () => 0,
  clearTimeout: () => {},
  MutationObserver: class { observe() {} disconnect() {} },
};
vm.createContext(ctx);
vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });

let failures = 0;
function eq(name, got, want) {
  if (got === want) { console.log("ok   " + name); }
  else { console.error("FAIL " + name + ": got " + JSON.stringify(got) + " want " + JSON.stringify(want)); failures++; }
}

const appId = win.__lumenFixesAppIdFromImgs;
const pickGear = win.__lumenFixesPickGear;
const resolveName = win.__lumenFixesResolveName;
const allowed = win.__lumenFixesAppAllowed;

// ── appid extraction ────────────────────────────────────────────────────────
// Real-shaped library detail page: ONE hero + logo + capsule for the focused
// game (322330), surrounded by shelf header.jpg capsules of OTHER appids.
const REAL = [
  "https://steamloopback.host/assets/322330/abc/library_hero_blur.jpg?c=1",
  "https://steamloopback.host/assets/322330/abc/library_hero.jpg?c=1",
  "https://steamloopback.host/assets/322330/def/logo.png?c=1",
  "https://steamloopback.host/assets/322330/ghi/library_capsule.jpg?c=1",
  "https://steamloopback.host/assets/981700/header.jpg?c=2",
  "https://steamloopback.host/assets/974740/header.jpg?c=3",
];
eq("appid: hero wins over shelf headers", appId(REAL), 322330);
eq("appid: logo when no hero", appId([
  "https://steamloopback.host/assets/620/x/logo.png",
  "https://steamloopback.host/assets/440/header.jpg",
]), 620);
eq("appid: capsule when only capsule", appId([
  "https://steamloopback.host/assets/570/x/library_capsule.jpg",
]), 570);
eq("appid: shelf headers only -> null", appId([
  "https://steamloopback.host/assets/981700/header.jpg",
  "https://steamloopback.host/assets/974740/header.jpg",
]), null);
eq("appid: empty -> null", appId([]), null);

// ── gear pick ───────────────────────────────────────────────────────────────
// gear, info, heart sit left→right; the gear is the smallest x.
const G = { id: "gear" }, H = { id: "heart" };
eq("gear: leftmost of cluster", pickGear([{ el: H, x: 1216 }, { el: G, x: 1132 }]).el, G);
eq("gear: single candidate", pickGear([{ el: G, x: 1132 }]).el, G);
eq("gear: empty -> null", pickGear([]), null);

// ── banner name ───────────────────────────────────────────────────────────────
// Show a trusted name only; nothing (not "Unknown Game") when not installed.
eq("name: not installed -> empty", resolveName({ isInstalled: false, gameName: "" }, { gameName: "Unknown Game (322330)" }), "");
eq("name: not installed ignores fix name", resolveName({ isInstalled: false }, { gameName: "Darkest Dungeon" }), "");
eq("name: installed uses appmanifest name", resolveName({ isInstalled: true, gameName: "Darkest Dungeon" }, {}), "Darkest Dungeon");
eq("name: installed falls back to real fix name", resolveName({ isInstalled: true, gameName: "" }, { gameName: "Blasphemous 2" }), "Blasphemous 2");
eq("name: installed but only Unknown placeholder -> empty", resolveName({ isInstalled: true, gameName: "" }, { gameName: "Unknown Game (1)" }), "");
eq("name: nullish args -> empty", resolveName(null, null), "");

// ── LuaTools-added gate ───────────────────────────────────────────────────────
// The entry only shows for games present in the fetched added-set.
eq("allowed: appid in set", allowed(322330, { 322330: true, 620: true }), true);
eq("allowed: appid not in set", allowed(440, { 322330: true }), false);
eq("allowed: set null (still loading) -> false", allowed(322330, null), false);
eq("allowed: no appid -> false", allowed(null, { 322330: true }), false);
eq("allowed: empty set -> false", allowed(322330, {}), false);

if (failures) { console.error("\n" + failures + " failed"); process.exit(1); }
console.log("\nall ok");
