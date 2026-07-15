// The Themes tab keeps local theme management lightweight: installed themes
// get one secondary "Browse themes folder" action instead of import controls.
"use strict";

const fs = require("fs");
const vm = require("vm");

class El {
  constructor(tag) {
    this.tagName = String(tag || "div").toUpperCase();
    this.children = [];
    this.parentElement = null;
    this.className = "";
    this.style = {};
    this._text = "";
    this._listeners = {};
    this.checked = false;
    this.disabled = false;
    this.value = "";
  }
  appendChild(child) {
    child.parentElement = this;
    this.children.push(child);
    return child;
  }
  addEventListener(type, listener) {
    (this._listeners[type] = this._listeners[type] || []).push(listener);
  }
  click() {
    for (const listener of this._listeners.click || []) listener({ target: this });
  }
  dispatch(type) {
    for (const listener of this._listeners[type] || []) listener({ target: this });
  }
  set textContent(value) {
    this._text = String(value == null ? "" : value);
    this.children = [];
  }
  get textContent() {
    return this._text + this.children.map((child) => child.textContent).join("");
  }
}

function findByText(root, text) {
  if (root._text === text) return root;
  for (const child of root.children) {
    const found = findByText(child, text);
    if (found) return found;
  }
  return null;
}

function findByClass(root, name) {
  if (root.className.split(/\s+/).includes(name)) return root;
  for (const child of root.children) {
    const found = findByClass(child, name);
    if (found) return found;
  }
  return null;
}

