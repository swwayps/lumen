"use strict";

const fs = require("fs");
const vm = require("vm");

class Element {
  constructor(name, left) {
    this.name = name;
    this.dataset = {};
    this.tagName = "BUTTON";
    this.attributes = {};
    this.parentElement = null;
    this.children = [];
    this.listeners = new Map();
    this.isConnected = true;
    this.disabled = false;
    this.clicks = 0;
    this.rect = { left, right: left + 80, top: 0, bottom: 40, width: 80, height: 40 };
    this.classList = {
      values: new Set(),
      add: (...names) => names.forEach((name) => this.classList.values.add(name)),
      remove: (...names) => names.forEach((name) => this.classList.values.delete(name)),
      contains: (name) => this.classList.values.has(name),
    };
  }
  appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
  hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  contains(target) { return target === this || this.children.some((child) => child.contains(target)); }
  querySelectorAll() { return this.children.slice(); }
  querySelector(selector) {
    if (selector === ".active-focus") {
      return this.children.find((child) => child.classList.contains("active-focus")) || null;
    }
    return this.children[0] || null;
  }
  getBoundingClientRect() { return this.rect; }
  addEventListener(type, fn) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(fn);
  }
  removeEventListener(type, fn) { this.listeners.get(type)?.delete(fn); }
  dispatch(type, detail) {
    const event = {
      detail, prevented: false, stopped: false,
      preventDefault() { this.prevented = true; },
      stopPropagation() { this.stopped = true; },
      stopImmediatePropagation() { this.stopped = true; },
    };
    for (const fn of this.listeners.get(type) || []) fn(event);
    return event;
  }
  focus() { document.activeElement = this; }
  click() { this.clicks += 1; }
}

class Node {
  constructor(tree, parent) {
    this.tree = tree; this.m_Parent = parent; this.m_rgChildren = [];
    this.m_Properties = {}; this.focused = false; this.m_element = null;
    if (parent) parent.m_rgChildren.push(this);
  }
  SetProperties(value) { this.m_Properties = value; }
  BHasFocus() { return this.focused; }
  BTakeFocus(source, direction) {
    this.tree.clearFocus(); this.focused = true;
    this.source = source; this.direction = direction;
    this.m_element?.dispatch("focus", {});
    return true;
  }
}

class Tree {
  constructor(id, parent, options) {
    this.m_ID = id; this.parent = parent; this.options = options;
    this.Root = new Node(this, null); this.registered = [];
  }
  CreateNode(parent) { return new Node(this, parent); }
  RegisterNavigationItem(node, element) {
    node.m_element = element; this.registered.push({ node, element });
    return () => { node.unregistered = true; };
  }
  Register() {}
  SetIsEnabled(value) { this.enabled = value; }
  Activate(value) { this.activated = value; }
  TakeFocus(source) { this.focusSource = source; }
  clearFocus() {
    const walk = (node) => {
      if (node.focused) node.m_element?.dispatch("blur", {});
      node.focused = false; node.m_rgChildren.forEach(walk);
    };
    walk(this.Root);
  }
}

const page = new Element("page", 0);
const overlay = new Element("overlay", 0);
const install = new Element("install-anyway", 0);
const close = new Element("close", 100);
install.dataset.action = "install-anyway";
close.dataset.action = "close";
page.appendChild(overlay); overlay.appendChild(install); overlay.appendChild(close);

const pageTree = new Tree("GamepadUI_Full_Root", null, {});
pageTree.Root.m_element = page;
const context = {
  ActiveWindow: null, m_rgGamepadNavigationTrees: new Set([pageTree]),
  m_LastActiveNavTree: pageTree, m_LastActiveFocusNavTree: pageTree,
  UnregisterGamepadNavigationTree(tree) {
    this.m_rgGamepadNavigationTrees.delete(tree);
    tree.contextUnregistered = true;
  },
};
const createdTrees = [];
const controller = {
  m_ActiveContext: context,
  GetActiveContext: () => context,
  GetActiveNavTree: () => pageTree,
  NewGamepadNavigationTree(ctx, id, parent, options) {
    if (ctx !== context) throw new Error("wrong context");
    const tree = new Tree(id, parent, options); createdTrees.push(tree); return tree;
  },
  RegisterGamepadNavigationTree(tree, owner) {
    tree.registeredOwner = owner;
    return () => { tree.controllerUnregistered = true; };
  },
};

class Observer {
  constructor(callback) { this.callback = callback; observers.push(this); }
  observe(target) { this.target = target; }
  disconnect() { this.disconnected = true; }
  trigger() { this.callback([]); }
}
const observers = [];

const documentListeners = {};
const document = {
  activeElement: page, documentElement: page,
  addEventListener(type, fn) { (documentListeners[type] ||= []).push(fn); },
  removeEventListener(type, fn) {
    documentListeners[type] = (documentListeners[type] || []).filter((item) => item !== fn);
  },
};
const windowObject = {
  opener: { FocusNavController: controller },
  getComputedStyle: () => ({ display: "block", visibility: "visible", opacity: "1" }),
};
context.ActiveWindow = windowObject;

