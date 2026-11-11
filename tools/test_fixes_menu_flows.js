// test_fixes_menu_flows.js — Fixes Menu flows driven end to end through the
// real menu bundle (menu/*.js, the boot.lua order) on a small fake DOM, with
// the backend RPCs answered by the test: Escape on a confirmation runs its
// decline path, picker rows are gamepad-reachable buttons, Unfix never says
// "Restored" over a failed revert, the busy note tells searching from
// downloading, an install whose fix needs no override clears a stale one, a
// menu closed mid-download neither installs nor keeps the downloaded fix, and
// the Online Fix tile installs online-fix.me's torrent download (Cancel stops
// it, a failed one falls back to the mirror) and only sets launch options over
// an install recorded as online-fix.me's.
// Run: node tools/test_fixes_menu_flows.js
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const MENU_DIR = path.join(__dirname, "..", "lua", "menu");
const PARTS = [
  "01-core.js", "02-i18n.js", "03-styles.js", "04-overlay-helpers.js",
  "05-config-tab.js", "06-updates-helpers.js", "07-updates-tab.js",
  "08-about-tab.js", "09-luatools-account.js", "09-overlay.js",
  "10-auto-fix-status.js", "10-fixes-menu.js", "12-cloud-tab.js",
  "13-sls-check.js", "11-menubar.js",
];
const SOURCE = PARTS.map((p) => fs.readFileSync(path.join(MENU_DIR, p), "utf8")).join("\n");

// ── fake DOM ────────────────────────────────────────────────────────────────
function parseCompound(text) {
  const c = { tag: null, id: null, classes: [], attrs: [], nots: [], scope: false };
  const re = /^(?:(\*|[a-zA-Z][\w-]*)|#([\w-]+)|\.([\w-]+)|\[([\w-]+)(?:(\*?=)"([^"]*)")?\]|:not\(([^)]*)\)|(:scope))/;
  let s = text;
  while (s.length) {
    const m = re.exec(s);
    if (!m) throw new Error("unsupported selector: " + text);
    if (m[1]) c.tag = m[1] === "*" ? null : m[1].toUpperCase();
    else if (m[2]) c.id = m[2];
    else if (m[3]) c.classes.push(m[3]);
    else if (m[4]) c.attrs.push({ name: m[4], op: m[5], value: m[6] });
    else if (m[7]) c.nots.push(parseCompound(m[7]));
    else if (m[8]) c.scope = true;
    s = s.slice(m[0].length);
  }
  return c;
}
function matchCompound(el, c, scope) {
  if (!(el instanceof FakeElement)) return false;
  if (c.scope && el !== scope) return false;
  if (c.tag && el.tagName !== c.tag) return false;
  if (c.id && el.id !== c.id) return false;
  for (const k of c.classes) if (!el.classList.contains(k)) return false;
  for (const a of c.attrs) {
    if (!el.hasAttribute(a.name)) return false;
    const v = el.getAttribute(a.name);
    if (a.op === "=" && v !== a.value) return false;
    if (a.op === "*=" && v.indexOf(a.value) === -1) return false;
  }
  for (const n of c.nots) if (matchCompound(el, n, scope)) return false;
  return true;
}
function parseSelector(sel) {
  return sel.split(",").map((one) => {
    const tokens = one.trim().replace(/\s*>\s*/g, " > ").split(/\s+/);
    const parts = [];
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i] === ">") parts.push(">");
      else {
        if (parts.length && parts[parts.length - 1] !== ">") parts.push(" ");
        parts.push(parseCompound(tokens[i]));
      }
    }
    return parts;
  });
}
function matchParts(el, parts, i, scope) {
  if (!matchCompound(el, parts[i], scope)) return false;
  if (i === 0) return true;
  const comb = parts[i - 1];
  if (comb === ">") return !!el.parentNode && matchParts(el.parentNode, parts, i - 2, scope);
  for (let p = el.parentNode; p; p = p.parentNode) {
    if (matchParts(p, parts, i - 2, scope)) return true;
  }
  return false;
}

