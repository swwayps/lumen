// test_menu_anchor.js — the full-moon menubar button must anchor regardless of
// Steam's UI language. Detection in menu/11-menubar.js must NOT rely on the
// localized labels (View/Friends/Games/Help + translations).
//
// The DOM mock mirrors the REAL Steam shell (captured live via CDP):
//   menubar (row)
//     ├─ wrapper ─ inner ─ [ <logo>, "Steam" (bare text node) ]   ← NOT a leaf
//     ├─ wrapper ─ leaf "Exibir"
//     ├─ wrapper ─ leaf "Amigos"
//     ├─ wrapper ─ leaf "Jogos"
//     └─ wrapper ─ leaf "Ajuda"
// Crucially the "Steam" item is the logo + a bare text node, so NO leaf element
// has textContent "Steam". Each menubar child wrapper's textContent is the
// (localized) label; the first wrapper's text is "Steam" in every locale.
// Run: node tools/test_menu_anchor.js
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const MENU_DIR = path.join(__dirname, "..", "lua", "menu");
const PARTS = [
  "01-core.js", "02-i18n.js", "03-styles.js", "04-overlay-helpers.js",
  "05-config-tab.js", "06-updates-helpers.js", "07-updates-tab.js",
  "08-about-tab.js", "09-overlay.js", "10-fixes-menu.js", "12-cloud-tab.js",
  "13-sls-check.js", "11-menubar.js",
];
const SOURCE = PARTS.map((p) => fs.readFileSync(path.join(MENU_DIR, p), "utf8")).join("\n");

// ── minimal DOM with text-node support ──────────────────────────────────────
class TextNode { constructor(t) { this.data = t == null ? "" : String(t); } }

class El {
  constructor(tag) {
    this.tagName = (tag || "div").toUpperCase();
    this.childNodes = []; // mix of El and TextNode (mirrors real childNodes)
    this.parentElement = null;
    this.id = "";
    this.title = "";
    this.className = "";
    this.dataset = {};
    this.style = {
      values: {},
      setProperty: (name, value) => { this.style.values[name] = value; },
      removeProperty: (name) => { delete this.style.values[name]; },
      getPropertyValue: (name) => this.style.values[name] || "",
      getPropertyPriority: () => "",
    };
    this.classList = {
      add: (...names) => { this.className = Array.from(new Set((this.className + " " + names.join(" ")).trim().split(/\s+/))).join(" "); },
      remove: (...names) => { this.className = this.className.split(/\s+/).filter((x) => x && !names.includes(x)).join(" "); },
      contains: (name) => this.className.split(/\s+/).includes(name),
      toggle() {},
    };
    this._listeners = {};
  }
  get children() { return this.childNodes.filter((n) => n instanceof El); }
  appendChild(c) { c.parentElement = this; this.childNodes.push(c); return c; }
  appendText(t) { this.childNodes.push(new TextNode(t)); return this; }
  insertBefore(c, ref) {
    c.parentElement = this;
    const i = this.childNodes.indexOf(ref);
    if (i === -1) this.childNodes.push(c); else this.childNodes.splice(i, 0, c);
    return c;
  }
  remove() {
    if (this.parentElement) {
      const k = this.parentElement.childNodes, i = k.indexOf(this);
      if (i !== -1) k.splice(i, 1);
      this.parentElement = null;
    }
  }
  set textContent(v) { this.childNodes = [new TextNode(v)]; }
  get textContent() {
    return this.childNodes.map((n) => (n instanceof El ? n.textContent : n.data)).join("");
  }
  set innerHTML(v) { /* svg icons — irrelevant */ }
  contains(el) {
    if (el === this) return true;
    for (const c of this.children) if (c.contains(el)) return true;
    return false;
  }
  get nextSibling() {
    if (!this.parentElement) return null;
    const k = this.parentElement.children, i = k.indexOf(this);
    return i >= 0 && i < k.length - 1 ? k[i + 1] : null;
  }
  get lastElementChild() { const c = this.children; return c[c.length - 1] || null; }
  addEventListener(t, fn) { (this._listeners[t] = this._listeners[t] || []).push(fn); }
  removeEventListener() {}
  getBoundingClientRect() {
    if (this.id === "lumen-moon-btn" && this.classList.contains("lumen-fallback-slot")) {
      const left = Number.parseFloat(this.style.values.left || "4");
      const top = Number.parseFloat(this.style.values.top || "4");
      return { x: left, y: top, left, top, right: left + 32, bottom: top + 32, width: 32, height: 32 };
    }
    return { x: 0, y: 0, left: 0, top: 0, right: 24, bottom: 20, width: 24, height: 20 };
  }
  querySelectorAll() { return walk(this); }
}

