// Regression coverage for the restart warning attached to the parental-control
// setting. Run: node tools/test_parental_restart_ui.js
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
    this.checked = false;
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
    return (this._text || "")
      + this.childNodes.map((child) => child.textContent).join("");
  }
  set innerHTML(value) { this._html = String(value || ""); }
  addEventListener(type, handler) {
    (this.listeners[type] = this.listeners[type] || []).push(handler);
  }
  dispatch(type) {
    (this.listeners[type] || []).forEach((handler) => handler({
      target: this,
      stopPropagation() {},
      preventDefault() {},
    }));
  }
  click() { this.dispatch("click"); }
  setAttribute(name, value) { this[name] = String(value); }
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
      contains(name) { return self.className.split(/\s+/).includes(name); },
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
function byTag(node, tag) {
  return walk(node).filter((el) => el.tagName === tag.toUpperCase());
}
function byId(node, id) {
  return [node].concat(walk(node)).find((el) => el.id === id) || null;
}
function tick() {
  return new Promise((resolve) => setImmediate(resolve));
}

const MENU_DIR = path.join(__dirname, "..", "lua", "menu");
const fragment = (name) => fs.readFileSync(path.join(MENU_DIR, name), "utf8");

function run(language) {
  const root = new El("html");
  const body = new El("body");
  root.appendChild(body);
  const window = {};
  const calls = [];
  let persisted = false;
  const document = {
    body,
    documentElement: root,
    createElement: (tag) => new El(tag),
    getElementById: (id) => byId(root, id),
  };
  window.__call = (name, args) => {
    calls.push({ name, args });
    if (name === "SetSlsConfig") {
      persisted = JSON.parse(args.json).value;
    }
    if (name === "LumenGetPluginPrefs") {
      return Promise.resolve(JSON.stringify({
        success: true,
        prefs: { fixes_menu_enabled: true },
      }));
    }
    return Promise.resolve(JSON.stringify({ success: true }));
  };

  const source = [
    "(function(){",
    fragment("02-i18n.js"),
    "function injectStyles(){}",
    "function addLine(){}",
    "function log(){}",
    "function call(fn,args){return window.__call(fn,args||{});}",
    fragment("05-config-tab.js"),
    fragment("06-updates-helpers.js"),
    "window.__renderConfigForTest=renderConfig;",
    "})();",
  ].join("\n");

  vm.runInNewContext(source, {
    window,
    document,
    navigator: { language },
    Promise,
    JSON,
    Error,
    Date,
    console,
  }, { filename: "parental-restart-ui.js" });

  window.__renderConfigForTest(body, {
    schema: [{
      key: "DisableParentalRestrictions",
      type: "bool",
      default: false,
      level: "normal",
      restart_on_change: true,
    }],
    values: { DisableParentalRestrictions: false },
  });
  return { root, body, window, calls, getPersisted: () => persisted };
}

function modal(root) {
  return byClass(root, "lumen-modal-back")[0] || null;
}
function button(root, label) {
  return byTag(root, "button").find((candidate) => candidate.textContent === label);
}

async function main() {
  const ptDescription = "Isso deixa as paginas internas da steam desautenticadas, "
    + "SÓ ATIVE ESSA OPÇÃO SE SUA CONTA DE FATO ESTIVER COM RESTRIÇÕES PARENTAIS.";
  const ptWarning = "Isso deixará as paginas internas (como a loja, comunidade e outros) "
    + "da steam desautenticadas, SÓ ATIVE ESSA OPÇÃO SE SUA CONTA DE FATO ESTIVER "
    + "COM RESTRIÇÕES PARENTAIS.";

  const state = run("pt-BR");
  const description = byClass(state.body, "lumen-desc")[0];
  if (!description || !description.textContent.includes(ptDescription)) {
    throw new Error("the parental setting must show the requested pt-BR warning");
  }

  const checkbox = byTag(state.body, "input")[0];
  checkbox.checked = true;
  checkbox.dispatch("change");
  await tick();
  if (!state.getPersisted()) throw new Error("enabling must be saved before prompting");
  let prompt = modal(state.root);
  if (!prompt || !prompt.textContent.includes(ptWarning)) {
    throw new Error("enabling must open the restart modal with the parental warning");
  }
  const later = button(prompt, "Depois");
  if (!later) throw new Error("the restart modal must offer Later");
  later.click();
  if (modal(state.root)) throw new Error("Later must dismiss the restart modal");

  checkbox.checked = false;
  checkbox.dispatch("change");
  await tick();
  if (state.getPersisted()) {
    throw new Error("disabling after Later must persist false");
  }
  prompt = modal(state.root);
  if (!prompt || !prompt.textContent.includes(ptWarning)) {
    throw new Error("disabling must still offer the restart needed to apply the change");
  }
  button(prompt, "Depois").click();
  if (state.getPersisted()) throw new Error("Later must never restore the enabled value");

  const writes = state.calls.filter((call) => call.name === "SetSlsConfig")
    .map((call) => JSON.parse(call.args.json).value);
  if (JSON.stringify(writes) !== JSON.stringify([true, false])) {
    throw new Error("the UI must save both toggle transitions in order");
  }
  if (state.calls.some((call) => call.name === "RestartSteam")) {
    throw new Error("Later must not restart Steam");
  }

  const restartState = run("en");
  const restartCheckbox = byTag(restartState.body, "input")[0];
  restartCheckbox.checked = true;
  restartCheckbox.dispatch("change");
  await tick();
  const restartPrompt = modal(restartState.root);
  const restart = restartPrompt && button(restartPrompt, "Restart Steam");
  if (!restart) throw new Error("the modal must offer Restart Steam");
  restart.click();
  await tick();
  if (restartState.calls.filter((call) => call.name === "RestartSteam").length !== 1) {
    throw new Error("Restart Steam must invoke the native restart RPC exactly once");
  }

  console.log("test_parental_restart_ui: ok");
}

main().catch((error) => {
  console.error("FAIL:", error.message);
  process.exit(1);
});
