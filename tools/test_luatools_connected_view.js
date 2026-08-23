const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

class FakeElement {
  constructor(tagName) {
    this.tagName = String(tagName || "").toUpperCase();
    this.children = [];
    this.attributes = {};
    this.listeners = {};
    this.className = "";
    this.type = "";
    this.checked = false;
    this.disabled = false;
    this._textContent = "";
    this.innerHTML = "";
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }

  addEventListener(name, listener) {
    this.listeners[name] = listener;
  }

  set textContent(value) {
    this._textContent = String(value || "");
    this.children = [];
  }

  get textContent() {
    return this._textContent + this.children.map((child) => child.textContent || "").join("");
  }
}

function descendants(root) {
  return [root].concat(root.children.flatMap(descendants));
}

const context = {
  document: { createElement: (tagName) => new FakeElement(tagName) },
  lang: "en",
  pickLang() { return context.lang; },
  window: {},
};
vm.runInNewContext(
  fs.readFileSync("lua/menu/09-luatools-account.js", "utf8"),
  context,
  { filename: "09-luatools-account.js" },
);

assert.strictEqual(
  typeof context.luaToolsBuildConnectedAccount,
  "function",
  "connected account view should have a dedicated component builder",
);

const retentionChanges = [];
let logoutCount = 0;
const view = context.luaToolsBuildConnectedAccount(
  { account: { displayName: "SWay", avatarUrl: "" } },
  {
    keepSignedIn: false,
    onKeepChange: (keepSignedIn) => retentionChanges.push(keepSignedIn),
    onLogout: () => { logoutCount += 1; },
  },
);
const elements = descendants(view.node);
const buttons = elements.filter((node) => node.tagName === "BUTTON");
const checkboxes = elements.filter((node) => node.tagName === "INPUT" && node.type === "checkbox");

assert.strictEqual(buttons.length, 1, "connected view should expose only the sign-out button");
assert.strictEqual(checkboxes.length, 1, "Discord retention should be a single switch");
assert.strictEqual(checkboxes[0].checked, false, "Discord retention should reflect the safer default");
assert.match(view.node.textContent, /Discord in Steam/);
assert.match(
  view.node.textContent,
  /Keeps Discord signed in to Steam's internal browser\. Enable this only when necessary\./,
);
assert.doesNotMatch(view.node.textContent, /Ryuu|OAuth|MFA/i);

checkboxes[0].checked = true;
checkboxes[0].listeners.change();
assert.deepStrictEqual(retentionChanges, [true], "switch should report the requested retention state");
buttons[0].listeners.click();
assert.strictEqual(logoutCount, 1, "the remaining button should sign out of lua.tools");

context.lang = "pt-BR";
const portuguese = context.luaToolsBuildConnectedAccount(
  { account: { displayName: "SWay", avatarUrl: "" } },
  { keepSignedIn: false, onKeepChange() {}, onLogout() {} },
);
assert.match(portuguese.node.textContent, /Discord no Steam/);
assert.match(
  portuguese.node.textContent,
  /Mantém o Discord conectado no navegador interno do Steam\. Ative esta opção somente se necessário\./,
);

console.log("ok   connected lua.tools account uses one clear Discord-retention control");
