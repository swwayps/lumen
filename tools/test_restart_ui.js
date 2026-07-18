// DOM contract for the native Restart Steam action in the settings header.
// Run: node tools/test_restart_ui.js
"use strict";

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
  appendChild(child) {
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }
  remove() {
    if (!this.parentNode) return;
    const index = this.parentNode.childNodes.indexOf(this);
    if (index !== -1) this.parentNode.childNodes.splice(index, 1);
    this.parentNode = null;
  }
  set textContent(value) {
    this.childNodes = [];
    this._text = String(value == null ? "" : value);
  }
  get textContent() {
    return (this._text || "") + this.childNodes.map((child) => child.textContent).join("");
  }
  set innerHTML(value) { this._html = String(value || ""); }
  addEventListener(type, handler) {
    (this.listeners[type] = this.listeners[type] || []).push(handler);
  }
  click() {
    (this.listeners.click || []).forEach((handler) => handler({
      target: this,
      stopPropagation() {},
      preventDefault() {},
    }));
  }
  get classList() {
    const self = this;
    return {
      add(...names) {
        const classes = new Set(self.className.split(/\s+/).filter(Boolean));
        names.forEach((name) => classes.add(name));
        self.className = [...classes].join(" ");
      },
      remove(...names) {
        const removed = new Set(names);
        self.className = self.className.split(/\s+/)
          .filter((name) => name && !removed.has(name)).join(" ");
      },
      toggle(name, enabled) {
        if (enabled) this.add(name); else this.remove(name);
      },
      contains(name) {
        return self.className.split(/\s+/).includes(name);
      },
    };
  }
}

function walk(node, output = []) {
  for (const child of node.childNodes) {
    output.push(child);
    walk(child, output);
  }
  return output;
}
function byClass(node, name) {
  return walk(node).filter((el) => el.className.split(/\s+/).includes(name));
}
function byId(node, id) {
  return [node].concat(walk(node)).find((el) => el.id === id) || null;
}
function tick() {
  return new Promise((resolve) => setImmediate(resolve));
}

function run(restartResponse) {
  const fragment = fs.readFileSync(
    path.join(__dirname, "..", "lua", "menu", "09-overlay.js"), "utf8");
  const root = new El("html");
  const body = new El("body");
  root.appendChild(body);
  const calls = [];
  const confirms = [];
  const window = { __lumenCloud: false };
  const document = {
    body,
    documentElement: root,
    createElement: (tag) => new El(tag),
    getElementById: (id) => byId(root, id),
    addEventListener() {},
  };
  const strings = {
    reset: "Reset to defaults",
    resetConfirm: "Click again to confirm",
    resetFail: "Reset failed: ",
    restart: "Restart Steam",
    restartTitle: "Restart Steam?",
    restartBody: "Steam will close and reopen through slsteam-moon.",
    restartConfirm: "Restart Steam",
    restartCancel: "Cancel",
    restartFailTitle: "Could not restart Steam",
    restartFail: "Restart failed: ",
    about: { tab: "About", title: "About" },
  };
  const source = [
    "(function(){",
    "var OVERLAY_ID='lumen-overlay';",
    "var I18N={en:" + JSON.stringify(strings) + "};",
    "var MOON_SVG='', GU_SVG='', CLOUD_SVG='', ABOUT_SVG='';",
    "var _guClearBtnRef=null;",
    "function pickLang(){return 'en';}",
    "function injectStyles(){}",
    "function requestClose(){}",
    "function closeOverlay(){}",
    "function guStrings(){return {tab:'Game Updates',title:'Game Updates',experimental:'Experimental',experimentalHint:'',clearManifests:'Clear',clearHint:'',clearConfirm:'Confirm',clearFail:'Failed'};}",
    "function cloudStrings(){return {tab:'Cloud',title:'Cloud'};}",
    "function renderConfig(){}",
    "function renderGameUpdates(){}",
    "function renderCloud(){}",
    "function renderAbout(){}",
    "function showConfirm(opts){window.__confirms.push(opts);}",
    "function call(fn,args){return window.__call(fn,args||{});}",
    fragment,
    "})();",
  ].join("\n");
  window.__confirms = confirms;
  window.__call = (name, args) => {
    calls.push({ name, args });
    if (name === "GetSlsConfig") {
      return Promise.resolve(JSON.stringify({ success: true, schema: [], values: {} }));
    }
    if (name === "RestartSteam") {
      return Promise.resolve(JSON.stringify(
        restartResponse || { success: true }));
    }
    return Promise.resolve(JSON.stringify({ success: true, schema: [], values: {} }));
  };

  vm.runInNewContext(source, {
    window, document, Promise, JSON, Error,
    setTimeout: () => 0,
    clearTimeout() {},
  }, { filename: "restart-overlay.js" });
  window.__lumenOpenOverlay();
  return { root, calls, confirms };
}

async function main() {
  {
    const { root, calls, confirms } = run();
    const restart = byClass(root, "lumen-restart")[0];
    const reset = byClass(root, "reset").find(
      (el) => el !== restart && el.textContent === "Reset to defaults");
    if (!restart || !reset) throw new Error("restart and reset controls must render");
    if (!restart.classList.contains("reset")) {
      throw new Error("restart must reuse the reset control's visual style");
    }
    const header = byClass(root, "lumen-ctop")[0];
    if (header.childNodes.indexOf(restart) + 1 !== header.childNodes.indexOf(reset)) {
      throw new Error("restart must sit immediately left of reset");
    }

    restart.click();
    if (confirms.length !== 1
        || confirms[0].title !== "Restart Steam?"
        || confirms[0].declineText !== "Cancel"
        || typeof confirms[0].onConfirm !== "function") {
      throw new Error("restart click must open a cancellable confirmation modal");
    }
    confirms[0].onConfirm();
    confirms[0].onConfirm();
    await tick();
    if (calls.filter((call) => call.name === "RestartSteam").length !== 1) {
      throw new Error("confirmation must call the native RestartSteam RPC only once");
    }

    const tabs = byClass(root, "lumen-tab");
    tabs[tabs.length - 1].click();
    if (restart.style.display !== "none") {
      throw new Error("restart is visible only on the slsteam-moon tab");
    }
    tabs[0].click();
    if (restart.style.display === "none") {
      throw new Error("restart returns with the slsteam-moon tab");
    }
  }

  {
    const { root, confirms } = run({ success: false, error: "launcher missing" });
    byClass(root, "lumen-restart")[0].click();
    confirms[0].onConfirm();
    await tick();
    await tick();
    if (confirms.length !== 2
        || confirms[1].title !== "Could not restart Steam"
        || !confirms[1].body.includes("launcher missing")) {
      throw new Error("restart failure must be acknowledged with the backend error");
    }
  }

  console.log("test_restart_ui: ok");
}

main().catch((error) => {
  console.error("FAIL:", error.message);
  process.exit(1);
});