class FakeText {
  constructor(text) { this.nodeType = 3; this.text = String(text); this.parentNode = null; }
  get textContent() { return this.text; }
  set textContent(v) { this.text = String(v); }
}

class FakeElement {
  constructor(tag) {
    this.nodeType = 1;
    this.tagName = String(tag).toUpperCase();
    this.childNodes = [];
    this.parentNode = null;
    this.attributes = {};
    this.style = {};
    this.listeners = {};
    this.dataset = {};
    const el = this;
    this.classList = {
      list() { return (el.attributes.class || "").split(/\s+/).filter(Boolean); },
      contains(k) { return this.list().indexOf(k) !== -1; },
      add(...ks) { const l = this.list(); ks.forEach((k) => { if (l.indexOf(k) === -1) l.push(k); }); el.attributes.class = l.join(" "); },
      remove(...ks) { el.attributes.class = this.list().filter((k) => ks.indexOf(k) === -1).join(" "); },
      toggle(k, on) { if (on === undefined) on = !this.contains(k); if (on) this.add(k); else this.remove(k); return on; },
    };
  }
  get id() { return this.attributes.id || ""; }
  set id(v) { this.attributes.id = String(v); }
  get className() { return this.attributes.class || ""; }
  set className(v) { this.attributes.class = String(v); }
  get children() { return this.childNodes.filter((n) => n instanceof FakeElement); }
  get firstChild() { return this.childNodes[0] || null; }
  get lastChild() { return this.childNodes[this.childNodes.length - 1] || null; }
  get parentElement() { return this.parentNode instanceof FakeElement ? this.parentNode : null; }
  get isConnected() {
    for (let n = this; n; n = n.parentNode) if (n === document.documentElement) return true;
    return false;
  }
  get offsetHeight() { return 0; }
  get textContent() { return this.childNodes.map((n) => n.textContent).join(""); }
  set textContent(v) {
    this.childNodes.forEach((n) => { n.parentNode = null; });
    this.childNodes = [];
    if (v !== "" && v !== null && v !== undefined) this.appendChild(new FakeText(v));
  }
  set innerHTML(html) {
    this.textContent = "";
    const stack = [this];
    const re = /<\/([a-zA-Z][\w-]*)\s*>|<([a-zA-Z][\w-]*)((?:\s+[\w:-]+(?:="[^"]*")?)*)\s*(\/?)>|([^<]+)/g;
    let m;
    while ((m = re.exec(String(html)))) {
      const top = stack[stack.length - 1];
      if (m[1]) { if (stack.length > 1) stack.pop(); }
      else if (m[2]) {
        const el = document.createElement(m[2]);
        (m[3] || "").replace(/([\w:-]+)(?:="([^"]*)")?/g, (_, k, v) => { el.setAttribute(k, v === undefined ? "" : v); });
        top.appendChild(el);
        if (!m[4]) stack.push(el);
      } else if (m[5]) top.appendChild(new FakeText(m[5]));
    }
  }
  get innerHTML() { return ""; }
  getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k); }
  removeAttribute(k) { delete this.attributes[k]; }
  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }
  insertBefore(child, ref) {
    if (!ref) return this.appendChild(child);
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    this.childNodes.splice(this.childNodes.indexOf(ref), 0, child);
    return child;
  }
  removeChild(child) {
    const i = this.childNodes.indexOf(child);
    if (i !== -1) this.childNodes.splice(i, 1);
    child.parentNode = null;
    return child;
  }
  replaceChild(next, old) {
    this.insertBefore(next, old);
    return this.removeChild(old);
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  contains(node) {
    for (let n = node; n; n = n.parentNode) if (n === this) return true;
    return false;
  }
  descendants() {
    const out = [];
    const walk = (n) => n.children.forEach((c) => { out.push(c); walk(c); });
    walk(this);
    return out;
  }
  querySelectorAll(sel) {
    const alts = parseSelector(sel);
    return this.descendants().filter((el) => alts.some((parts) => matchParts(el, parts, parts.length - 1, this)));
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn);
  }
  click() {
    const event = {
      type: "click", target: this, stopped: false, defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.stopped = true; },
      stopImmediatePropagation() { this.stopped = true; },
    };
    for (let n = this; n && !event.stopped; n = n.parentNode) {
      for (const fn of (n.listeners && n.listeners.click) || []) fn.call(n, event);
    }
  }
  focus() { document.activeElement = this; }
  blur() {}
  select() {}
  getBoundingClientRect() { return { left: 0, top: 0, right: 100, bottom: 30, width: 100, height: 30 }; }
}