function walk(node, out) {
  out = out || [];
  for (const c of node.children) { out.push(c); walk(c, out); }
  return out;
}
function findById(node, id) {
  if (node.id === id) return node;
  for (const c of node.children) { const r = findById(c, id); if (r) return r; }
  return null;
}

function buildShell(labels) {
  const root = new El("div");
  const head = new El("div"); root.appendChild(head);
  const body = new El("div"); root.appendChild(body);

  const titlebar = new El("div"); body.appendChild(titlebar);
  const logoLeft = new El("div"); titlebar.appendChild(logoLeft);

  const menubar = new El("div"); titlebar.appendChild(menubar);
  labels.forEach((label, idx) => {
    const wrap = new El("div");
    if (idx === 0) {
      // first item = Steam: logo element + bare "Steam" text node (no leaf)
      const inner = new El("div");
      inner.appendChild(new El("div")); // svg/logo
      inner.appendText(label);          // "Steam" as a text node
      wrap.appendChild(inner);
    } else {
      const leaf = new El("div");
      leaf.textContent = label;
      wrap.appendChild(leaf);
    }
    menubar.appendChild(wrap);
  });

  // Steam keeps a flexible empty titlebar spacer between the root menubar and
  // the account/download/window-control cluster. It is the only stable area
  // that remains clear when a theme covers the Help-side native anchor.
  const spacer = new El("div");
  spacer.getBoundingClientRect = () => ({ x: 286, y: 0, left: 286, top: 0, right: 1186, bottom: 40, width: 900, height: 40 });
  titlebar.appendChild(spacer);

  // account area with a stray "Steam" leaf — must NOT become the menubar
  const account = new El("div"); titlebar.appendChild(account);
  const acct = new El("div"); acct.textContent = "Steam"; account.appendChild(acct);

  // window controls (icon-only, no text)
  const ctrls = new El("div"); titlebar.appendChild(ctrls);
  for (let i = 0; i < 3; i++) ctrls.appendChild(new El("div"));

  return { root, head, body, menubar, spacer, account };
}

function makeDocument(root, head, body) {
  return {
    head, body, documentElement: root,
    querySelectorAll: () => walk(root),
    getElementById: (id) => findById(root, id),
    createElement: (t) => new El(t),
    addEventListener() {}, removeEventListener() {},
  };
}

