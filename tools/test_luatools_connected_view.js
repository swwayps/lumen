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

let logoutCount = 0;
const view = context.luaToolsBuildConnectedAccount(
  { account: { displayName: "SWay", avatarUrl: "" } },
  { onLogout: () => { logoutCount += 1; } },
);
const elements = descendants(view.node);
const buttons = elements.filter((node) => node.tagName === "BUTTON");
const checkboxes = elements.filter((node) => node.tagName === "INPUT" && node.type === "checkbox");

// Once connected there is nothing left to decide: the Discord-cleanup preference
// belongs to the sign-in choice that uses it, and it already ran. The screen
// states who you are and offers the one action that still applies.
assert.strictEqual(buttons.length, 1, "connected view should expose only the sign-out button");
assert.strictEqual(checkboxes.length, 0, "connected view should carry no settings switch");
assert.doesNotMatch(view.node.textContent, /Discord in Steam/);
assert.doesNotMatch(view.node.textContent, /Keeps Discord signed in/);
assert.match(view.node.textContent, /SWay/);
assert.match(view.node.textContent, /Connected/);
assert.match(view.node.textContent, /Sign out of lua\.tools/);
assert.doesNotMatch(view.node.textContent, /Ryuu|OAuth|MFA/i);

buttons[0].listeners.click();
assert.strictEqual(logoutCount, 1, "the remaining button should sign out of lua.tools");

context.lang = "pt-BR";
const portuguese = context.luaToolsBuildConnectedAccount(
  { account: { displayName: "SWay", avatarUrl: "" } },
  { onLogout() {} },
);
assert.match(portuguese.node.textContent, /Conectado/);
assert.match(portuguese.node.textContent, /Sair do lua\.tools/);
assert.doesNotMatch(portuguese.node.textContent, /Discord no Steam/);

console.log("ok   connected lua.tools account states the account and offers only sign-out");
