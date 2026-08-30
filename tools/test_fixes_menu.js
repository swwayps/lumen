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
// Same list, same order as boot.lua's MENU_PARTS: the test must bundle exactly
// what production bundles, or a syntax error in a fragment slips through.
const PARTS = [
  "01-core.js", "02-i18n.js", "03-styles.js", "04-overlay-helpers.js",
  "05-config-tab.js", "06-updates-helpers.js", "07-updates-tab.js",
  "08-about-tab.js", "09-luatools-account.js", "09-overlay.js",
  "10-auto-fix-status.js", "10-fixes-menu.js", "12-cloud-tab.js",
  "13-sls-check.js", "11-menubar.js",
];
const SOURCE = PARTS.map((p) => fs.readFileSync(path.join(MENU_DIR, p), "utf8")).join("\n");
const FIXES_SOURCE = fs.readFileSync(path.join(MENU_DIR, "10-fixes-menu.js"), "utf8");

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
const authExpired = win.__lumenFixesAuthExpired;
const groupCategories = win.__lumenFixesGroupCategories;
const defaultCategory = win.__lumenFixesDefaultCategory;
const newestRelease = win.__lumenFixesNewestRelease;
const officialIconKey = win.__lumenFixesOfficialIconKey;
const luaToolsIcon = win.__lumenFixesLuaToolsIcon;
const appliedStates = win.__lumenFixesAppliedStates;
const fallbackReceiptKind = win.__lumenFixesFallbackReceiptKind;
const catalogueFilter = win.__lumenLuaToolsFilterFixGames;
const normalizeCatalogueTag = win.__lumenLuaToolsNormalizeFixTag;
const displayFixTitle = win.__lumenLuaToolsFixDisplayTitle;
const formatFixDate = win.__lumenLuaToolsFormatFixDate;

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

// A source refusing the download must be reported as such, never as the generic
// "corrupt archive" failure the user originally hit.
if (typeof authExpired !== "function") {
  console.error("FAIL download auth-failure helper is not exposed");
  failures++;
} else {
  eq("Auth failure: typed 401 state", authExpired({ status: "failed", errorCode: "authentication" }), true);
  eq("Auth failure: typed apply rejection", authExpired({ errorCode: "authentication" }), true);
  eq("Auth failure: ordinary download failure", authExpired({ status: "failed", error: "corrupt" }), false);
  eq("Auth failure: success state", authExpired({ status: "done" }), false);
  eq("Auth failure: nullish", authExpired(null), false);
}

// ── official lua.tools category selector + shared receipt ───────────────────
if (typeof groupCategories !== "function" || typeof defaultCategory !== "function"
    || typeof newestRelease !== "function") {
  console.error("FAIL official category helpers are not exposed");
  failures++;
} else {
  const official = {
    recommended: { id: "v", category: "voices38" },
    fixes: [
      { id: "v", category: "voices38", title: "Voices" },
      { id: "b1", category: "bypass", title: "Bypass 1" },
      { id: "b2", category: "bypass", title: "Bypass 2" },
      { id: "o", category: "online_fix", title: "Online" },
    ],
  };
  const grouped = groupCategories(official.fixes);
  eq("categories: preserve ranked first-seen order", grouped.map((x) => x.key).join(","),
    "voices38,bypass,online_fix");
  eq("categories: keep every fix in a category", grouped[1].fixes.length, 2);
  eq("categories: recommended category is selected by default",
    defaultCategory(official, grouped), "voices38");
  eq("categories: a single category stays a static badge", groupCategories([
    { id: "only", category: "freetp" },
  ]).length, 1);
  const voicesOnly = groupCategories([
    { id: "old", category: "voices38", createdAt: "2026-06-12T00:00:00Z",
      tags: [{ slug: "voices38-crack" }] },
    { id: "new", category: "voices38", createdAt: "2026-06-15T00:00:00Z",
      tags: [{ slug: "steamtools-achievements-fix" }, { slug: "voices38-crack" }] },
    { id: "aux", category: "steamtools-achievements-fix",
      tags: [{ slug: "steamtools-achievements-fix" }] },
  ]);
  eq("categories: achievements metadata never becomes a selectable category",
    voicesOnly.map((x) => x.key).join(","), "voices38");
  eq("categories: auxiliary-only entries are not offered as standalone fixes",
    voicesOnly[0].fixes.length, 2);
  eq("categories: selected category always applies its newest release",
    newestRelease(voicesOnly[0].fixes).id, "new");
  eq("categories: equal timestamps preserve the official API order",
    newestRelease([
      { id: "official-first", createdAt: "2026-06-15T00:00:00Z" },
      { id: "official-second", createdAt: "2026-06-15T00:00:00Z" },
    ]).id, "official-first");
}

