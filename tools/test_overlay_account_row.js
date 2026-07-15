// Run: node tools/test_overlay_account_row.js
//
// Two things the sidebar account row and the tab warm-up have to get right, both
// consequences of the backend being one call deep at a time:
//   * the row must not claim "signed out" while the auth status is still queued;
//   * closing the window must stop it queueing more work, or reopening waits
//     behind a manifest scan and a network version check before it can happen.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

class El {
  constructor(tag) {
    this.tagName = String(tag || "div").toUpperCase();
    this.childNodes = [];
    this.parentNode = null;
    this.className = "";
    this.style = {};
    this.listeners = {};
    this.id = "";
    this.title = "";
  }
  appendChild(child) { child.parentNode = this; this.childNodes.push(child); return child; }
  remove() {
    if (!this.parentNode) return;
    const index = this.parentNode.childNodes.indexOf(this);
    if (index !== -1) this.parentNode.childNodes.splice(index, 1);
    this.parentNode = null;
  }
  set textContent(value) { this.childNodes = []; this._text = String(value == null ? "" : value); }
  get textContent() {
    return (this._text || "") + this.childNodes.map((child) => child.textContent).join("");
  }
  set innerHTML(value) { this._html = String(value || ""); }
  get innerHTML() { return this._html || ""; }
  addEventListener(type, handler) { (this.listeners[type] = this.listeners[type] || []).push(handler); }
  setAttribute(name, value) { this[name] = String(value); }
  click() {
    (this.listeners.click || []).forEach((handler) => handler({
      target: this, stopPropagation() {}, preventDefault() {},
    }));
  }
  get classList() {
    const self = this;
    const classes = () => new Set(self.className.split(/\s+/).filter(Boolean));
    return {
      add(...names) { const c = classes(); names.forEach((n) => c.add(n)); self.className = [...c].join(" "); },
      remove(...names) { const c = classes(); names.forEach((n) => c.delete(n)); self.className = [...c].join(" "); },
      toggle(name, on) { if (on) this.add(name); else this.remove(name); },
      contains(name) { return classes().has(name); },
    };
  }
}

function walk(node, output = []) {
  for (const child of node.childNodes) { output.push(child); walk(child, output); }
  return output;
}
const byClass = (node, name) =>
  walk(node).filter((el) => el.className.split(/\s+/).includes(name));
const byId = (node, id) => [node].concat(walk(node)).find((el) => el.id === id) || null;
const tick = () => new Promise((resolve) => setImmediate(resolve));

function open(options = {}) {
  const fragment = fs.readFileSync(
    path.join(__dirname, "..", "lua", "menu", "09-overlay.js"), "utf8");
  const root = new El("html");
  const body = new El("body");
  root.appendChild(body);
  const calls = [];
  const deferred = {};
  const window = { __lumenCloud: false, __lumenNoPlugin: false };
  const document = {
    body, documentElement: root,
    createElement: (tag) => new El(tag),
    getElementById: (id) => byId(root, id),
    addEventListener() {},
  };
  const strings = { reset: "Reset", restart: "Restart", about: { tab: "About", title: "About" } };
  const account = {
    fixesTab: "Fixes", accountTitle: "lua.tools account", back: "Back",
    signIn: "Sign in to lua.tools", unlock: "Unlock fixes.", connected: "Connected",
    checking: "Checking your account\u2026",
  };
  const source = [
    "(function(){",
    "var OVERLAY_ID='lumen-settings-overlay';",
    "var I18N={en:" + JSON.stringify(strings) + "};",
    "var MOON_SVG='', GU_SVG='', CLOUD_SVG='', ABOUT_SVG='', LUA_TOOLS_FIXES_SVG='',",
    "    LUA_TOOLS_BACK_SVG='', LUA_TOOLS_USER_SVG='<svg/>';",
    "function luaToolsLogoImage(cls){var i=document.createElement('img');",
    "  i.className=cls||'';return i;}",
    "var _guClearBtnRef=null;",
    "function pickLang(){return 'en';}",
    "function injectStyles(){}",
    "function applyAdaptivePalette(){}",
    "var THEMES_SVG='';",
    "function themeStrings(){return {tab:'Themes',title:'Themes'};}",
    "function renderThemes(body){body.textContent='THEMES';}",
    "function requestClose(){}",
    "function closeOverlay(){}",
    "function log(){}",
    "function luaToolsStrings(){return " + JSON.stringify(account) + ";}",
    "function luaToolsParse(v){try{return typeof v==='string'?JSON.parse(v):v;}catch(e){return null;}}",
    "function guStrings(){return {tab:'Game Updates',title:'Game Updates',experimental:'x',experimentalHint:'',clearManifests:'Clear',clearHint:'',clearConfirm:'C',clearFail:'F'};}",
    "function cloudStrings(){return {tab:'Cloud',title:'Cloud'};}",
    "function renderConfig(body){body.textContent='CONFIG';call('LumenGetPluginPrefs',{});}",
    "function renderGameUpdates(body){body.textContent='GU';return call('GetGameUpdates',{});}",
    "function reloadGameUpdates(body){return renderGameUpdates(body);}",
    "function revalidateGameUpdates(){}",
    "function guSetTabActive(){}",
    "function renderCloud(body){return call('LumenCloudStatus',{});}",
    "function renderAbout(body){return call('GetAboutVersions',{});}",
    "function renderLuaToolsFixes(body){return call('GetLuaToolsFixesCatalogue',{});}",
    "function renderLuaToolsAccount(body,hooks){return call('GetLuaToolsAuthStatus',{});}",
    "function showConfirm(){}",
    "function call(fn,args){return window.__call(fn,args||{});}",
    fragment,
    "})();",
  ].join("\n");
  window.__call = (name) => {
    calls.push(name);
    if (name === "GetSlsConfig") {
      return new Promise((resolve) => { deferred.sls = resolve; });
    }
    if (name === "GetLuaToolsAuthStatus") {
      if (options.holdAuth) return new Promise((resolve) => { deferred.auth = resolve; });
      return Promise.resolve(JSON.stringify({
        success: true, configured: true, account: { displayName: "SWay", avatarUrl: "" },
      }));
    }
    return Promise.resolve(JSON.stringify({ success: true, schema: [], values: {} }));
  };
  vm.runInNewContext(source,
    { window, document, Promise, JSON, Error, setTimeout: () => 0, clearTimeout() {} },
    { filename: "overlay.js" });
  window.__lumenOpenOverlay();
  return { root, calls, deferred, window, document };
}

