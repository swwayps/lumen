"use strict";

const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync("lua/menu/03-styles.js", "utf8");

class InlineStyle {
  constructor() { this.values = {}; }
  setProperty(name, value) { this.values[name] = String(value); }
  removeProperty(name) { delete this.values[name]; }
  getPropertyValue(name) { return this.values[name] || ""; }
}

function styled(backgroundColor, color, width = 1200, height = 700) {
  return {
    tagName: "DIV",
    parentElement: null,
    _computed: { backgroundColor, color, backgroundImage: "none" },
    getBoundingClientRect() {
      return { left: 0, top: 0, right: width, bottom: height, width, height };
    },
  };
}

function parseColor(value) {
  const nums = String(value || "").match(/[\d.]+/g);
  return nums ? nums.slice(0, 3).map(Number) : null;
}

function same(actual, expected) {
  return actual && expected.every((value, index) => Math.abs(actual[index] - value) <= 1);
}

function createRuntime({ theme, seed, rootVariables = {}, samples = [], links = [] }) {
  const root = { tagName: "HTML", style: new InlineStyle(), parentElement: null };
  const body = styled("rgba(0, 0, 0, 0)", "rgb(255, 255, 255)");
  body.tagName = "BODY";
  body.parentElement = root;
  let sampleIndex = 0;
  let currentSamples = samples;
  let sampledStyleReads = 0;
  const injected = [];
  const document = {
    documentElement: root,
    body,
    head: { appendChild(element) { injected.push(element); } },
    getElementById() { return null; },
    createElement() { return { id: "", style: new InlineStyle() }; },
    querySelectorAll(selector) {
      return selector.includes("data-lumen-theme-asset") ? links : [];
    },
    elementsFromPoint() {
      if (!currentSamples.length) return [];
      return currentSamples[Math.min(sampleIndex++, currentSamples.length - 1)];
    },
  };
  const window = {
    __lumenThemeApplied: theme,
    __lumenThemePaletteSeed: seed,
    innerWidth: 1600,
    innerHeight: 900,
  };
  const context = {
    window,
    document,
    console,
    BTN_ID: "lumen-moon-btn",
    OVERLAY_ID: "lumen-settings-overlay",
    STYLE_ID: "lumen-menu-styles",
    getComputedStyle(element) {
      if (element === root) {
        return {
          backgroundColor: "rgba(0, 0, 0, 0)", color: "rgb(255, 255, 255)",
          getPropertyValue(name) {
            return root.style.getPropertyValue(name) || rootVariables[name] || "";
          },
        };
      }
      sampledStyleReads++;
      return Object.assign({
        backgroundColor: "rgba(0, 0, 0, 0)", color: "rgba(0, 0, 0, 0)",
        backgroundImage: "none", getPropertyValue() { return ""; },
      }, element._computed || {});
    },
  };
  vm.createContext(context);
  vm.runInContext(source, context, { filename: "03-styles.js" });
  return {
    context, root,
    sampledStyleReads: () => sampledStyleReads,
    replaceSamples(next) { currentSamples = next; sampleIndex = 0; },
    injected,
  };
}

function assert(condition, message) {
  if (!condition) throw new Error("FAIL: " + message);
}

// simply-dark declares valid Millennium RootColors, but none use the handful
// of aliases the old adapter recognized. Native samples identify its actual
// #191919 base and #212121 panel; the semantic online color is its accent.
{
  const base = styled("rgb(25, 25, 25)", "rgb(217, 218, 221)");
  const panel = styled("rgb(33, 33, 33)", "rgb(255, 255, 255)", 900, 500);
  const runtime = createRuntime({
    theme: "simply-dark",
    seed: {
      theme: "simply-dark", revision: "fixture-1", colors: [
        { name: "color-light", value: "rgb(48, 48, 48)" },
        { name: "color-dark", value: "#212121" },
        { name: "color-darker", value: "#191919" },
        { name: "color-darkest", value: "#141414" },
        { name: "darkerwhite", value: "#b8b6b4" },
        { name: "darkwhite", value: "#d9dadd" },
        { name: "white", value: "#ffffff" },
        { name: "ingame", value: "#90ba3c" },
        { name: "online", value: "#57cbde" },
      ],
    },
    samples: [[base, panel], [base, panel], [base], [panel], [base, panel]],
  });
  runtime.context.applyAdaptivePalette();
  const values = runtime.root.style.values;
  assert(same(parseColor(values["--lumen-theme-bg"]), [25, 25, 25]),
    "simply-dark base was not inferred from the themed Steam surface");
  assert(same(parseColor(values["--lumen-theme-panel"]), [33, 33, 33]),
    "simply-dark panel was not inferred from its secondary surface");
  assert(same(parseColor(values["--lumen-theme-accent"]), [87, 203, 222]),
    "simply-dark semantic accent was not selected from arbitrary RootColors");
  assert(values["--lumen-theme-text"] && values["--lumen-theme-muted"] &&
      values["--lumen-theme-border"],
    "the complete Lumen palette was not generated");
}

