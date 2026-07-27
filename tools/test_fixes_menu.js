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
  "08-about-tab.js", "09-overlay.js", "10-fixes-menu.js", "12-cloud-tab.js",
  "13-sls-check.js", "11-menubar.js",
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
const authConfiguredFromStatus = win.__lumenRyuuConfiguredFromStatus;
const crackCardState = win.__lumenFixesCrackCardState;
const authExpired = win.__lumenFixesAuthExpired;

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

// ── Ryuu authentication UI ──────────────────────────────────────────────────
// The bearer secret is never returned to JavaScript; only its configured state
// reaches the card/settings UI.
if (typeof authConfiguredFromStatus !== "function") {
  console.error("FAIL Ryuu auth status helper is not exposed");
  failures++;
} else {
  eq("Ryuu status: configured", authConfiguredFromStatus({
    success: true, configured: true, kind: "session",
  }), true);
  eq("Ryuu status: absent", authConfiguredFromStatus({ success: true }), false);
  eq("Ryuu status: malformed", authConfiguredFromStatus(null), false);
}

if (typeof crackCardState !== "function") {
  console.error("FAIL Crack/Bypass card-state helper is not exposed");
  failures++;
} else {
  const S = {
    crackDesc: "normal", ryuuAuthRequired: "auth", authRequiredBadge: "Needs auth",
    unavailable: "Unavailable", nativeWarnShort: "native",
  };
  const needs = crackCardState({status: 200, requiresAuth: true, authConfigured: false}, true, false, S);
  eq("Crack card: missing auth remains clickable", needs.off, false);
  // The tile keeps its own identity: the key rides along with the badge, it does
  // not replace the wrench.
  eq("Crack card: keeps the wrench icon", needs.iconKey, "wrench");
  eq("Crack card: key icon sits on the badge", needs.badgeIcon, "key");
  eq("Crack card: warns before click", needs.badge, "Needs auth");
  eq("Crack card: missing auth explains requirement", needs.desc, "auth");

  const ready = crackCardState({status: 200, requiresAuth: true, authConfigured: true}, true, false, S);
  eq("Crack card: configured uses wrench", ready.iconKey, "wrench");
  eq("Crack card: configured has no badge", ready.badge, null);
  eq("Crack card: configured has no key on the badge", ready.badgeIcon, null);
  // The badge must come back on its own once the stored session is gone again.
  const expired = crackCardState({status: 200, requiresAuth: true, authConfigured: false}, true, false, S);
  eq("Crack card: badge returns when the session expires", expired.badge, "Needs auth");
  eq("Crack card: key returns with it", expired.badgeIcon, "key");
}

// ── in-client sign-in view ──────────────────────────────────────────────────
// The panel turns into a sign-in view and polls. The anonymous cookie Ryuu
// issues before the Discord step reads as "waiting" (see ryuulogin.poll_state),
// so the view must only leave that state on a verified session, a real error, or
// the deadline — never because a cookie merely appeared.
const authViewState = win.__lumenFixesAuthViewState;
if (typeof authViewState !== "function") {
  console.error("FAIL sign-in view state helper is not exposed");
  failures++;
} else {
  const LIMIT = 180000;
  eq("view: verified session", authViewState({ ok: true, state: "configured" }, 5000, LIMIT), "configured");
  eq("view: still waiting", authViewState({ ok: true, state: "waiting" }, 5000, LIMIT), "waiting");
  eq("view: backend error", authViewState({ ok: true, state: "error" }, 5000, LIMIT), "error");
  eq("view: deadline reached", authViewState({ ok: true, state: "waiting" }, LIMIT, LIMIT), "timeout");
  // A verified session on the last tick still wins over the deadline.
  eq("view: verified on the final tick", authViewState({ ok: true, state: "configured" }, LIMIT, LIMIT), "configured");
  eq("view: unreachable backend keeps waiting", authViewState(null, 5000, LIMIT), "waiting");
  eq("view: malformed reply keeps waiting", authViewState({ ok: false }, 5000, LIMIT), "waiting");
}

// Game Mode gets a plain notice, not a form: verified on a live gamescope
// session that the sign-in window cannot open there, and typing a 300-character
// cookie with a gamepad is not a real option. The credential is shared between
// modes, so the notice points at Desktop Mode instead.
const gameModeNotice = win.__lumenFixesGameModeNotice;
if (typeof gameModeNotice !== "function") {
  console.error("FAIL Game Mode notice helper is not exposed");
  failures++;
} else {
  const S = { authGameModeTitle: "no auth here", authGameModeBody: "go to desktop",
              authGotIt: "Got it" };
  const notice = gameModeNotice(S);
  eq("notice: own title", notice.title, "no auth here");
  eq("notice: explains the desktop route", notice.copy, "go to desktop");
  eq("notice: single dismissing action", notice.buttons.length, 1);
  eq("notice: that action is 'got it'", notice.buttons[0], "Got it");
  eq("notice: no paste form offered", notice.offersPaste, false);
  eq("notice: no polling started", notice.polls, false);
}

// A rejected session must be reported as expired authentication, never as the
// generic "corrupt archive" download failure the user originally hit.
if (typeof authExpired !== "function") {
  console.error("FAIL Ryuu auth-failure helper is not exposed");
  failures++;
} else {
  eq("Auth failure: typed 401 state", authExpired({ status: "failed", errorCode: "authentication" }), true);
  eq("Auth failure: typed apply rejection", authExpired({ errorCode: "authentication" }), true);
  eq("Auth failure: ordinary download failure", authExpired({ status: "failed", error: "corrupt" }), false);
  eq("Auth failure: success state", authExpired({ status: "done" }), false);
  eq("Auth failure: nullish", authExpired(null), false);
}

if (failures) { console.error("\n" + failures + " failed"); process.exit(1); }
console.log("\nall ok");