const docListeners = {};
const document = {
  createElement: (tag) => new FakeElement(tag),
  createTextNode: (t) => new FakeText(t),
  addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
  removeEventListener(type, fn) {
    docListeners[type] = (docListeners[type] || []).filter((f) => f !== fn);
  },
  getElementById(id) {
    return document.documentElement.descendants().find((el) => el.id === id) || null;
  },
  querySelectorAll(sel) { return document.documentElement.querySelectorAll(sel); },
  querySelector(sel) { return document.documentElement.querySelector(sel); },
  execCommand() {},
};
document.documentElement = new FakeElement("html");
document.head = document.documentElement.appendChild(new FakeElement("head"));
document.body = document.documentElement.appendChild(new FakeElement("body"));
document.activeElement = document.body;
function keydown(key) {
  const event = {
    key, type: "keydown", target: document.activeElement, stopped: false,
    preventDefault() {}, stopPropagation() {}, stopImmediatePropagation() { this.stopped = true; },
  };
  for (const fn of (docListeners.keydown || []).slice()) {
    if (event.stopped) break;
    fn(event);
  }
}

// The focused game's hero image: the menu reads the appid from it.
const hero = document.createElement("img");
hero.setAttribute("src", "https://steamloopback.host/assets/322330/abc/library_hero.jpg?c=1");
hero.src = hero.getAttribute("src");
document.body.appendChild(hero);

// ── timers and RPCs under test control ──────────────────────────────────────
let timers = [];
const rpcLog = [];
let handlers = {};
const window = {
  Millennium: {
    callServerMethod(plugin, fn, args) {
      rpcLog.push({ fn, args });
      const h = handlers[fn];
      if (!h) return Promise.resolve(JSON.stringify({ success: false }));
      return Promise.resolve().then(() => h(args)).then((r) => (typeof r === "string" ? r : JSON.stringify(r)));
    },
  },
  getComputedStyle: () => ({ display: "block", visibility: "visible", opacity: "1" }),
};
const sandbox = {
  window, document,
  location: { hostname: "steamloopback.host" },
  navigator: { language: "en-US" },
  console: { log() {}, warn() {}, error() {} },
  setTimeout: (fn) => { timers.push(fn); return timers.length; },
  clearTimeout: () => {},
  setInterval: () => 0,
  clearInterval: () => {},
  MutationObserver: class { observe() {} disconnect() {} },
  Promise, JSON, Date, Math, Object, Array, String, Number, RegExp, Error,
};
vm.createContext(sandbox);
vm.runInContext(SOURCE, sandbox, { filename: "lumen_menu.js" });
const S = window.__lumenI18n.en.fixes;

async function settle(rounds) {
  for (let i = 0; i < (rounds || 30); i++) {
    await new Promise((r) => setImmediate(r));
    const due = timers;
    timers = [];
    due.forEach((fn) => fn());
  }
}

let failures = 0;
function eq(name, got, want) {
  if (got === want) console.log("ok   " + name);
  else { console.error("FAIL " + name + ": got " + JSON.stringify(got) + " want " + JSON.stringify(want)); failures++; }
}

