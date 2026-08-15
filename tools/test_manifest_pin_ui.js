// Behavioural contract for selecting an archived build on an installed game:
// save the pin immediately, then offer Steam's existing Validate flow.
// Run: node tools/test_manifest_pin_ui.js
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class El {
  constructor(tag) {
    this.tagName = String(tag || "div").toUpperCase();
    this.childNodes = [];
    this.parentNode = null;
    this.className = "";
    this.style = {};
    this.listeners = {};
    this._text = "";
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
    return this._text + this.childNodes.map((child) => child.textContent).join("");
  }
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
}

function walk(node, output = []) {
  for (const child of node.childNodes) {
    output.push(child);
    walk(child, output);
  }
  return output;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function settle() {
  for (let i = 0; i < 4; i += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
}

function harness() {
  const helpers = fs.readFileSync(
    path.join(__dirname, "..", "lua", "menu", "06-updates-helpers.js"), "utf8");
  const root = new El("html");
  const body = new El("body");
  root.appendChild(body);
  const calls = [];
  const errors = [];
  const window = {};
  const document = {
    body,
    documentElement: root,
    createElement: (tag) => new El(tag),
  };
  const source = [
    "(function(){",
    "function log(scope, error){window.__errors.push({scope:scope,error:error});}",
    "function call(fn,args){window.__calls.push({fn:fn,args:args});return Promise.resolve('{}');}",
    "function injectStyles(){}",
    "function guStrings(){return {validateTitle:'Apply selected build',",
    "validateBody:'The selected build is applied after Steam validates the game files.',",
    "validateConfirm:'Validate now',validateDecline:'Not now'};}",
    helpers,
    "window.__test={applyPinForInstalledGame:applyPinForInstalledGame};",
    "})();",
  ].join("\n");
  window.__calls = calls;
  window.__errors = errors;
  vm.runInNewContext(source, {
    window, document, Promise, JSON, Error, Array, Object, String, Number, Math, Date,
    setTimeout, clearTimeout, console,
  }, { filename: "manifest-pin-ui.js" });
  return { body, calls, errors, run: window.__test.applyPinForInstalledGame };
}

async function main() {
  const h = harness();
  let pins = 0;
  h.run(250900, function () {
    pins += 1;
    return Promise.resolve();
  }, true);
  await settle();

  assert(pins === 1, "selecting another build must save its pin immediately");
  assert(h.body.textContent.includes("Apply selected build"),
    "a successful pin must open the existing Validate modal");

  const buttons = walk(h.body).filter((el) => el.tagName === "BUTTON");
  const decline = buttons.find((el) => el.textContent === "Not now");
  const confirm = buttons.find((el) => el.textContent === "Validate now");
  assert(decline && decline.className === "lumen-mbtn",
    "Not now must keep the neutral modal style");
  assert(confirm && confirm.className === "lumen-mbtn primary",
    "Validate now must use Lumen's primary style");

  decline.click();
  assert(!h.body.textContent.includes("Apply selected build"),
    "Not now must only dismiss the Validate modal");
  assert(!h.calls.some((entry) => entry.fn === "__lumenValidateApp"),
    "Not now must not start validation");

  h.run(250900, function () { return Promise.resolve(); }, true);
  await settle();
  const validate = walk(h.body).find((el) =>
    el.tagName === "BUTTON" && el.textContent === "Validate now");
  validate.click();
  assert(h.calls.some((entry) =>
    entry.fn === "__lumenValidateApp" && entry.args.appid === 250900),
  "Validate now must ask Steam to validate the selected game");

  const sameBuild = harness();
  sameBuild.run(250900, function () { return Promise.resolve(); }, false);
  await settle();
  assert(!sameBuild.body.textContent.includes("Apply selected build"),
    "pinning the build already installed must not ask for validation");

  const failed = harness();
  failed.run(250900, function () { return Promise.reject(new Error("pin failed")); }, true);
  await settle();
  assert(!failed.body.textContent.includes("Apply selected build"),
    "a failed pin must not offer validation for a build that was not saved");
  assert(failed.errors.length === 1, "a failed pin must be logged once");

  console.log("manifest pin UI tests passed");
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
