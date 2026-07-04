// test_cloud_i18n.js — the "Cloud Saves" tab must follow the user's Steam
// language like the other Lumen tabs, be wired into the overlay switcher, and
// drive the LumenCloud* backend RPCs. Run: node tools/test_cloud_i18n.js
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

let fails = 0;
const fail = (m) => { console.error("FAIL: " + m); fails++; };
const okmsg = (m) => console.log("ok   " + m);

// 1) The cloud tab fragment must not hard-code the English cloud strings.
{
  const src = fs.readFileSync(path.join(MENU_DIR, "12-cloud-tab.js"), "utf8");
  if (/I18N\.en\.cloud/.test(src)) fail("12-cloud-tab.js hard-codes I18N.en.cloud");
  else okmsg("12-cloud-tab.js: no hardcoded English cloud strings");
  // Must define renderCloud and call the backend RPCs.
  if (!/function\s+renderCloud/.test(src)) fail("12-cloud-tab.js missing renderCloud()");
  for (const rpc of ["LumenCloudStatus", "LumenCloudSetProvider", "LumenCloudSetToggle",
                     "LumenCloudAuthorize", "LumenCloudAuthPoll", "LumenCloudSignOut",
                     "LumenCloudApps", "LumenCloudRemoteApps"]) {
    if (!src.includes(rpc)) fail("12-cloud-tab.js does not call " + rpc);
  }
  if (fails === 0) okmsg("12-cloud-tab.js defines renderCloud and calls all LumenCloud* RPCs");

  // A stats toggle must persist UNCONDITIONALLY (so turning it back off in the
  // same session writes false, never a stuck "on"); the restart modal only
  // shows on enable and must NOT gate the write. Assert the SetToggle write
  // comes before the `if (on)` modal in cloudStatsToggle.
  const m = src.match(/function\s+cloudStatsToggle[\s\S]*?\n {2}}/);
  if (!m) fail("12-cloud-tab.js missing cloudStatsToggle()");
  else {
    const fn = m[0];
    const writeAt = fn.indexOf("LumenCloudSetToggle");
    const ifOnAt = fn.search(/if\s*\(\s*on\s*\)/);
    if (writeAt === -1) fail("cloudStatsToggle doesn't write the toggle");
    else if (ifOnAt !== -1 && writeAt > ifOnAt)
      fail("cloudStatsToggle gates the write behind `if (on)` — disable wouldn't persist");
    else okmsg("cloudStatsToggle persists unconditionally; modal only on enable");
  }
}

// 2) The overlay must wire in the cloud tab (a selectTab("cloud") branch and a
//    renderCloud call).
{
  const ov = fs.readFileSync(path.join(MENU_DIR, "09-overlay.js"), "utf8");
  if (!/["']cloud["']/.test(ov)) fail("09-overlay.js has no 'cloud' tab branch");
  if (!/renderCloud\s*\(/.test(ov)) fail("09-overlay.js never calls renderCloud()");
  // The tab must be gated on CloudRedirect presence (window.__lumenCloud), so it
  // never appears — and nothing cloud runs — when the hook isn't installed.
  if (!/__lumenCloud[\s\S]{0,40}mkTab|tabCloud\s*=\s*window\.__lumenCloud/.test(ov))
    fail("09-overlay.js does not gate the Cloud tab on window.__lumenCloud");
  if (fails === 0) okmsg("09-overlay.js wires the cloud tab, gated on __lumenCloud");
}

// 3) Run the bundle and introspect the i18n table + a cloudStrings() picker.
function stubEl() {
  return { style: {}, classList: { add() {}, remove() {}, toggle() {} },
    appendChild() {}, addEventListener() {}, setAttribute() {}, remove() {},
    textContent: "", title: "", id: "", value: "" };
}
function ctxFor(lang) {
  const win = {};
  const ctx = {
    window: win,
    document: {
      getElementById: () => null,
      createElement: () => stubEl(),
      querySelectorAll: () => [],
      head: { appendChild() {} },
      body: { appendChild() {} },
      documentElement: { appendChild() {} },
      addEventListener() {}, removeEventListener() {},
    },
    location: { hostname: "steamloopback.host" },
    navigator: { language: lang },
    console: { log() {} },
    setTimeout: () => 0,
    clearTimeout: () => {},
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  return win;
}

const winPt = ctxFor("pt-BR");
const I = winPt.__lumenI18n;
const cloudStrings = winPt.__lumenCloudStrings;

if (!I || typeof cloudStrings !== "function") {
  console.error("FAIL: __lumenI18n / __lumenCloudStrings not exposed for introspection");
  process.exit(1);
}

const enCloud = I.en.cloud;
const ptCloud = I["pt-BR"] && I["pt-BR"].cloud;
if (!enCloud) { console.error("FAIL: en has no cloud block"); process.exit(1); }

if (!ptCloud) {
  fail("pt-BR has no cloud block");
} else {
  const missing = Object.keys(enCloud).filter((k) => !(k in ptCloud));
  if (missing.length) fail("pt-BR cloud missing keys: " + missing.join(", "));
  else okmsg(`pt-BR cloud has all ${Object.keys(enCloud).length} keys`);

  const empty = Object.keys(ptCloud).filter((k) => typeof ptCloud[k] !== "string" || !ptCloud[k].length);
  if (empty.length) fail("pt-BR cloud empty/non-string keys: " + empty.join(", "));

  for (const k of ["title", "signIn", "signOut", "syncAchievements", "provider"]) {
    if (ptCloud[k] === enCloud[k]) fail(`pt-BR cloud.${k} is still English: ${JSON.stringify(ptCloud[k])}`);
  }
}

// 4) cloudStrings() follows the picked language, en fallback for unknown locales.
if (ptCloud && cloudStrings().title !== ptCloud.title) fail("cloudStrings() didn't return pt-BR for a pt-BR client");
else okmsg("cloudStrings() returns pt-BR for a pt-BR client");

const winRu = ctxFor("ru");
if (winRu.__lumenCloudStrings().title !== winRu.__lumenI18n.en.cloud.title) {
  fail("cloudStrings() didn't fall back to en for an unsupported locale (ru)");
} else {
  okmsg("cloudStrings() falls back to en for an unsupported locale");
}

if (fails) { console.error(`\n${fails} check(s) failed`); process.exit(1); }
console.log("\nall ok");
