// test_gu_i18n.js — the "Game Updates" tab must follow the user's Steam language
// like the other Lumen tabs. The strings live under I18N[lang].gu and the tab
// code must read the PICKED language (with an en fallback), not the hardcoded
// English block. Run: node tools/test_gu_i18n.js
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const MENU_DIR = path.join(__dirname, "..", "lua", "menu");
const PARTS = [
  "01-core.js", "02-i18n.js", "03-styles.js", "04-overlay-helpers.js",
  "05-config-tab.js", "06-updates-helpers.js", "07-updates-tab.js",
  "08-about-tab.js", "09-overlay.js", "10-fixes-menu.js", "11-menubar.js",
];
const SOURCE = PARTS.map((p) => fs.readFileSync(path.join(MENU_DIR, p), "utf8")).join("\n");

let fails = 0;

// 1) No fragment may hard-code the English Game Updates strings, or translations
//    never apply.
for (const f of ["06-updates-helpers.js", "07-updates-tab.js", "09-overlay.js"]) {
  const src = fs.readFileSync(path.join(MENU_DIR, f), "utf8");
  const m = src.match(/I18N\.en\.gu/g);
  if (m) { console.error(`FAIL: ${f} still has ${m.length} hardcoded I18N.en.gu ref(s)`); fails++; }
  else console.log(`ok   ${f}: no hardcoded English Game Updates strings`);
}

// 2) Run the bundle and introspect the i18n table + the language picker.
function stubEl() {
  return { style: {}, classList: { add() {}, remove() {}, toggle() {} },
    appendChild() {}, addEventListener() {}, setAttribute() {}, textContent: "", title: "", id: "" };
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
const guStrings = winPt.__lumenGuStrings;

if (!I || typeof guStrings !== "function") {
  console.error("FAIL: __lumenI18n / __lumenGuStrings not exposed for introspection");
  process.exit(1);
}

const enGu = I.en.gu;
const ptGu = I["pt-BR"] && I["pt-BR"].gu;

if (!ptGu) {
  console.error("FAIL: pt-BR has no gu block");
  fails++;
} else {
  const missing = Object.keys(enGu).filter((k) => !(k in ptGu));
  if (missing.length) { console.error("FAIL: pt-BR gu missing keys: " + missing.join(", ")); fails++; }
  else console.log(`ok   pt-BR gu has all ${Object.keys(enGu).length} keys`);

  const empty = Object.keys(ptGu).filter((k) => typeof ptGu[k] !== "string" || ptGu[k].length === 0);
  if (empty.length) { console.error("FAIL: pt-BR gu empty/non-string keys: " + empty.join(", ")); fails++; }

  // representative keys that must actually be translated (not left in English).
  // (Avoid true cognates like "experimental"/"depot" that are identical in pt-BR.)
  for (const k of ["title", "note", "reinstallConfirm", "back", "deleteConfirm", "search"]) {
    if (ptGu[k] === enGu[k]) { console.error(`FAIL: pt-BR gu.${k} is still English: ${JSON.stringify(ptGu[k])}`); fails++; }
  }
  if (!fails) console.log("ok   representative pt-BR gu keys are translated");
}

// 3) guStrings() must follow the picked language, with en fallback.
if (ptGu && guStrings().note !== ptGu.note) {
  console.error("FAIL: guStrings() did not return pt-BR for a pt-BR client"); fails++;
} else if (ptGu) {
  console.log("ok   guStrings() returns pt-BR for a pt-BR client");
}
const winRu = ctxFor("ru");
if (winRu.__lumenGuStrings().note !== winRu.__lumenI18n.en.gu.note) {
  console.error("FAIL: guStrings() did not fall back to en for an unsupported locale (ru)"); fails++;
} else {
  console.log("ok   guStrings() falls back to en for an unsupported locale");
}

if (fails) { console.error(`\n${fails} check(s) failed`); process.exit(1); }
console.log("\nall ok");