// The featured lua.tools action keeps the Steam identity in every state.
// Applied is communicated by the existing green receipt badge, never by
// replacing the primary icon with a checkmark.
if (typeof officialIconKey !== "function") {
  console.error("FAIL official Steam icon helper is not exposed");
  failures++;
} else {
  eq("official card: ready uses LuaTools icon", officialIconKey(false), "luatools");
  eq("official card: applied keeps LuaTools icon", officialIconKey(true), "luatools");
}

if (typeof luaToolsIcon !== "function") {
  console.error("FAIL LuaTools vector icon helper is not exposed");
  failures++;
} else {
  const icon = luaToolsIcon();
  const officialSteamPath = "M11.979 0C5.678 0 .511 4.86.022 11.037l6.432 2.658c.545-.371 1.203-.59 1.912-.59.063 0 .125.004.188.006l2.861-4.142V8.91c0-2.495 2.028-4.524 4.524-4.524 2.494 0 4.524 2.031 4.524 4.527s-2.03 4.525-4.524 4.525h-.105l-4.076 2.911c0 .052.004.105.004.159 0 1.875-1.515 3.396-3.39 3.396-1.635 0-3.016-1.173-3.331-2.727L.436 15.27C1.862 20.307 6.486 24 11.979 24c6.627 0 11.999-5.373 11.999-12S18.605 0 11.979 0zM7.54 18.21l-1.473-.61c.262.543.714.999 1.314 1.25 1.297.539 2.793-.076 3.332-1.375.263-.63.264-1.319.005-1.949s-.75-1.121-1.377-1.383c-.624-.26-1.29-.249-1.878-.03l1.523.63c.956.4 1.409 1.5 1.009 2.455-.397.957-1.497 1.41-2.454 1.012H7.54zm11.415-9.303c0-1.662-1.353-3.015-3.015-3.015-1.665 0-3.015 1.353-3.015 3.015 0 1.665 1.35 3.015 3.015 3.015 1.663 0 3.015-1.35 3.015-3.015zm-5.273-.005c0-1.252 1.013-2.266 2.265-2.266 1.249 0 2.266 1.014 2.266 2.266 0 1.251-1.017 2.265-2.266 2.265-1.253 0-2.265-1.014-2.265-2.265z";
  eq("official card: LuaTools icon is native SVG", icon.includes("<svg") && !icon.includes("<image"), true);
  eq("official card: LuaTools icon uses the supplied 24px Steam path",
    icon.includes('viewBox="0 0 24 24"') && icon.includes('d="' + officialSteamPath + '"'), true);
  eq("official card: Steam mark is rotated around the icon centre",
    icon.includes('transform="rotate(90 12 12)"'), true);
  eq("official card: monochrome state has a white knockout background",
    icon.includes('<circle cx="12" cy="12" r="12" fill="#fff"'), true);
  eq("official card: every logo layer shares one inset circular edge",
    icon.includes('<clipPath id="lumen-lt-logo-edge"><circle cx="12" cy="12" r="11.5"/></clipPath>') &&
      icon.includes('<g clip-path="url(#lumen-lt-logo-edge)">'), true);
  eq("official card: circular edge requests geometric precision",
    icon.includes('shape-rendering="geometricPrecision"'), true);
  eq("official card: state-coloured rings cover the white edge halo",
    icon.includes('<circle class="lumen-lt-logo-mono lumen-lt-logo-edge" cx="12" cy="12" r="11.55"') &&
      icon.includes('<circle class="lumen-lt-logo-brand lumen-lt-logo-edge" cx="12" cy="12" r="11.55"'), true);
  eq("official card: hover gradient uses the reference magenta-purple",
    icon.includes("#AC4EAD") && icon.includes("#670867"), true);
  eq("official card: monochrome and brand layers are distinct",
    icon.includes("lumen-lt-logo-mono") && icon.includes("lumen-lt-logo-brand"), true);
}
if (typeof appliedStates !== "function") {
  console.error("FAIL shared applied-state helper is not exposed");
  failures++;
} else {
  const states = appliedStates({ fallbackOnlineApplied: true, spacewarApplied: true });
  eq("fallback card reads its persisted receipt", states.fallbackOnline, true);
  eq("Spacewar card reads FakeAppIds state", states.spacewar, true);
  const emptyStates = appliedStates({});
  eq("missing applied flags stay false", emptyStates.fallbackOnline || emptyStates.spacewar, false);
}
eq("fallback apply uses a locale-independent receipt kind",
  typeof fallbackReceiptKind === "function" ? fallbackReceiptKind() : null,
  "online_fix_fallback");

