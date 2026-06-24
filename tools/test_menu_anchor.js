// test_menu_anchor.js — the full-moon menubar button must anchor regardless of
// Steam's UI language. Detection in menu/10-menubar.js must NOT rely on the
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
  "08-about-tab.js", "09-overlay.js", "10-menubar.js",
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
    this.style = {};
    this.classList = { add() {}, remove() {}, toggle() {} };
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

  // account area with a stray "Steam" leaf — must NOT become the menubar
  const account = new El("div"); titlebar.appendChild(account);
  const acct = new El("div"); acct.textContent = "Steam"; account.appendChild(acct);

  // window controls (icon-only, no text)
  const ctrls = new El("div"); titlebar.appendChild(ctrls);
  for (let i = 0; i < 3; i++) ctrls.appendChild(new El("div"));

  return { root, head, body, menubar };
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

console.log("\nall ok");