const BASE = {
  LumenFixesContext: () => ({ success: true, isInstalled: true, installPath: "/games/G",
    gameName: "Game", runsUnderProton: true }),
  CheckForFixes: () => ({ success: true, luaToolsFixes: { fixes: [] } }),
  LumenDetectLocalFix: () => ({ success: true, found: false }),
  ResolveOnlineFix: () => ({ success: true, found: false }),
  GetFixLaunchOptions: () => ({ success: true, apply: false }),
};
function calls(fn) { return rpcLog.filter((c) => c.fn === fn); }
function overlay() { return document.getElementById("lumen-fixes-overlay"); }
function tile(label) {
  return document.querySelectorAll(".lumen-fx-tile")
    .find((t) => (t.querySelector(".tl") || {}).textContent === label) || null;
}
function modals() { return document.querySelectorAll(".lumen-modal-back"); }
function lastModalText() {
  const m = modals();
  return m.length ? m[m.length - 1].querySelector(".mb").textContent : null;
}

async function openMenu(extra) {
  for (const m of modals()) m.remove();
  const o = overlay();
  if (o) o.remove();
  (docListeners.keydown || []).length = 0;
  rpcLog.length = 0;
  handlers = Object.assign({}, BASE, extra || {});
  window.__lumenOpenFixesMenu();
  await settle();
}

// Confirm Unfix on the first modal, then let the flow run.
async function confirmUnfix() {
  tile(S.unfixLabel).click();
  await settle();
  modals()[0].querySelector(".lumen-mbtn.primary").click();
  await settle();
}