function runMenu(labels, lang) {
  const { root, head, body, menubar } = buildShell(labels);
  const win = {};
  const ctx = {
    window: win,
    document: makeDocument(root, head, body),
    location: { hostname: "steamloopback.host" },
    navigator: { language: lang || "en" },
    console: { log() {} },
    setTimeout: () => 0,
    clearTimeout: () => {},
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  const btn = findById(root, "lumen-moon-btn");
  return { btn, menubar };
}

// The menubar does not exist when the script first runs (cold Steam start); it
// must keep retrying and anchor once the menubar appears, even well past 30s.
// Drives a manual setTimeout queue so we control "time".
function runLateMenu(labels, appearAtTick, maxTicks) {
  // shell with an EMPTY title bar — no menubar yet
  const root = new El("div");
  const head = new El("div"); root.appendChild(head);
  const body = new El("div"); root.appendChild(body);
  const titlebar = new El("div"); body.appendChild(titlebar);

  const queue = [];
  const win = {};
  const ctx = {
    window: win,
    document: makeDocument(root, head, body),
    location: { hostname: "steamloopback.host" },
    navigator: { language: "pt-BR" },
    console: { log() {} },
    setTimeout: (fn) => { queue.push(fn); return queue.length; },
    clearTimeout: () => {},
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" }); // runs tryAnchor once

  for (let tick = 1; tick <= maxTicks; tick++) {
    if (tick === appearAtTick) {
      // menubar renders into the title bar
      const menubar = new El("div");
      labels.forEach((label, idx) => {
        const wrap = new El("div");
        if (idx === 0) {
          const inner = new El("div");
          inner.appendChild(new El("div"));
          inner.appendText(label);
          wrap.appendChild(inner);
        } else {
          const leaf = new El("div"); leaf.textContent = label; wrap.appendChild(leaf);
        }
        menubar.appendChild(wrap);
      });
      titlebar.appendChild(menubar);
    }
    const fn = queue.shift();
    if (!fn) break;           // gave up scheduling — no more retries
    fn();
    if (findById(root, "lumen-moon-btn")) break;
  }
  return { btn: findById(root, "lumen-moon-btn") };
}

// A theme can replace the complete native menubar after Lumen has anchored.
// The access watchdog must remain recurring even while the button is healthy,
// otherwise that later replacement permanently removes the only entry point.
function runThemeReplacesMenubar(labels) {
  const { root, head, body, menubar } = buildShell(labels);
  const queue = [];
  const win = {};
  const ctx = {
    window: win,
    document: makeDocument(root, head, body),
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" },
    console: { log() {} },
    setTimeout: (fn, delay) => { queue.push({ fn, delay }); return queue.length; },
    clearTimeout: () => {},
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1",
      backgroundColor: "rgb(20, 20, 20)", getPropertyValue: () => "",
    }),
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });

  // First watchdog pass sees a healthy button. It still has to schedule the
  // next pass before the theme removes the entire observed menubar subtree.
  const firstIndex = queue.findIndex((job) => job.delay === 2000);
  const firstCheck = firstIndex >= 0 ? queue.splice(firstIndex, 1)[0] : null;
  if (firstCheck) firstCheck.fn();
  menubar.remove();
  for (let i = 0; i < 5; i++) {
    const nextIndex = queue.findIndex((job) => job.delay === 2000);
    if (nextIndex < 0) break;
    queue.splice(nextIndex, 1)[0].fn();
  }
  return { btn: findById(root, "lumen-moon-btn") };
}

function runThemeCoversButton(labels) {
  const { root, head, body, spacer } = buildShell(labels);
  root.style.setProperty("--lumen-theme-bg", "stale-custom-theme");
  const queue = [];
  const doc = makeDocument(root, head, body);
  const cover = new El("div");
  doc.elementFromPoint = () => cover;
  const ctx = {
    window: { __lumenThemeApplied: "covering-theme" }, document: doc,
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" }, console: { log() {} },
    setTimeout: (fn, delay) => { queue.push({ fn, delay }); return queue.length; },
    clearTimeout: () => {},
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1",
      backgroundColor: "rgb(20, 20, 20)", getPropertyValue: () => "",
    }),
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  for (let i = 0; i < 1; i++) {
    const index = queue.findIndex((job) => job.delay === 2000);
    if (index < 0) break;
    queue.splice(index, 1)[0].fn();
  }
  const btn = findById(root, "lumen-moon-btn");
  return {
    btn,
    fallback: !!btn && btn.className.indexOf("lumen-fallback") >= 0,
    slotted: !!btn && btn.parentElement && btn.parentElement.id === "lumen-access-layer" &&
      btn.classList.contains("lumen-fallback-slot") &&
      spacer.classList.contains("lumen-fallback-host"),
  };
}

function runDefaultPaletteCleanup(labels) {
  const { root, head, body } = buildShell(labels);
  root.style.setProperty("--lumen-theme-bg", "stale-custom-theme");
  const ctx = {
    window: {}, document: makeDocument(root, head, body),
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" }, console: { log() {} },
    setTimeout: () => 0, clearTimeout: () => {},
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1",
      backgroundColor: "rgb(20, 20, 20)", getPropertyValue: () => "",
    }),
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  return Object.keys(root.style.values).some((name) => name.indexOf("--lumen-theme-") === 0);
}