const unfixBody = (FIXES_SOURCE.match(/function fxUnfix\([\s\S]*?\n  }/) || [""])[0];
eq("Unfix never starts a full Steam validation",
  unfixBody.includes("__lumenValidateApp"), false);

// ── Lumen Settings authenticated Fixes catalogue ────────────────────────────
if (typeof catalogueFilter !== "function") {
  console.error("FAIL Fixes catalogue filter helper is not exposed");
  failures++;
} else {
  const games = [
    { appid: 10, name: "Crimson Desert", tags: [
      { name: "DenuvOwO", slug: "denuvowo", color: "#a78bfa" },
      { name: "Generic", slug: "generic", color: "#ec4899" },
    ] },
    { appid: 20, name: "PRAGMATA", tags: [
      { name: "voices38 (crack)", slug: "voices38-crack", color: "#22c55e" },
    ] },
    { appid: 30, name: "UNO", tags: [
      { name: "Online Fix", slug: "online-fix", color: "#3b82f6" },
    ] },
  ];
  eq("settings catalogue: category chip filters by normalized tag",
    catalogueFilter(games, "", "online-fix").map((game) => game.appid).join(","), "30");
  eq("settings catalogue: search and category filters combine",
    catalogueFilter(games, "crimson", "generic").map((game) => game.appid).join(","), "10");
  eq("settings catalogue: search accepts AppID",
    catalogueFilter(games, "20", "").map((game) => game.appid).join(","), "20");
  eq("settings catalogue: malformed game collections stay empty",
    catalogueFilter(null, "", "").length, 0);
}
if (typeof normalizeCatalogueTag !== "function" || typeof displayFixTitle !== "function"
    || typeof formatFixDate !== "function") {
  console.error("FAIL Fixes detail presentation helpers are not exposed");
  failures++;
} else {
  const tag = normalizeCatalogueTag({ name: "Online Fix", slug: "online-fix", color: "#3b82f6" });
  eq("settings catalogue: object tag exposes its name", tag.label, "Online Fix");
  eq("settings catalogue: object tag exposes its slug", tag.key, "online-fix");
  eq("settings catalogue: object tag keeps a safe colour", tag.color, "#3b82f6");
  eq("settings detail: numeric release title gains Build prefix", displayFixTitle("24613230"), "Build 24613230");
  eq("settings detail: descriptive release title stays unchanged", displayFixTitle("Gang Beasts online"), "Gang Beasts online");
  eq("settings detail: release date is formatted in UTC", formatFixDate("1970-01-01T00:00:00.000Z", "en"), "1 Jan 1970");
}

eq("official card: content starts at the top instead of floating in empty space",
  SOURCE.includes("min-height:266px;padding:22px 20px;justify-content:flex-start;"), true);

if (failures) { console.error("\n" + failures + " failed"); process.exit(1); }
console.log("\nall ok");