const sandbox = {
  window: windowObject, document, MutationObserver: Observer,
  Date, Array, Map, Set, console, setTimeout: (fn) => { fn(); return 1; },
  call: () => Promise.resolve(),
};
const intervals = [];
sandbox.setInterval = (fn) => { intervals.push(fn); return intervals.length; };
sandbox.clearInterval = (id) => { intervals[id - 1] = null; };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync("lua/menu/04-overlay-helpers.js", "utf8"), sandbox);

let backs = 0;
const cleanup = sandbox.trapModalFocus(overlay, () => { backs += 1; }, "close");
const tree = createdTrees[0];
if (!tree || tree.options.modal !== true || tree.registeredOwner !== windowObject) {
  throw new Error("modal was not registered in opener's native Steam focus controller");
}
if (!tree.enabled || !tree.activated || tree.registered.length !== 3) {
  throw new Error("modal root and actions were not activated as a native navigation tree");
}
const installNode = tree.registered.find((item) => item.element === install)?.node;
const closeNode = tree.registered.find((item) => item.element === close)?.node;
if (!closeNode?.BHasFocus()) throw new Error("preferred safe action did not take native focus");

const left = close.dispatch("vgp_onbuttondown", { button: 11, is_repeat: false });
if (!left.prevented || !installNode.BHasFocus()) {
  throw new Error("D-pad did not stay inside the native modal tree");
}
install.dispatch("vgp_onbuttondown", { button: 1, is_repeat: false });
if (install.clicks !== 1) throw new Error("gamepad A did not activate the focused action");
install.dispatch("vgp_onbuttondown", { button: 2, is_repeat: false });
if (backs !== 1) throw new Error("gamepad B did not invoke the modal back handler");

cleanup();
if (!tree.controllerUnregistered || !tree.registered.every((item) => item.node.unregistered)) {
  throw new Error("closing the modal did not unregister native navigation");
}
if (!tree.contextUnregistered || context.m_rgGamepadNavigationTrees.has(tree)) {
  throw new Error("closing the modal leaked its navigation tree in Steam's context");
}
if (tree.enabled !== false) {
  throw new Error("closing the modal left its navigation tree enabled");
}
if ((install.listeners.get("vgp_onbuttondown")?.size || 0) !== 0) {
  throw new Error("closing the modal left gamepad listeners attached");
}

console.log("ok   native Gamepad UI modal focus is trapped and cleaned up");

// The Fixes Menu entry joins Steam's OWN tree (no modal trap) so the D-pad can
// reach it from the neighbouring Play row.
const inlineButton = new Element("fixes-entry", 200);
page.appendChild(inlineButton);
const inlineCleanup = sandbox.registerNativeInlineFocus(inlineButton);
if (typeof inlineCleanup !== "function") {
  throw new Error("inline entry was not registered in Steam's existing navigation tree");
}
const inlineEntry = pageTree.registered.find((item) => item.element === inlineButton);
if (!inlineEntry || inlineEntry.node.m_Properties.focusable !== true) {
  throw new Error("inline entry was not marked focusable inside the page tree");
}
if (inlineEntry.node.m_Parent !== pageTree.Root) {
  throw new Error("inline entry was not attached to the node that owns it");
}
if (createdTrees.length !== 1) {
  throw new Error("inline entry must not create its own modal navigation tree");
}
const inlineConfirm = inlineButton.dispatch("vgp_onbuttondown", { button: 1, is_repeat: false });
if (inlineButton.clicks !== 1 || !inlineConfirm.prevented) {
  throw new Error("gamepad A did not activate the inline entry");
}
// Steam moves focus between siblings without firing a DOM focus event on divs,
// so the entry must mirror its own navigation node or the ring never appears.
inlineButton.tagName = "DIV";
inlineEntry.node.focused = true;
intervals.filter(Boolean).forEach((tick) => tick());
if (!inlineButton.classList.contains("active-focus")) {
  throw new Error("inline entry did not show a focus ring when Steam focused its node");
}
inlineEntry.node.focused = false;
intervals.filter(Boolean).forEach((tick) => tick());
if (inlineButton.classList.contains("active-focus")) {
  throw new Error("inline entry kept its focus ring after Steam moved focus away");
}
inlineButton.dispatch("vgp_onbuttondown", { button: 1, is_repeat: true });
if (inlineButton.clicks !== 1) {
  throw new Error("key repeat re-activated the inline entry");
}
inlineCleanup();
if (!inlineEntry.node.unregistered
    || (inlineButton.listeners.get("vgp_onbuttondown")?.size || 0) !== 0) {
  throw new Error("removing the inline entry left native navigation registered");
}
console.log("ok   inline Fixes Menu entry is gamepad focusable in Steam's own tree");