// Some themes position the account/download cluster with position:fixed over
// Steam's nominally empty flex spacer. The fallback must inspect what is
// actually under its complete 32px box and move left whenever that cluster
// grows, without knowing theme classes or localized text.
function runFallbackAvoidsDynamicControls(labels) {
  const { root, head, body, spacer, account } = buildShell(labels);
  const queue = [];
  const doc = makeDocument(root, head, body);
  const cover = new El("div");
  let accountLeft = 1000;
  account.getBoundingClientRect = () => ({
    x: accountLeft, y: 4, left: accountLeft, top: 4,
    right: 1186, bottom: 36, width: 1186 - accountLeft, height: 32,
  });
  doc.elementFromPoint = (x) => {
    const btn = findById(root, "lumen-moon-btn");
    if (!btn || !btn.classList.contains("lumen-fallback")) return cover;
    if (btn.style.values["pointer-events"] !== "none") return btn;
    return x >= accountLeft ? account : spacer;
  };
  const ctx = {
    window: { __lumenThemeApplied: "moving-controls-theme" }, document: doc,
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" }, console: { log() {} },
    setTimeout: (fn, delay) => { queue.push({ fn, delay }); return queue.length; },
    clearTimeout: () => {},
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1",
      backgroundColor: "rgb(20, 20, 20)", getPropertyValue: () => "",
    }),
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  let index = queue.findIndex((job) => job.delay === 2000);
  queue.splice(index, 1)[0].fn();
  const first = findById(root, "lumen-moon-btn").getBoundingClientRect();

  // A download/account indicator expands left after the fallback is already
  // placed. The next lightweight access check must move it again.
  accountLeft = first.left - 8;
  index = queue.findIndex((job) => job.delay === 2000);
  queue.splice(index, 1)[0].fn();
  const second = findById(root, "lumen-moon-btn").getBoundingClientRect();
  return { first, second, firstLimit: 1000, secondLimit: accountLeft };
}

function runThemeReturnsNativeMenubar(labels) {
  const { root, head, body, menubar } = buildShell(labels);
  const queue = [];
  const win = { __lumenThemeApplied: "covering-theme" };
  const doc = makeDocument(root, head, body);
  const cover = new El("div");
  doc.elementFromPoint = () => cover;
  const ctx = {
    window: win, document: doc,
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" }, console: { log() {} },
    setTimeout: (fn, delay) => { queue.push({ fn, delay }); return queue.length; },
    clearTimeout: () => {},
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1",
      backgroundColor: "rgb(20, 20, 20)", getPropertyValue: () => "",
    }),
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  let index = queue.findIndex((job) => job.delay === 2000);
  queue.splice(index, 1)[0].fn(); // covered -> fallback
  win.__lumenThemeApplied = "";
  doc.elementFromPoint = (x, y) => findById(root, "lumen-moon-btn");
  index = queue.findIndex((job) => job.delay === 2000);
  queue.splice(index, 1)[0].fn(); // theme changed -> restore native anchor
  const btn = findById(root, "lumen-moon-btn");
  return { btn, native: !!btn && menubar.contains(btn) && btn.className.indexOf("lumen-fallback") < 0 };
}

// elementFromPoint can temporarily report a popup, animation layer or stale
// themed node over the native Help-side button. Once that native position was
// selected for the current theme session, a transient hit-test must not move
// the button to the fallback slot. A theme change is the reset boundary.
function runNativeAnchorSurvivesTransientCover(labels) {
  const { root, head, body, menubar } = buildShell(labels);
  const queue = [];
  const doc = makeDocument(root, head, body);
  const cover = new El("div");
  doc.elementFromPoint = () => findById(root, "lumen-moon-btn");
  const win = {};
  const ctx = {
    window: win, document: doc,
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" }, console: { log() {} },
    setTimeout: (fn, delay) => { queue.push({ fn, delay }); return queue.length; },
    clearTimeout: () => {},
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1",
      backgroundColor: "rgb(20, 20, 20)", getPropertyValue: () => "",
    }),
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  const original = findById(root, "lumen-moon-btn");
  doc.elementFromPoint = () => cover;
  for (let i = 0; i < 3; i++) {
    const index = queue.findIndex((job) => job.delay === 2000);
    if (index < 0) break;
    queue.splice(index, 1)[0].fn();
  }
  const current = findById(root, "lumen-moon-btn");
  return {
    sameNode: current === original,
    native: !!current && menubar.contains(current) && !current.classList.contains("lumen-fallback"),
  };
}