// Large native surfaces can be intentionally darker than the theme's panels.
// Explicitly named RootColors must keep the Lumen window stable across Library
// and Store instead of allowing each page's dominant surface to redefine it.
{
  const base = styled("rgb(25, 25, 25)", "rgb(150, 150, 150)");
  const black = styled("rgb(0, 0, 0)", "rgb(150, 150, 150)");
  const panel = styled("rgb(33, 33, 33)", "rgb(255, 255, 255)");
  const samples = Array.from({ length: 14 }, () => [base, black]);
  samples[3] = [panel, base, black];
  const runtime = createRuntime({
    theme: "simply-dark",
    seed: { theme: "simply-dark", revision: "noisy-native", colors: [
      { name: "color-dark", value: "#212121" },
      { name: "color-darker", value: "#191919" },
      { name: "color-darkest", value: "#141414" },
      { name: "darkwhite", value: "#d9dadd" },
      { name: "white", value: "#ffffff" },
      { name: "online", value: "#57cbde" },
    ] },
    samples,
  });
  runtime.context.applyAdaptivePalette();
  const values = runtime.root.style.values;
  assert(same(parseColor(values["--lumen-theme-bg"]), [25,25,25]),
    "dominant native surface overrode the semantic theme background");
  assert(same(parseColor(values["--lumen-theme-panel"]), [33,33,33]),
    "dominant native surface overrode the semantic theme panel");
  assert(same(parseColor(values["--lumen-theme-text"]), [217,218,221]),
    "native inherited text overrode the semantic theme foreground");
}

// Standard Millennium variables can contain bare RGB triplets. They remain
// authoritative and do not require runtime DOM inference.
{
  const runtime = createRuntime({
    theme: "space-theme",
    seed: { theme: "space-theme", revision: "fixture-2", colors: [] },
    rootVariables: {
      "--st-background": "10, 10, 10",
      "--st-color-2": "30, 30, 30",
      "--st-accent-1": "102, 108, 255",
    },
  });
  runtime.context.applyAdaptivePalette();
  const values = runtime.root.style.values;
  assert(same(parseColor(values["--lumen-theme-bg"]), [10, 10, 10]),
    "bare RGB background variables are unsupported");
  assert(same(parseColor(values["--lumen-theme-panel"]), [30, 30, 30]),
    "standard Millennium panel variable was not authoritative");
  assert(same(parseColor(values["--lumen-theme-accent"]), [102, 108, 255]),
    "standard Millennium accent variable was not authoritative");
}

// Arbitrary names still yield usable light and dark palettes even when a
// theme has not painted enough native UI to sample yet.
{
  const dark = createRuntime({
    theme: "arbitrary-dark",
    seed: { theme: "arbitrary-dark", revision: "1", colors: [
      { name: "a", value: "#101820" }, { name: "b", value: "#243447" },
      { name: "c", value: "#ff7a45" }, { name: "d", value: "#f5f5f5" },
    ] },
  });
  dark.context.applyAdaptivePalette();
  assert(same(parseColor(dark.root.style.values["--lumen-theme-bg"]), [16,24,32]),
    "arbitrary dark RootColors did not produce a dark base");
  assert(same(parseColor(dark.root.style.values["--lumen-theme-panel"]), [36,52,71]),
    "arbitrary dark RootColors did not produce a distinct panel");
  assert(same(parseColor(dark.root.style.values["--lumen-theme-accent"]), [255,122,69]),
    "arbitrary dark RootColors lost their chromatic accent");

  const light = createRuntime({
    theme: "arbitrary-light",
    seed: { theme: "arbitrary-light", revision: "1", colors: [
      { name: "one", value: "#ffffff" }, { name: "two", value: "#fafafa" },
      { name: "three", value: "#e8e8e8" }, { name: "four", value: "#222222" },
      { name: "five", value: "hsl(18, 90%, 52%)" },
    ] },
  });
  light.context.applyAdaptivePalette();
  const lightValues = light.root.style.values;
  assert(parseColor(lightValues["--lumen-theme-bg"])[0] >= 245,
    "arbitrary light RootColors were misclassified as a dark theme");
  assert(parseColor(lightValues["--lumen-theme-text"])[0] <= 40,
    "light theme did not select contrasting dark text");
  assert(parseColor(lightValues["--lumen-theme-border"])[0] === 0,
    "light theme did not select a dark border");
}