// The Fixes Menu and settings window are built from divs, which never receive a
// DOM focus event from Steam's BTakeFocus — the highlight has to be painted by
// the modal itself, and the items need a tab stop.
const divOverlay = new Element("div-overlay", 0);
const tileA = new Element("tile-a", 0);
const tileB = new Element("tile-b", 0);
[tileA, tileB].forEach((tile, index) => {
  tile.tagName = "DIV";
  tile.rect = { left: 0, right: 200, top: index * 60, bottom: index * 60 + 40, width: 200, height: 40 };
});
page.appendChild(divOverlay);
divOverlay.appendChild(tileA);
divOverlay.appendChild(tileB);
context.m_rgGamepadNavigationTrees.add(pageTree);
const divCleanup = sandbox.trapModalFocus(divOverlay, () => {}, {
  selector: "tile", preferFirst: true,
});
if (typeof divCleanup !== "function") {
  throw new Error("div-based overlay did not register native gamepad navigation");
}
if (!tileA.classList.contains("active-focus")) {
  throw new Error("div-based overlay opened with no visible selection");
}
if (tileA.attributes.tabindex !== "0" || tileB.attributes.tabindex !== "0") {
  throw new Error("div items were not given a tab stop for native focus");
}
const divMove = tileA.dispatch("vgp_onbuttondown", { button: 10, is_repeat: false });
if (!divMove.prevented || !tileB.classList.contains("active-focus")
    || tileA.classList.contains("active-focus")) {
  throw new Error("D-pad did not move the visible selection between div items");
}
divCleanup();
if (tileA.attributes.tabindex !== undefined
    || tileB.classList.contains("active-focus")) {
  throw new Error("closing the div overlay left tab stops or highlight behind");
}
console.log("ok   div-based Lumen overlays paint and move gamepad selection");

// The Fixes Menu opens on a spinner and renders its tiles a moment later, so
// the modal must take the selection when those first items appear.
const lateOverlay = new Element("late-overlay", 0);
lateOverlay.tagName = "DIV";
lateOverlay.querySelectorAll = function () { return this.children.slice(); };
page.appendChild(lateOverlay);
const treesBeforeLate = createdTrees.length;
const lateCleanup = sandbox.registerNativeModalFocus(lateOverlay, () => {}, {
  selector: "tile", preferFirst: true,
});
if (lateCleanup !== null || createdTrees.length !== treesBeforeLate) {
  throw new Error("an empty overlay must not claim a native navigation tree yet");
}
const lateTile = new Element("late-tile", 0);
lateTile.tagName = "DIV";
lateOverlay.appendChild(lateTile);
const lateRetry = sandbox.trapModalFocus(lateOverlay, () => {}, {
  selector: "tile", preferFirst: true,
});
if (typeof lateRetry !== "function" || !lateTile.classList.contains("active-focus")) {
  throw new Error("late-rendered content did not receive the gamepad selection");
}
const observerInstance = observers[observers.length - 1];
const replacement = new Element("replacement-tile", 0);
replacement.tagName = "DIV";
lateTile.classList.remove("active-focus");
lateOverlay.children = [replacement];
replacement.parentElement = lateOverlay;
if (observerInstance && typeof observerInstance.trigger === "function") {
  observerInstance.trigger();
}
if (!replacement.classList.contains("active-focus")) {
  throw new Error("a re-render left the modal focused with nothing selected");
}
lateRetry();
console.log("ok   asynchronously rendered overlay content takes gamepad selection");

// A focused search box has to keep the space bar. Steam's controller maps the
// space bar (and Enter) to gamepad button 1, and turning that into a click
// swallowed the space, so the Add-game and Fixes search fields could only take
// a single word — "crimson", never "crimson desert". The activate button must
// pass through untouched when a text field is focused, while a normal button in
// the same modal still activates on gamepad A.
const searchOverlay = new Element("search-overlay", 0);
searchOverlay.tagName = "DIV";
const searchInput = new Element("search-input", 0);
searchInput.tagName = "INPUT";
searchInput.type = "search";
const searchGo = new Element("search-go", 100);
page.appendChild(searchOverlay);
searchOverlay.appendChild(searchInput);
searchOverlay.appendChild(searchGo);
context.m_rgGamepadNavigationTrees.add(pageTree);
const searchCleanup = sandbox.trapModalFocus(searchOverlay, () => {}, {
  selector: "field", preferFirst: true,
});
if (typeof searchCleanup !== "function") {
  throw new Error("search overlay did not register native gamepad navigation");
}
const space = searchInput.dispatch("vgp_onbuttondown", { button: 1, is_repeat: false });
if (space.prevented || searchInput.clicks !== 0) {
  throw new Error("gamepad A on a text field was consumed instead of typing a space");
}
const spaceUp = searchInput.dispatch("vgp_onbuttonup", { button: 1, is_repeat: false });
if (spaceUp.prevented) {
  throw new Error("the activate button-up was consumed on a text field");
}
const goHit = searchGo.dispatch("vgp_onbuttondown", { button: 1, is_repeat: false });
if (!goHit.prevented || searchGo.clicks !== 1) {
  throw new Error("gamepad A no longer activates a normal button next to the field");
}
searchCleanup();
console.log("ok   a focused search box keeps the space bar (gamepad A still types)");