async function main() {
  // ── the account row while the status is still queued ───────────────────────
  {
    const { root, deferred } = open({ holdAuth: true });
    const row = byClass(root, "lumen-account-entry")[0];
    assert.ok(row, "the sidebar has an account row");
    assert.ok(row.className.includes("checking"),
      "the row starts in its checking state");
    assert.ok(!row.textContent.includes("Sign in to lua.tools"),
      "a queued status must not be reported as signed out: " + row.textContent);
    assert.ok(row.textContent.includes("Checking your account"),
      "the row says it is checking: " + row.textContent);
    assert.strictEqual(byClass(row, "lumen-spin").length, 1,
      "the shared spinner stands in for the avatar while checking");

    // Answering it later is what settles the row (covered below); nothing about
    // the row may change while the call is still outstanding.
    deferred.sls(JSON.stringify({ success: true, schema: [], values: {} }));
    for (let i = 0; i < 6; i++) await tick();
    assert.ok(row.className.includes("checking") && !row.className.includes("connected"),
      "an unanswered status leaves the row checking: " + row.className);
  }

  // ── a connected answer settles the row ─────────────────────────────────────
  {
    const { root, deferred } = open();
    deferred.sls(JSON.stringify({ success: true, schema: [], values: {} }));
    await tick(); await tick(); await tick();
    const row = byClass(root, "lumen-account-entry")[0];
    assert.ok(!row.className.includes("checking"),
      "the checking state is dropped once the status lands");
    assert.ok(row.className.includes("connected"),
      "a configured account marks the row connected: " + row.className);
    assert.ok(row.textContent.includes("SWay") && row.textContent.includes("Connected"),
      "the row shows the account: " + row.textContent);
  }

  // ── closing stops the warm-up from queueing more backend work ──────────────
  {
    const { root, calls, deferred } = open();
    const overlay = byId(root, "lumen-settings-overlay");
    assert.ok(overlay, "the overlay is in the document");
    overlay.remove();                        // what closeOverlay() does
    deferred.sls(JSON.stringify({ success: true, schema: [], values: {} }));
    for (let i = 0; i < 8; i++) await tick();
    assert.ok(!calls.includes("GetGameUpdates"),
      "a closed window must not queue the manifest scan: " + calls.join(", "));
    assert.ok(!calls.includes("GetAboutVersions"),
      "a closed window must not queue the version check: " + calls.join(", "));
  }

  // ── and it still warms them while it is open ───────────────────────────────
  {
    const { calls, deferred } = open();
    deferred.sls(JSON.stringify({ success: true, schema: [], values: {} }));
    for (let i = 0; i < 8; i++) await tick();
    assert.ok(calls.includes("GetGameUpdates") && calls.includes("GetAboutVersions"),
      "an open window still preloads its tabs: " + calls.join(", "));
  }

  console.log("ok   the account row reports checking, and a closed window queues no more work");
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