// Themes without RootColors use only a bounded native-surface sample.
{
  const base = styled("rgb(18, 24, 31)", "rgb(235, 238, 241)");
  const panel = styled("rgb(35, 45, 57)", "rgb(235, 238, 241)", 700, 450);
  const highlighted = styled("rgb(171, 62, 214)", "rgb(255, 255, 255)", 180, 38);
  const sampleStacks = Array.from({ length: 14 }, () => [base,panel]);
  sampleStacks[4] = [highlighted,base,panel];
  const runtime = createRuntime({
    theme: "css-only", seed: { theme: "css-only", revision: "1", colors: [] },
    samples: sampleStacks,
  });
  runtime.context.applyAdaptivePalette();
  assert(same(parseColor(runtime.root.style.values["--lumen-theme-bg"]), [18,24,31]),
    "theme without RootColors did not use the native UI sample");
  assert(same(parseColor(runtime.root.style.values["--lumen-theme-accent"]), [171,62,214]),
    "theme without RootColors did not infer its visible native accent");
  const reads = runtime.sampledStyleReads();
  runtime.context.applyAdaptivePalette();
  assert(runtime.sampledStyleReads() === reads,
    "cached palette repeated computed-style sampling");
}

// A stylesheet that was pending during the first resolution invalidates the
// cache exactly once on load; no timer or persistent observer is needed.
{
  const listeners = {};
  const link = {
    sheet: null, dataset: { lumenThemeAsset: "css:theme.css" },
    addEventListener(type, fn) { listeners[type] = fn; },
  };
  const initial = styled("rgb(30, 30, 30)", "rgb(240, 240, 240)");
  const themed = styled("rgb(70, 20, 90)", "rgb(255, 245, 255)");
  const runtime = createRuntime({
    theme: "late-css", seed: { theme: "late-css", revision: "1", colors: [] },
    samples: [[initial]], links: [link],
  });
  runtime.context.applyAdaptivePalette();
  runtime.replaceSamples([[themed]]);
  link.sheet = {};
  assert(typeof listeners.load === "function", "pending theme stylesheet has no one-shot load hook");
  listeners.load();
  assert(same(parseColor(runtime.root.style.values["--lumen-theme-bg"]), [70,20,90]),
    "palette cache was not refreshed when the theme stylesheet became ready");
}

// Disabling themes clears every derived property and the cached custom state.
{
  const runtime = createRuntime({
    theme: "dark", seed: { theme: "dark", revision: "1", colors: [
      { name: "bg", value: "#111111" }, { name: "fg", value: "#eeeeee" },
    ] },
  });
  runtime.context.applyAdaptivePalette();
  runtime.context.window.__lumenThemeApplied = "";
  runtime.context.applyAdaptivePalette();
  assert(!Object.keys(runtime.root.style.values).some((name) => name.startsWith("--lumen-theme-")),
    "disabling themes left derived Lumen palette properties behind");
}

// Preference changes can alter RootColors without changing the repository
// commit/revision. The palette cache key must include effective color values.
{
  const seed = { theme: "same-revision", revision: "commit-1", colors: [
    { name: "background", value: "#111111" },
    { name: "panel", value: "#222222" },
    { name: "accent", value: "#3366ff" },
  ] };
  const runtime = createRuntime({ theme: "same-revision", seed });
  runtime.context.applyAdaptivePalette();
  seed.colors[0].value = "#444444";
  seed.colors[1].value = "#555555";
  runtime.context.applyAdaptivePalette();
  assert(same(parseColor(runtime.root.style.values["--lumen-theme-bg"]), [68,68,68]),
    "same-revision RootColors preference reused a stale cached palette");
}

// Adaptive variables cover all common controls, not only the outer window.
// This prevents a light theme from producing a light shell with dark inputs,
// cards and selectors left inside it.
{
  const runtime = createRuntime({
    theme: "light",
    seed: { theme: "light", revision: "1", colors: [
      { name: "background", value: "#fafafa" },
      { name: "panel", value: "#eeeeee" },
      { name: "text", value: "#202020" },
      { name: "accent", value: "#5a45d6" },
    ] },
  });
  runtime.context.injectStyles();
  const css = runtime.injected.map((element) => element.textContent || "").join("\n");
  assert(css.includes(".lumen-gu-search,.lumen-cloud-search,.lumen-theme-actions input[type=text]") &&
      css.includes("background:var(--lumen-theme-bg"),
    "search, theme and cloud inputs are not covered by the adaptive palette");
  assert(css.includes(".lumen-row input[type=text],.lumen-row input[type=number],.lumen-row select") &&
      css.includes("border-color:var(--lumen-theme-border"),
    "settings controls are not covered by adaptive surface and border colors");
  assert(css.includes(".lumen-game-name,.lumen-about-ver .nm,.lumen-about-act .at") &&
      css.includes("color:var(--lumen-theme-text"),
    "secondary tabs retain hard-coded dark-theme text colors");
}

console.log("test_adaptive_palette: ok");