(async function main() {
  const iconSource = fs.readFileSync("lua/menu/06-updates-helpers.js", "utf8");
  const overlaySource = fs.readFileSync("lua/menu/09-overlay.js", "utf8");
  if (!/var THEMES_SVG\s*=/.test(iconSource) ||
      !/mkTab\(themeStrings\(\)\.tab,\s*THEMES_SVG\)/.test(overlaySource)) {
    throw new Error("FAIL: Themes must use its own theme icon instead of the slsteam-moon icon");
  }

  const source = fs.readFileSync("lua/menu/14-themes-tab.js", "utf8");
  const calls = [];
  const document = {
    body: new El("body"),
    documentElement: new El("html"),
    createElement: (tag) => new El(tag),
    getElementById: () => null,
  };
  const context = {
    document,
    window: {},
    sessionStorage: { setItem() {} },
    pickLang: () => "en",
    OVERLAY_ID: "lumen-overlay",
    call: (fn) => {
      calls.push(fn);
      return Promise.resolve(JSON.stringify({ success: true }));
    },
    console,
    FileReader: class {},
  };
  vm.createContext(context);
  vm.runInContext(source, context, { filename: "14-themes-tab.js" });
  let themeState = {
    success: true,
    config: {
      enabled: true,
      active: "minimal-dark",
      allow_javascript: true,
      preferences: { "minimal-dark": {} },
    },
    themes: [
      {
        native: "minimal-dark",
        name: "Minimal Dark",
        version: "5.7.1",
        author: "SaiyajinK",
        description: "Highly customizable dark minimalist skin for Steam.",
        updateable: true,
        configurable: true,
        conditions: [{
          name: "Accent color",
          description: "Changes the primary accent.",
          default: "blue",
          values: ["blue", "red"],
          tab: "Colors",
          section: "General",
        }, {
          name: "Corner radius",
          description: "Changes corner rounding.",
          default: 6,
          values: [],
          slider: { min: 0, max: 12, step: 1, unit: "px" },
          tab: "Layout",
          section: "Window",
        }],
        root_colors: [],
      },
      {
        native: "space-theme",
        name: "SpaceTheme for Steam",
        author: "SpaceEnergy",
        description: "A dark modular theme.",
        updateable: true,
        configurable: false,
        conditions: [],
        root_colors: [],
      },
    ],
  };
  context.themeCall = (fn) => {
    calls.push(fn);
    if (fn === "LumenThemesStatus") {
      return Promise.resolve(JSON.stringify(themeState));
    }
    return Promise.resolve(JSON.stringify({ success: true }));
  };

  const body = new El("div");
  context.renderThemes(body);
  await new Promise((resolve) => setImmediate(resolve));

  const browse = findByText(body, "Browse themes folder");
  if (!browse) throw new Error("FAIL: Browse themes folder action is missing");
  if (browse.tagName !== "BUTTON" || !browse.className.includes("lumen-theme-folder-action")) {
    throw new Error("FAIL: folder action must be a semantic tertiary button");
  }
  const toolbar = browse.parentElement;
  if (!toolbar || !toolbar.className.includes("lumen-theme-list-head")) {
    throw new Error("FAIL: folder action is not in the Installed themes header");
  }
  if (!findByText(toolbar, "Installed themes")) {
    throw new Error("FAIL: Installed themes heading does not share the toolbar");
  }
  for (const removed of ["Import local theme", "Select folder", "Select ZIP"]) {
    if (findByText(body, removed)) throw new Error("FAIL: obsolete control remains: " + removed);
  }

  const list = findByClass(body, "lumen-theme-list");
  if (!list) throw new Error("FAIL: installed themes are not grouped in a list");
  const activeStatus = findByText(list, "Active");
  if (!activeStatus || activeStatus.tagName === "BUTTON" || !activeStatus.className.includes("lumen-theme-status")) {
    throw new Error("FAIL: Active must be a non-interactive status indicator");
  }
  const activeCard = activeStatus.parentElement.parentElement.parentElement;
  if (!activeCard.className.split(/\s+/).includes("active")) {
    throw new Error("FAIL: active theme row lacks a distinct active state");
  }
  const remove = findByText(activeCard, "Remove");
  if (!remove || remove.tagName !== "BUTTON" || !remove.className.includes("danger")) {
    throw new Error("FAIL: Remove must be a semantic destructive action");
  }

  const customize = findByClass(body, "lumen-theme-customize");
  if (!customize || !findByText(customize, "Customize Minimal Dark")) {
    throw new Error("FAIL: customization panel does not identify the active theme");
  }
  const option = findByClass(customize, "lumen-theme-option");
  if (!option) throw new Error("FAIL: customization controls are not grouped as options");
  const category = findByClass(customize, "lumen-theme-category");
  if (!category) throw new Error("FAIL: large customization sets lack category navigation");
  if (!findByText(customize, "Accent color") || findByText(customize, "Corner radius")) {
    throw new Error("FAIL: customization panel must render only the selected category");
  }
  const apply = findByText(customize, "Apply changes");
  if (!apply || apply.tagName !== "BUTTON" || !apply.disabled) {
    throw new Error("FAIL: Apply changes must start disabled in the semantic footer");
  }
  const select = findByClass(customize, "lumen-theme-select");
  if (!select) throw new Error("FAIL: theme select lacks its dedicated control style");
  select.value = "red";
  select.dispatch("change");
  if (apply.disabled) throw new Error("FAIL: changing a preference did not enable Apply changes");
  category.value = findByText(category, "Layout").value;
  category.dispatch("change");
  if (!findByText(customize, "Corner radius") || findByText(customize, "Accent color")) {
    throw new Error("FAIL: category navigation did not replace the visible option group");
  }
  if (!findByClass(customize, "lumen-theme-range") || !findByText(customize, "Window")) {
    throw new Error("FAIL: slider or section metadata is not rendered generically");
  }

  browse.click();
  await new Promise((resolve) => setImmediate(resolve));
  if (!calls.includes("LumenThemesOpenFolder")) {
    throw new Error("FAIL: folder action did not open the managed themes folder");
  }

  // Millennium themes are not required to define tab/section metadata and may
  // expose only RootColors. Both shapes need useful generic fallbacks.
  themeState = {
    success: true,
    config: {
      enabled: true,
      active: "generic-theme",
      allow_javascript: true,
      preferences: { "generic-theme": {} },
    },
    themes: [{
      native: "generic-theme",
      name: "Generic Theme",
      author: "Author",
      description: "No Millennium tab metadata.",
      configurable: true,
      conditions: [{ name: "Uncategorised option", default: "on", values: ["on", "off"] }],
      root_colors: [{ name: "accent", default: "#112233" }],
    }],
  };
  const genericBody = new El("div");
  context.renderThemes(genericBody);
  await new Promise((resolve) => setImmediate(resolve));
  const genericCustom = findByClass(genericBody, "lumen-theme-customize");
  const genericCategory = findByClass(genericCustom, "lumen-theme-category");
  if (!findByText(genericCategory, "General") || !findByText(genericCategory, "Theme colors")) {
    throw new Error("FAIL: missing tab metadata or RootColors lack generic categories");
  }
  genericCategory.value = findByText(genericCategory, "Theme colors").value;
  genericCategory.dispatch("change");
  if (!findByClass(genericCustom, "lumen-theme-color")) {
    throw new Error("FAIL: RootColors category did not render a color control");
  }
  console.log("test_themes_ui: ok");
})().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
