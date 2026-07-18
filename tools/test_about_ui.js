// DOM-level contract for the About channel selector. The fragment is executed
// inside its real shared closure with only the transport and i18n stubbed.
// Run: node tools/test_about_ui.js
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
    this.attributes = {};
    this.listeners = {};
  }
  appendChild(child) { child.parentNode = this; this.childNodes.push(child); return child; }
  remove() {
    if (!this.parentNode) return;
    const i = this.parentNode.childNodes.indexOf(this);
    if (i !== -1) this.parentNode.childNodes.splice(i, 1);
    this.parentNode = null;
  }
  set textContent(value) { this.childNodes = []; this._text = String(value == null ? "" : value); }
  get textContent() {
    return (this._text || "") + this.childNodes.map((c) => c.textContent).join("");
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name]; }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  click() { (this.listeners.click || []).forEach((fn) => fn({ target: this })); }
  get classList() {
    const self = this;
    return {
      add(...names) {
        const set = new Set(self.className.split(/\s+/).filter(Boolean));
        names.forEach((n) => set.add(n)); self.className = [...set].join(" ");
      },
      remove(...names) {
        const drop = new Set(names);
        self.className = self.className.split(/\s+/).filter((n) => n && !drop.has(n)).join(" ");
      },
      contains(name) { return self.className.split(/\s+/).includes(name); },
    };
  }
}

function walk(node, out = []) {
  for (const child of node.childNodes) { out.push(child); walk(child, out); }
  return out;
}
function byClass(node, name) {
  return walk(node).filter((el) => el.className.split(/\s+/).includes(name));
}
function buttons(node) { return walk(node).filter((el) => el.tagName === "BUTTON"); }
function rowNamed(body, name) {
  return byClass(body, "lumen-about-ver").find((row) => row.textContent.includes(name));
}
function tick() { return new Promise((resolve) => setImmediate(resolve)); }