// Switching directly from one custom theme to another must choose the new
// theme's fallback placement in one reconciliation pass. The old behaviour
// briefly recreated the native Help-side button and moved it again two seconds
// later, which is the visible location jump this test guards against.
function runCustomThemeSwitchKeepsFallback(labels) {
  const { root, head, body } = buildShell(labels);
  const queue = [];
  const win = { __lumenThemeApplied: "theme-a" };
  const doc = makeDocument(root, head, body);
  doc.elementFromPoint = () => findById(root, "lumen-moon-btn");
  const ctx = {
    window: win, document: doc,
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" }, console: { log() {} },
    setTimeout: (fn, delay) => { queue.push({ fn, delay }); return queue.length; },
    clearTimeout: () => {},
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1",
      backgroundColor: "rgb(20, 20, 20)", getPropertyValue: () => "",
    }),
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  win.__lumenThemeApplied = "theme-b";
  const index = queue.findIndex((job) => job.delay === 2000);
  queue.splice(index, 1)[0].fn();
  const btn = findById(root, "lumen-moon-btn");
  return {
    fallback: !!btn && btn.classList.contains("lumen-fallback"),
    theme: btn && btn.dataset.lumenTheme,
  };
}

// The menu bundle is composed before the theme asset bundle. The configured
// theme is therefore the stable session identity; __lumenThemeApplied may only
// appear a little later when the theme script executes. That late marker is
// initial settling, not a user theme switch, and must not relocate the button.
function runConfiguredThemeSettlesWithoutMove(labels) {
  const { root, head, body } = buildShell(labels);
  const queue = [];
  const win = { __lumenConfiguredTheme: "theme-a" };
  const doc = makeDocument(root, head, body);
  doc.elementFromPoint = () => findById(root, "lumen-moon-btn");
  const ctx = {
    window: win, document: doc,
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" }, console: { log() {} },
    setTimeout: (fn, delay) => { queue.push({ fn, delay }); return queue.length; },
    clearTimeout: () => {},
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1",
      backgroundColor: "rgb(20, 20, 20)", getPropertyValue: () => "",
    }),
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  const original = findById(root, "lumen-moon-btn");
  win.__lumenThemeApplied = "theme-a";
  const index = queue.findIndex((job) => job.delay === 2000);
  queue.splice(index, 1)[0].fn();
  const current = findById(root, "lumen-moon-btn");
  return {
    sameNode: current === original,
    fallback: !!current && current.classList.contains("lumen-fallback"),
    theme: current && current.dataset.lumenTheme,
  };
}

function runOwnOverlayCoversButton(labels) {
  const { root, head, body, menubar } = buildShell(labels);
  const queue = [];
  const doc = makeDocument(root, head, body);
  const overlay = new El("div"); overlay.id = "lumen-settings-overlay"; body.appendChild(overlay);
  doc.elementFromPoint = () => overlay;
  const ctx = {
    window: {}, document: doc,
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" }, console: { log() {} },
    setTimeout: (fn, delay) => { queue.push({ fn, delay }); return queue.length; },
    clearTimeout: () => {},
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1",
      backgroundColor: "rgb(20, 20, 20)", getPropertyValue: () => "",
    }),
    MutationObserver: class { observe() {} disconnect() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  const index = queue.findIndex((job) => job.delay === 2000);
  queue.splice(index, 1)[0].fn();
  const btn = findById(root, "lumen-moon-btn");
  return { native: !!btn && menubar.contains(btn) && !btn.classList.contains("lumen-fallback") };
}

// label order: Steam, View, Friends, Games, Help (localized)
const LANGS = {
  "en":    ["Steam", "View", "Friends", "Games", "Help"],
  "pt-BR": ["Steam", "Exibir", "Amigos", "Jogos", "Ajuda"],
  "ru":    ["Steam", "Вид", "Друзья", "Игры", "Справка"],
  "de":    ["Steam", "Ansicht", "Freunde", "Spiele", "Hilfe"],
  "fr":    ["Steam", "Afficher", "Amis", "Jeux", "Aide"],
  "ja":    ["Steam", "表示", "フレンド", "ゲーム", "ヘルプ"],
  "zh-CN": ["Steam", "查看", "好友", "游戏", "帮助"],
  "ar":    ["Steam", "عرض", "الأصدقاء", "الألعاب", "مساعدة"],
};