(async function main() {
  // ── Unfix: a revert that could not run is never reported as "Restored" ──
  const unfixOk = { UnFixGame: () => ({ success: true }) };
  await openMenu(Object.assign({}, unfixOk, {
    LumenRevertFixInstall: () => ({ success: true, reverted: false }) }));
  await confirmUnfix();
  eq("unfix: nothing recorded -> the closing note says Restored",
    (lastModalText() || "").indexOf(S.unfixDone) === 0, true);

  await openMenu(Object.assign({}, unfixOk, {
    LumenRevertFixInstall: () => { throw new Error("rpc down"); } }));
  await confirmUnfix();
  eq("unfix: a rejected revert does not say Restored, and says the files remain",
    (lastModalText() || "").indexOf(S.unfixDone) === -1
      && (lastModalText() || "").indexOf(S.unfixRevertFailed) !== -1, true);

  await openMenu(Object.assign({}, unfixOk, {
    LumenRevertFixInstall: () => ({ success: false, error: "crash" }) }));
  await confirmUnfix();
  eq("unfix: a failed revert ({success:false}) does not say Restored, and says the files remain",
    (lastModalText() || "").indexOf(S.unfixDone) === -1
      && (lastModalText() || "").indexOf(S.unfixRevertFailed) !== -1, true);

  // fixinstall.revert's answers for a record it cannot read or use: the same
  // every time, so the note points to Steam's verify and manual removal
  // instead of asking for another Unfix.
  for (const code of ["record_invalid", "record_unreadable"]) {
    await openMenu(Object.assign({}, unfixOk, {
      LumenRevertFixInstall: () => ({ success: false, errorCode: code, reverted: false,
        removed: 0, replacedCount: 0, needsVerify: false }) }));
    await confirmUnfix();
    const text = lastModalText() || "";
    eq("unfix: " + code + " says the record could not be read, not to press Unfix again",
      text.indexOf(S.unfixDone) === -1 && text.indexOf(S.unfixRecordUnreadable) !== -1
        && text.indexOf(S.unfixRevertFailed) === -1, true);
  }

  // ── Escape on the verify confirmation takes the decline path ─────────────
  await openMenu(Object.assign({}, unfixOk, {
    LumenRevertFixInstall: () => ({ success: true, reverted: true, removed: 2,
      replacedCount: 3, needsVerify: true }),
    __lumenValidateApp: () => ({ ok: true }),
  }));
  await confirmUnfix();
  const askText = lastModalText() || "";
  keydown("Escape");
  await settle();
  const manual = window.__lumenFixesFill(S.unfixVerifyManual, { replaced: 3 });
  eq("unfix: Escape on the verify question declines it: no verify, the manual-verify note shows",
    askText.indexOf(S.unfixVerifyAsk) !== -1 && calls("__lumenValidateApp").length === 0
      && (lastModalText() || "").indexOf(manual) !== -1
      && (lastModalText() || "").indexOf(S.unfixDone) === -1, true);

  // ── FreeTP: the archive picker ───────────────────────────────────────────
  const archiveName = "fix $& $' v2.zip";
  let finishInstall = null;
  await openMenu({
    LumenDownloadFreeTPFix: () => ({ success: false, errorCode: "no_page" }),
    LumenListFixArchives: () => ({ success: true, archives: [
      { name: archiveName, path: "/home/u/Downloads/fix.zip", size: 1000, mtime: 1 },
      { name: "other.rar", path: "/home/u/Downloads/other.rar", size: 2000, mtime: 2 },
    ] }),
    LumenInstallFixArchive: () => new Promise((resolve) => { finishInstall = resolve; }),
  });
  tile(S.freetpLabel).click();
  await settle();
  const rows = document.querySelectorAll(".lumen-fx-arch");
  eq("picker: every archive row is a role=button (gamepad focus reaches only those)",
    rows.length === 2 && rows.every((r) => r.getAttribute("role") === "button"), true);
  rows[0].click();
  await settle();
  const busy = document.querySelectorAll(".lumen-fx-spin").map((s) => s.parentNode.lastChild.textContent);
  eq("picker: the installing note shows the archive name verbatim ($ sequences included)",
    busy.indexOf(S.freetpInstalling.split("{archive}").join(archiveName)) !== -1, true);
  if (finishInstall) finishInstall({ success: false, errorCode: "bad_archive" });
  await settle();

  // ── FreeTP: the download runs in the background and is polled ────────────
  let polls = 0;
  const busyAtPoll = [];
  const busyText = () => document.querySelectorAll(".lumen-fx-spin")
    .map((s) => s.parentNode.lastChild.textContent).join("|");
  await openMenu({
    LumenDownloadFreeTPFix: () => {
      busyAtPoll.push(busyText());
      return ++polls < 3 ? { success: true, pending: true }
        : { success: true, path: "/home/u/.local/share/Lumen/freetp_dl/322330-freetp-fix.exe", size: 10 };
    },
    LumenInstallFixArchive: () => ({ success: true, added: 2, replaced: 0 }),
  });
  tile(S.freetpLabel).click();
  await settle(60);
  eq("download: polled until the file is there, then installed",
    calls("LumenDownloadFreeTPFix").length === 3 && calls("LumenInstallFixArchive").length === 1
      && calls("LumenInstallFixArchive")[0].args.archivePath.endsWith("322330-freetp-fix.exe"), true);
  eq("download: the busy note says Searching until the file transfer starts, then Downloading",
    busyAtPoll.join(" / "), [S.freetpSearching, S.freetpDownloading, S.freetpDownloading].join(" / "));

  // ── Launch options after an install ──────────────────────────────────────
  // GetFixLaunchOptions answers apply:true with "" when the fix needs no
  // override and the options held only a stale one: "" must be written.
  const installed = (launch, relay) => openMenu({
    LumenDownloadFreeTPFix: () => ({ success: true,
      path: "/home/u/.local/share/Lumen/freetp_dl/322330-freetp-fix.exe", size: 10 }),
    LumenInstallFixArchive: () => ({ success: true, added: 2, replaced: 0 }),
    GetFixLaunchOptions: () => launch,
    __lumenSetLaunchOptions: () => relay,
  }).then(async () => { tile(S.freetpLabel).click(); await settle(60); });
  const pmsg = () => (document.getElementById("lumen-fx-pmsg") || {}).textContent || "";
  const installDone = S.freetpInstallDone.replace("{added}", 2).replace("{replaced}", 0);

  await installed({ success: true, apply: true, previousLaunchOptions: 'WINEDLLOVERRIDES="d3d12core=n,b" %command%',
    launchOptions: "" }, { ok: true });
  eq("launch options: apply with \"\" clears the stale options, then reports the install",
    calls("__lumenSetLaunchOptions").length === 1
      && calls("__lumenSetLaunchOptions")[0].args.options === "" && pmsg() === installDone, true);

  await installed({ success: true, apply: false, launchOptions: "%command%" }, { ok: true });
  eq("launch options: apply:false writes nothing",
    calls("__lumenSetLaunchOptions").length === 0 && pmsg() === installDone, true);

  await installed({ success: true, apply: true, launchOptions: "" }, { ok: false });
  eq("launch options: a failed \"\" write reports the failure, with no empty line to paste",
    calls("__lumenSetLaunchOptions").length === 1 && !document.querySelector(".lumen-fx-lo")
      && pmsg().indexOf(S.launchApplyFailed) !== -1, true);

  // ── Online Fix · No login: online-fix.me's torrent, then the mirror ────────
  const ofmePath = "/home/u/.local/share/Lumen/onlinefix_dl/322330/Fix Repair/fix.rar";
  // The busy overlay's message (its Cancel button, when there is one, comes last).
  const busyNote = () => document.querySelectorAll(".lumen-fx-spin")
    .map((s) => s.parentNode.childNodes[1].textContent).join("|");
  const busyCancel = () => {
    const spin = document.querySelector(".lumen-fx-spin");
    return spin && spin.parentNode.querySelector(".lumen-fx-btn");
  };
  let ofmePolls = 0;
  const ofmeBusyAtPoll = [];
  await openMenu({
    LumenStartOnlineFix: () => ({ success: true }),
    LumenOnlineFixStatus: () => {
      ofmeBusyAtPoll.push(busyNote());
      return ++ofmePolls < 3 ? { state: "downloading", bytes: 2048 } : { state: "done", path: ofmePath };
    },
    LumenInstallFixArchive: () => ({ success: true, added: 3, replaced: 0 }),
  });
  tile(S.fallbackOnlineLabel).click();
  await settle(60);
  eq("online: online-fix.me's torrent download is polled, then installed from its path",
    calls("LumenStartOnlineFix").length === 1 && calls("LumenOnlineFixStatus").length === 3
      && calls("LumenInstallFixArchive").length === 1
      && calls("LumenInstallFixArchive")[0].args.archivePath === ofmePath
      && calls("ResolveOnlineFix").length === 0 && calls("ApplyGameFix").length === 0, true);
  eq("online: the busy note says Downloading, then the bytes so far",
    ofmeBusyAtPoll.join(" / "),
    [S.onlineTorrentBusy, S.onlineTorrentBusy + " 2 KB", S.onlineTorrentBusy + " 2 KB"].join(" / "));
  eq("online: an installed online-fix.me fix ends reporting the install",
    pmsg(), S.freetpInstallDone.replace("{added}", 3).replace("{replaced}", 0));

  // Cancel stops the download for good: no mirror, no install, the tiles again.
  await openMenu({
    LumenStartOnlineFix: () => ({ success: true }),
    LumenOnlineFixStatus: () => ({ state: "downloading", bytes: 4096 }),
    LumenCancelOnlineFix: () => ({ success: true }),
    ResolveOnlineFix: () => ({ success: true, found: true, url: "https://mirror.example/fix.zip" }),
    ApplyGameFix: () => ({ success: true }),
    LumenInstallFixArchive: () => ({ success: true, added: 1, replaced: 0 }),
  });
  tile(S.fallbackOnlineLabel).click();
  await settle(4);
  const ofmeCancel = busyCancel();
  eq("online: the torrent download offers Cancel while it runs",
    !!ofmeCancel && ofmeCancel.textContent === S.cancel, true);
  const statusAtCancel = calls("LumenOnlineFixStatus").length;
  if (ofmeCancel) ofmeCancel.click();
  await settle(20);
  eq("online: Cancel stops the download and its polling, back to the tiles without the mirror",
    statusAtCancel > 0 && calls("LumenOnlineFixStatus").length === statusAtCancel
      && calls("LumenCancelOnlineFix").length === 1
      && calls("LumenCancelOnlineFix")[0].args.appid === 322330
      && calls("ResolveOnlineFix").length === 0 && calls("ApplyGameFix").length === 0
      && calls("LumenInstallFixArchive").length === 0
      && !busyCancel() && !!tile(S.fallbackOnlineLabel), true);

  await openMenu({
    LumenStartOnlineFix: () => ({ success: true }),
    LumenOnlineFixStatus: () => ({ state: "failed" }),
    ResolveOnlineFix: () => ({ success: true, found: true, url: "https://mirror.example/fix.zip" }),
    ApplyGameFix: () => ({ success: true }),
  });
  tile(S.fallbackOnlineLabel).click();
  await settle(8);
  eq("online: a torrent download that fails falls back to the mirror, with the fallback receipt",
    calls("ResolveOnlineFix").length === 1 && calls("ApplyGameFix").length === 1
      && calls("ApplyGameFix")[0].args.downloadUrl === "https://mirror.example/fix.zip"
      && calls("ApplyGameFix")[0].args.receiptKind === window.__lumenFixesFallbackReceiptKind()
      && calls("LumenInstallFixArchive").length === 0, true);
  overlay().querySelector(".lumen-fx-x").click();
  await settle(4);

  await openMenu({ LumenStartOnlineFix: () => ({ success: false, reason: "no_aria2" }) });
  tile(S.fallbackOnlineLabel).click();
  await settle(20);
  eq("online: without aria2 the mirror is tried, and its failure says aria2 is needed",
    calls("ResolveOnlineFix").length === 1 && calls("LumenOnlineFixStatus").length === 0
      && pmsg() === S.onlineNone + " " + S.onlineNoAria2, true);

  let ofmeStatus = 0;
  await openMenu({
    LumenStartOnlineFix: () => ({ success: true }),
    LumenOnlineFixStatus: () => { ofmeStatus++; return { state: "downloading", bytes: 1 }; },
    LumenInstallFixArchive: () => ({ success: true, added: 1, replaced: 0 }),
    ResolveOnlineFix: () => ({ success: true, found: true, url: "https://mirror.example/fix.zip" }),
    ApplyGameFix: () => ({ success: true }),
  });
  tile(S.fallbackOnlineLabel).click();
  await settle(4);
  overlay().querySelector(".lumen-fx-x").click();
  const ofmeAtClose = ofmeStatus;
  await settle(20);
  eq("online: a menu closed mid-download stops polling and installs nothing",
    ofmeAtClose > 0 && ofmeStatus <= ofmeAtClose + 1 && calls("LumenInstallFixArchive").length === 0
      && calls("ResolveOnlineFix").length === 0 && calls("ApplyGameFix").length === 0, true);

  // A status answer still in flight when the menu closes: the finished
  // download stays for the next click, nothing is installed with no menu.
  let finishStatus = null;
  await openMenu({
    LumenStartOnlineFix: () => ({ success: true }),
    LumenOnlineFixStatus: () => new Promise((resolve) => { finishStatus = resolve; }),
    LumenInstallFixArchive: () => ({ success: true, added: 1, replaced: 0 }),
    GetFixLaunchOptions: () => ({ success: true, apply: true,
      launchOptions: 'WINEDLLOVERRIDES="winmm=n,b" %command%' }),
    __lumenSetLaunchOptions: () => ({ ok: true }),
  });
  tile(S.fallbackOnlineLabel).click();
  await settle();
  overlay().querySelector(".lumen-fx-x").click();
  const launchAtStatusClose = calls("GetFixLaunchOptions").length;
  if (finishStatus) finishStatus({ state: "done", path: ofmePath });
  await settle();
  eq("online: a download answering done after the menu closed installs nothing",
    calls("LumenOnlineFixStatus").length === 1 && calls("LumenInstallFixArchive").length === 0
      && calls("GetFixLaunchOptions").length === launchAtStatusClose
      && calls("__lumenSetLaunchOptions").length === 0
      && calls("ResolveOnlineFix").length === 0 && calls("ApplyGameFix").length === 0, true);

  let finishMirror = null;
  await openMenu({
    LumenStartOnlineFix: () => ({ success: false }),
    ResolveOnlineFix: () => new Promise((resolve) => { finishMirror = resolve; }),
    ApplyGameFix: () => ({ success: true }),
  });
  tile(S.fallbackOnlineLabel).click();
  await settle();
  overlay().querySelector(".lumen-fx-x").click();
  if (finishMirror) finishMirror({ success: true, found: true, url: "https://mirror.example/fix.zip" });
  await settle();
  eq("online: a mirror found after the menu closed applies nothing",
    calls("ResolveOnlineFix").length === 1 && calls("ApplyGameFix").length === 0, true);

  // Lumen's own install record says online-fix.me: Applied, and a click only
  // sets the launch options again.
  await openMenu({
    LumenDetectLocalFix: () => ({ success: true, found: true, recorded: "onlinefix" }),
    LumenStartOnlineFix: () => ({ success: true }),
  });
  const recordedTile = tile(S.fallbackOnlineLabel);
  eq("online: an install recorded as online-fix.me's badges the tile Applied",
    !!recordedTile && recordedTile.classList.contains("applied")
      && (recordedTile.querySelector(".lumen-fx-badge") || {}).textContent === S.appliedBadge, true);
  const launchAtOpen = calls("GetFixLaunchOptions").length;
  if (recordedTile) recordedTile.click();
  await settle(60);
  eq("online: clicking the Applied tile only sets launch options, with no download",
    calls("GetFixLaunchOptions").length > launchAtOpen && calls("LumenStartOnlineFix").length === 0
      && calls("ResolveOnlineFix").length === 0 && pmsg() === S.onlineLaunchDone, true);

  // ── FreeTP: closing the menu mid-download ────────────────────────────────
  let finishDownload = null;
  await openMenu({
    LumenDownloadFreeTPFix: () => new Promise((resolve) => { finishDownload = resolve; }),
    LumenInstallFixArchive: () => ({ success: true, added: 1, replaced: 0 }),
    LumenDiscardFreeTPDownload: () => ({ success: true }),
  });
  tile(S.freetpLabel).click();
  await settle();
  overlay().querySelector(".lumen-fx-x").click();
  finishDownload({ success: true, path: "/home/u/.local/share/Lumen/freetp_dl/322330-freetp-fix.exe", size: 10 });
  await settle();
  eq("download: a menu closed before the file arrived installs nothing and discards the file",
    calls("LumenInstallFixArchive").length === 0
      && calls("LumenDiscardFreeTPDownload").length === 1
      && calls("LumenDiscardFreeTPDownload")[0].args.appid === 322330, true);

  polls = 0;
  await openMenu({
    LumenDownloadFreeTPFix: () => { polls++; return { success: true, pending: true }; },
    LumenDiscardFreeTPDownload: () => ({ success: true }),
  });
  tile(S.freetpLabel).click();
  await settle(4);
  overlay().querySelector(".lumen-fx-x").click();
  const pollsAtClose = polls;
  await settle(20);
  eq("download: polling stops once the menu is closed, and the job is discarded",
    polls <= pollsAtClose + 1 && calls("LumenDiscardFreeTPDownload").length === 1
      && calls("LumenInstallFixArchive").length === 0, true);

  if (failures) { console.error("\n" + failures + " failed"); process.exit(1); }
  console.log("\nall ok");
})().catch((e) => { console.error("FAIL " + (e && e.stack || e)); process.exit(1); });