async function main() {
  const fragment = fs.readFileSync(
    path.join(__dirname, "..", "lua", "menu", "08-about-tab.js"), "utf8");
  const styles = fs.readFileSync(
    path.join(__dirname, "..", "lua", "menu", "03-styles.js"), "utf8");
  if (!styles.includes(".lumen-channel-card-control{flex:0 0 103px;width:103px;")
      || !styles.includes(".lumen-channel-card-control .lumen-channel{width:100%;height:38px;")
      || !styles.includes(".lumen-channel-card-control .lumen-channel-option{flex:1 1 50%;")) {
    throw new Error("Global selector must match Update All and split into equal halves");
  }
  const calls = [];
  const saveResolvers = [];
  let versionLoads = 0;
  let serverChannel = "stable";
  const stableComponents = [
    { key: "slsteam_moon", name: "slsteam-moon", installed: "v2.7", latest: "v2.7",
      state: "current", channel: "stable", betaAvailable: true,
      channelStates: { stable: "current", beta: "update" } },
    { key: "plugin", name: "LuaTools plugin", installed: "v2.7", latest: "v2.7",
      state: "current", channel: "stable", betaAvailable: false,
      channelStates: { stable: "current", beta: "current" } },
    { key: "lumen", name: "Lumen", installed: "v2.7", latest: "beta",
      state: "current", channel: "stable", betaAvailable: true,
      channelStates: { stable: "current", beta: "update" } },
  ];
  function componentsFor(channel) {
    return stableComponents.map((component) => {
      const effective = channel === "beta" && component.betaAvailable ? "beta" : "stable";
      return Object.assign({}, component, {
        channel: effective,
        state: component.channelStates[effective],
      });
    });
  }

  const body = new El("div");
  const document = {
    body: new El("body"), documentElement: new El("html"),
    createElement: (tag) => new El(tag),
  };
  const window = {
    __call(fn, args) {
      calls.push({ fn, args });
      if (fn === "GetAboutVersions") {
        versionLoads += 1;
        return Promise.resolve(JSON.stringify({
          success: true,
          channel: serverChannel,
          components: componentsFor(serverChannel),
        }));
      }
      if (fn === "SetAboutChannel") {
        const requested = JSON.parse(args.json).channel;
        return new Promise((resolve) => {
          saveResolvers.push(() => {
            serverChannel = requested;
            resolve(JSON.stringify({ success: true }));
          });
        });
      }
      if (fn === "UpdateAll") return Promise.resolve(JSON.stringify({ success: true }));
      return Promise.reject(new Error("unexpected RPC " + fn));
    },
  };
  const I18N = { en: { about: {
    intro: "versions", installed: "installed", latest: "latest", unknown: "unknown",
    upToDate: "up to date", updateAvailable: "update available", stable: "Stable",
    beta: "Beta", channelSaveFail: "Could not save channel: ", updateTitle: "Updates",
    channelTitle: "Update channel", channelDesc: "Use one channel for every component.",
    updateDesc: "Update components", updateBtn: "Update All", updateOpenedTitle: "Updating",
    updateOpenedBody: "Opened", updateNoTerm: "No terminal", updateFail: "Failed: ", ok: "OK",
  } } };

  const source = [
    "(function(){",
    "var I18N = " + JSON.stringify(I18N) + ";",
    "function pickLang(){return 'en';}",
    "function log(){}",
    "function call(fn,args){return window.__call(fn,args||{});}",
    fragment,
    "window.__aboutTest={renderAbout:renderAbout};",
    "})();",
  ].join("\n");
  vm.runInNewContext(source, {
    window, document, console, Promise, JSON,
    setTimeout, clearTimeout,
  }, { filename: "about-fragment.js" });

  window.__aboutTest.renderAbout(body);
  await tick(); await tick();

  const sls = rowNamed(body, "slsteam-moon");
  const plugin = rowNamed(body, "LuaTools plugin");
  const lumen = rowNamed(body, "Lumen");
  if (!sls || !plugin || !lumen) throw new Error("component rows were not rendered");

  for (const row of [sls, plugin, lumen]) {
    const indicator = byClass(row, "lumen-channel")[0];
    if (!indicator || !indicator.classList.contains("single")
        || buttons(indicator).length !== 0
        || !indicator.textContent.includes("Stable")) {
      throw new Error("Each component must render a non-interactive Stable indicator");
    }
  }

  const cards = byClass(body, "lumen-about-act");
  if (cards.length !== 2
      || !cards[0].textContent.includes("Update channel")
      || !cards[1].textContent.includes("Updates")) {
    throw new Error("Global channel card must render immediately above Updates");
  }

  const selectors = byClass(body, "lumen-channel").filter(
    (el) => !el.classList.contains("single"));
  if (selectors.length !== 1) {
    throw new Error("About must render exactly one interactive channel selector");
  }
  const selector = selectors[0];
  const options = selector && buttons(selector);
  if (!options || options.length !== 2) {
    throw new Error("Global channel selector must render Stable and Beta");
  }
  if (options[0].getAttribute("aria-pressed") !== "true"
      || options[1].getAttribute("aria-pressed") !== "false") {
    throw new Error("channel selector must expose its active state with aria-pressed");
  }

  options[1].click();
  const indicatorText = (row) => byClass(row, "lumen-channel")[0].textContent;
  if (!indicatorText(sls).includes("Beta")
      || !indicatorText(plugin).includes("Stable")
      || !indicatorText(lumen).includes("Beta")) {
    throw new Error("Beta click must update effective channel indicators immediately");
  }
  const stateText = (row) => byClass(row, "lumen-about-state")[0].textContent;
  if (!stateText(sls).includes("update available")
      || !stateText(plugin).includes("up to date")
      || !stateText(lumen).includes("update available")) {
    throw new Error("Beta click must update availability pills immediately");
  }
  await tick();
  const save = calls.find((c) => c.fn === "SetAboutChannel");
  const saved = save && JSON.parse(save.args.json);
  if (!saved || saved.channel !== "beta" || Object.prototype.hasOwnProperty.call(saved, "key")) {
    throw new Error("choosing Beta must persist one global channel");
  }

  const update = byClass(body, "lumen-about-btn")[0];
  update.click();
  await tick();
  if (calls.some((c) => c.fn === "UpdateAll")) {
    throw new Error("Update All must wait for an in-flight channel save");
  }

  saveResolvers[0]();
  await tick(); await tick();
  if (!calls.some((c) => c.fn === "UpdateAll")) {
    throw new Error("Update All must run after the channel save completes");
  }
  if (versionLoads < 2) {
    throw new Error("saving the global channel must refresh effective component channels");
  }

  if (!indicatorText(sls).includes("Beta")
      || !indicatorText(plugin).includes("Stable")
      || !indicatorText(lumen).includes("Beta")) {
    throw new Error("component indicators must show effective channels after fallback");
  }

  options[0].click();
  if (!indicatorText(sls).includes("Stable")
      || !indicatorText(plugin).includes("Stable")
      || !indicatorText(lumen).includes("Stable")
      || !stateText(sls).includes("up to date")
      || !stateText(plugin).includes("up to date")
      || !stateText(lumen).includes("up to date")) {
    throw new Error("Stable click must restore indicators and pills immediately");
  }
  await tick();
  const saves = calls.filter((c) => c.fn === "SetAboutChannel");
  if (saves.length !== 2 || JSON.parse(saves[1].args.json).channel !== "stable") {
    throw new Error("returning to Stable must persist the global channel");
  }
  saveResolvers[1]();
  await tick(); await tick();

  console.log("test_about_ui: ok");
}

main().catch((err) => { console.error("FAIL:", err.message); process.exit(1); });
