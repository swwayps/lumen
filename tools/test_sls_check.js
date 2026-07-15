// test_sls_check.js — the "slsteam-moon not loaded" warning modal
// (menu/13-sls-check.js). When the moon button anchors, the menu asks the
// backend GetSlsLoaded; if it reports loaded=false a modal appears offering the
// auto-fix. loaded=true stays silent. Clicking Auto-fix calls RunSlsAutofix.
// Run: node tools/test_sls_check.js
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

// ── minimal DOM ──────────────────────────────────────────────────────────────
class TextNode { constructor(t) { this.data = t == null ? "" : String(t); } }
class El {
  constructor(tag) {
    this.tagName = (tag || "div").toUpperCase();
    this.childNodes = [];
    this.parentElement = null;
    this.id = ""; this.title = ""; this._class = "";
    this.style = {
      removeProperty(name) { delete this[name]; },
      setProperty(name, value) { this[name] = value; },
    };
    this._listeners = {};
    const self = this;
    this.classList = {
      add(c) { self._setClasses(self._classSet().concat(c)); },
      remove(c) { self._setClasses(self._classSet().filter((x) => x !== c)); },
      toggle() {}, contains(c) { return self._classSet().indexOf(c) !== -1; },
    };
  }
  _classSet() { return this._class ? this._class.split(/\s+/).filter(Boolean) : []; }
  _setClasses(a) { this._class = a.join(" "); }
  set className(v) { this._class = v || ""; }
  get className() { return this._class; }
  get children() { return this.childNodes.filter((n) => n instanceof El); }
  get parentNode() { return this.parentElement; }
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
  set innerHTML(v) {}
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
  click() {
    const evt = { target: this, stopPropagation() {}, preventDefault() {} };
    (this._listeners["click"] || []).forEach((fn) => fn(evt));
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
function byClass(node, cls) {
  return walk(node).filter((e) => e.classList.contains(cls));
}

function buildShell() {
  const root = new El("div");
  const head = new El("div"); root.appendChild(head);
  const body = new El("div"); root.appendChild(body);
  const menubar = new El("div"); body.appendChild(menubar);
  ["Steam", "View", "Friends", "Games", "Help"].forEach((label, idx) => {
    const wrap = new El("div");
    if (idx === 0) {
      const inner = new El("div"); inner.appendChild(new El("div")); inner.appendText(label);
      wrap.appendChild(inner);
    } else {
      const leaf = new El("div"); leaf.textContent = label; wrap.appendChild(leaf);
    }
    menubar.appendChild(wrap);
  });
  return { root, head, body };
}

const flush = () => new Promise((r) => setImmediate(r));

// Run the menu with an injected callServerMethod; returns { root, calls }.
function run(loaded, autofixResult) {
  const { root, head, body } = buildShell();
  const calls = [];
  const win = {};
  win.Millennium = {
    callServerMethod(plugin, fn) {
      calls.push(fn);
      if (fn === "GetSlsLoaded") return Promise.resolve(JSON.stringify({ success: true, loaded }));
      if (fn === "RunSlsAutofix") return Promise.resolve(JSON.stringify(autofixResult || { success: true, terminal: "konsole" }));
      if (fn === "__lumenSlsWarn" || fn === "__lumenOpen" || fn === "__lumenClose") return Promise.resolve("");
      return Promise.reject(new Error("unknown fn: " + fn));
    },
  };
  const ctx = {
    window: win,
    document: {
      head, body, documentElement: root,
      querySelectorAll: () => walk(root),
      getElementById: (id) => findById(root, id),
      createElement: (t) => new El(t),
      addEventListener() {}, removeEventListener() {},
    },
    location: { hostname: "steamloopback.host" },
    navigator: { language: "en" },
    console: { log() {} },
    setTimeout: (fn) => { return 0; },
    clearTimeout: () => {},
    MutationObserver: class { observe() {} disconnect() {} },
    Promise,
    JSON,
  };
  vm.createContext(ctx);
  vm.runInContext(SOURCE, ctx, { filename: "lumen_menu.js" });
  return { root, calls, win };
}

let failures = 0;
function check(name, cond) {
  if (cond) console.log("ok   " + name);
  else { console.error("FAIL " + name); failures++; }
}

(async () => {
  // ── un-injected session (loaded=false) -> BROADCAST the warning ────────────
  // The detection runs in the shell but the warning is broadcast (not rendered
  // locally) so the injector shows it in the on-top view (in front of the store).
  {
    const { root, calls, win } = run(false);
    check("queried GetSlsLoaded on anchor", calls.indexOf("GetSlsLoaded") !== -1);
    await flush();
    check("broadcasts __lumenSlsWarn when not loaded", calls.indexOf("__lumenSlsWarn") !== -1);
    check("does NOT render the modal locally in the shell",
      byClass(root, "lumen-modal-back").length === 0);
    check("exposes __lumenShowSlsWarn for the injector to fire", typeof win.__lumenShowSlsWarn === "function");
  }

  // ── the injector fires __lumenShowSlsWarn in the on-top context -> modal ───
  {
    const { root, calls, win } = run(false);
    await flush();
    win.__lumenShowSlsWarn();  // simulate the broadcast landing in this context
    const titles = byClass(root, "mt");
    check("modal has the not-loaded title",
      titles.some((t) => /didn't load/i.test(t.textContent)));
    const btns = byClass(root, "lumen-mbtn");
    check("modal has two buttons (Ignore + Auto-fix)", btns.length === 2);
    // A second broadcast must NOT stack a second modal.
    win.__lumenShowSlsWarn();
    check("re-broadcast does not stack modals", byClass(root, "lumen-modal-back").length === 1);

    const fix = btns.find((b) => b.classList.contains("primary"));
    check("Auto-fix is the primary button", fix && /auto-fix/i.test(fix.textContent));
    fix.click();
    await flush();
    check("clicking Auto-fix called RunSlsAutofix", calls.indexOf("RunSlsAutofix") !== -1);
    await flush();
    const acks = byClass(root, "mt");
    check("shows the 'running the auto-fix' acknowledgement",
      acks.some((t) => /running the auto-fix/i.test(t.textContent)));
  }

  // ── injected session (loaded=true) -> no warning at all ────────────────────
  {
    const { root, calls } = run(true);
    await flush();
    check("no modal when slsteam-moon is loaded", byClass(root, "lumen-modal-back").length === 0);
    check("still queried the backend", calls.indexOf("GetSlsLoaded") !== -1);
    check("never broadcasts the warning", calls.indexOf("__lumenSlsWarn") === -1);
    check("never called RunSlsAutofix", calls.indexOf("RunSlsAutofix") === -1);
  }

  // ── Ignore dismisses without running the fix ───────────────────────────────
  {
    const { root, calls, win } = run(false);
    await flush();
    win.__lumenShowSlsWarn();
    const btns = byClass(root, "lumen-mbtn");
    const ignore = btns.find((b) => !b.classList.contains("primary"));
    check("Ignore is the secondary button", ignore && /ignore/i.test(ignore.textContent));
    ignore.click();
    await flush();
    check("Ignore removes the modal", byClass(root, "lumen-modal-back").length === 0);
    check("Ignore never runs the auto-fix", calls.indexOf("RunSlsAutofix") === -1);
  }

  if (failures) { console.error("\n" + failures + " check(s) failed"); process.exit(1); }
  console.log("\nall ok");
})();