let failures = 0;
for (const [lang, labels] of Object.entries(LANGS)) {
  const { btn, menubar } = runMenu(labels, lang);
  if (!btn) {
    console.error(`FAIL [${lang}]: moon button was not anchored`);
    failures++;
  } else if (!menubar.contains(btn)) {
    console.error(`FAIL [${lang}]: moon button anchored outside the menubar`);
    failures++;
  } else {
    console.log(`ok   [${lang}]: moon button anchored in the menubar`);
  }
}

if (failures) {
  console.error(`\n${failures} language(s) failed`);
  process.exit(1);
}
console.log("\nall languages ok");

// ── late-appearing menubar (cold start) ─────────────────────────────────────
// The old code gave up after ~30 retries; a menubar that renders at tick 45
// must still get the button.
const PT = ["Steam", "Exibir", "Amigos", "Jogos", "Ajuda"];
const late = runLateMenu(PT, 45, 200);
if (!late.btn) {
  console.error("FAIL [late]: menubar appeared at tick 45 but button never anchored");
  process.exit(1);
}
console.log("ok   [late]: button anchored after a late-rendering menubar");

const replaced = runThemeReplacesMenubar(PT);
if (!replaced.btn) {
  console.error("FAIL [theme replacement]: access button vanished with the native menubar");
  process.exit(1);
}
console.log("ok   [theme replacement]: fallback survives a complete menubar replacement");

const covered = runThemeCoversButton(PT);
if (!covered.fallback) {
  console.error("FAIL [theme cover]: covered button was not promoted to the fixed fallback");
  process.exit(1);
}
console.log("ok   [theme cover]: covered button is promoted to the fixed fallback");
if (!covered.slotted) {
  console.error("FAIL [fallback slot]: fallback overlaps Steam's dynamic download area");
  process.exit(1);
}
console.log("ok   [fallback slot]: fallback uses the empty titlebar spacer");
const collision = runFallbackAvoidsDynamicControls(PT);
if (collision.first.right > collision.firstLimit || collision.second.right > collision.secondLimit ||
    collision.second.left >= collision.first.left) {
  console.error("FAIL [fallback collision]: fallback overlaps a fixed theme/download control");
  process.exit(1);
}
console.log("ok   [fallback collision]: fallback tracks the rightmost truly free titlebar slot");
if (runDefaultPaletteCleanup(PT)) {
  console.error("FAIL [default palette]: browser colors leaked into Lumen without a custom theme");
  process.exit(1);
}
console.log("ok   [default palette]: no adaptive colors without a custom theme");

const restored = runThemeReturnsNativeMenubar(PT);
if (!restored.native) {
  console.error("FAIL [theme restore]: fallback stayed fixed after the native menubar returned");
  process.exit(1);
}
console.log("ok   [theme restore]: theme change restores the native Help-side anchor");

const lockedNative = runNativeAnchorSurvivesTransientCover(PT);
if (!lockedNative.native || !lockedNative.sameNode) {
  console.error("FAIL [anchor lock]: same-theme hit-test moved the native Help-side button");
  process.exit(1);
}
console.log("ok   [anchor lock]: native Help-side position stays locked for the theme session");

const customSwitch = runCustomThemeSwitchKeepsFallback(PT);
if (!customSwitch.fallback || customSwitch.theme !== "theme-b") {
  console.error("FAIL [custom switch]: custom-theme change recreated an intermediate native button");
  process.exit(1);
}
console.log("ok   [custom switch]: custom-theme change selects its fallback without a position jump");

const configuredSettle = runConfiguredThemeSettlesWithoutMove(PT);
if (!configuredSettle.sameNode || !configuredSettle.fallback || configuredSettle.theme !== "theme-a") {
  console.error("FAIL [configured theme]: late applied marker relocated the session button");
  process.exit(1);
}
console.log("ok   [configured theme]: initial theme settling does not relocate the session button");

const ownOverlay = runOwnOverlayCoversButton(PT);
if (!ownOverlay.native) {
  console.error("FAIL [own overlay]: opening Lumen incorrectly promoted its button to fallback");
  process.exit(1);
}
console.log("ok   [own overlay]: Lumen overlay does not trigger its own fallback");

console.log("\nall ok");
