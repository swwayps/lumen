"use strict";

const fs = require("fs");
const vm = require("vm");

const path = "lua/menu/10-install-readiness.js";
if (!fs.existsSync(path)) {
  console.error("FAIL install readiness UI fragment is missing");
  process.exit(1);
}
const i18nSource = fs.readFileSync("lua/menu/02-i18n.js", "utf8");
const styleSource = fs.readFileSync("lua/menu/03-styles.js", "utf8");

class El {
  constructor(tag) {
    this.tagName = String(tag || "div").toUpperCase();
    this.children = [];
    this.parentElement = null;
    this.id = "";
    this.className = "";
    this.dataset = {};
    this.attributes = {};
    this._text = "";
    this._listeners = {};
  }
  appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
  remove() {
    if (!this.parentElement) return;
    this.parentElement.children = this.parentElement.children.filter((item) => item !== this);
    this.parentElement = null;
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name]; }
  addEventListener(type, fn) { (this._listeners[type] ||= []).push(fn); }
  click() {
    for (const fn of this._listeners.click || []) {
      fn({ target: this, preventDefault() {}, stopPropagation() {} });
    }
  }
  focus() { this.focused = true; document.activeElement = this; }
  contains(target) { return walk(this).includes(target); }
  querySelectorAll(selector) {
    if (selector !== "button.focusable:not([disabled])") return [];
    return walk(this).filter((el) => el.tagName === "BUTTON"
      && el.className.split(/\s+/).includes("focusable") && !el.disabled);
  }
  set textContent(value) { this._text = String(value == null ? "" : value); this.children = []; }
  get textContent() { return this._text + this.children.map((child) => child.textContent).join(""); }
}

function walk(root) {
  const result = [root];
  for (const child of root.children) result.push(...walk(child));
  return result;
}

const body = new El("body");
const documentListeners = {};
const document = {
  body,
  documentElement: body,
  activeElement: body,
  createElement(tag) { return new El(tag); },
  getElementById(id) { return walk(body).find((el) => el.id === id) || null; },
  addEventListener(type, fn) { (documentListeners[type] ||= []).push(fn); },
  removeEventListener(type, fn) {
    documentListeners[type] = (documentListeners[type] || []).filter((item) => item !== fn);
  },
};
function dispatchKey(key) {
  const event = {
    key, defaultPrevented: false, propagationStopped: false,
    preventDefault() { this.defaultPrevented = true; },
    stopPropagation() { this.propagationStopped = true; },
    stopImmediatePropagation() { this.propagationStopped = true; },
  };
  for (const fn of [...(documentListeners.keydown || [])]) fn(event);
  return event;
}
const calls = [];
let scans = 0;
const strings = {
  title: "Manifest unavailable",
  body: "The manifests required to start this installation are not available yet.",
  installAnyway: "Install anyway",
  close: "Close",
  risk: "Steam may show No Internet Connection because the manifests are missing.",
  ready: "The manifest is ready. You can install this game now.",
};
const timers = [];
const context = {
  window: { GamepadNav: { scanElements() { scans += 1; }, setBackHandler() {} } },
  document,
  installReadinessStrings() { return strings; },
  injectStyles() {},
  call(fn, args) { calls.push({ fn, args }); return Promise.resolve('{"ok":true}'); },
  setTimeout(fn) { timers.push(fn); return timers.length; },
  clearTimeout() {},
  Promise,
  console,
};
vm.runInNewContext(fs.readFileSync("lua/menu/04-overlay-helpers.js", "utf8"), context, {
  filename: "lua/menu/04-overlay-helpers.js",
});
vm.runInNewContext(fs.readFileSync(path, "utf8"), context, { filename: path });

let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.error("FAIL " + name); failures += 1; }
}

context.window.__lumenShowInstallReadinessBlocked(1671210);
let overlay = document.getElementById("lumen-install-readiness-overlay");
check("U1 a blocked install opens a Lumen dialog before the Steam wizard",
  overlay && overlay.getAttribute("role") === "dialog" && scans === 1);
check("U2 the dialog explicitly warns about Steam's No Internet Connection error",
  overlay.textContent.includes("No Internet Connection")
    && overlay.textContent.includes("manifests"));
context.window.GamepadNav = undefined;
const behind = new El("button");
behind.focus();
const arrow = dispatchKey("ArrowLeft");
check("U3 keyboard-backed gamepad navigation cannot stay behind the modal",
  arrow.defaultPrevented && overlay.contains(document.activeElement)
    && document.activeElement.dataset.action);

const installAnyway = walk(overlay).find((el) => el.dataset.action === "install-anyway");
installAnyway.click();
check("U4 install anyway closes the dialog and requests only that AppID",
  document.getElementById("lumen-install-readiness-overlay") === null
    && calls.length === 1 && calls[0].fn === "__lumenInstallAnyway"
    && calls[0].args.appid === 1671210);

context.window.__lumenShowInstallReadinessBlocked(1671210);
overlay = document.getElementById("lumen-install-readiness-overlay");
const close = walk(overlay).find((el) => el.dataset.action === "close");
close.click();
check("U5 close keeps the native install untouched",
  document.getElementById("lumen-install-readiness-overlay") === null
    && calls.length === 1);
const releasedArrow = dispatchKey("ArrowLeft");
check("U6 closing the readiness modal releases global navigation",
  !releasedArrow.defaultPrevented);

context.window.__lumenShowInstallReadinessReady(1671210);
const toast = document.getElementById("lumen-install-readiness-toast");
check("U5 readiness recovery is a passive notification, not an automatic install",
  toast && toast.textContent.includes("install this game now") && calls.length === 1);
check("U6 shipped Portuguese copy names the missing-manifest Steam error explicitly",
  i18nSource.includes("No Internet Connection")
    && i18nSource.includes("devido à falta de manifests"));
check("U7 the modal and passive toast have dedicated, non-wizard styling",
  styleSource.includes(".lumen-install-readiness-overlay")
    && styleSource.includes(".lumen-install-readiness-toast"));

process.exitCode = failures ? 1 : 0;
