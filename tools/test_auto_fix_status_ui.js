"use strict";

const fs = require("fs");
const vm = require("vm");

const path = "lua/menu/10-auto-fix-status.js";
if (!fs.existsSync(path)) {
  console.log("FAIL U1 auto-fix status fragment exists");
  process.exit(1);
}

class El {
  constructor(tag) {
    this.tagName = String(tag || "div").toUpperCase();
    this.children = [];
    this.parentElement = null;
    this.id = "";
    this.className = "";
    this.dataset = {};
    this.disabled = false;
    this._text = "";
    this._listeners = {};
    this.attributes = {};
    this.style = {};
    this.classList = {
      add: (...names) => names.forEach((name) => {
        const set = new Set(this.className.split(/\s+/).filter(Boolean));
        set.add(name); this.className = Array.from(set).join(" ");
      }),
      remove: (...names) => {
        const gone = new Set(names);
        this.className = this.className.split(/\s+/).filter((n) => n && !gone.has(n)).join(" ");
      },
      contains: (name) => this.className.split(/\s+/).includes(name),
    };
  }
  appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
  remove() {
    if (!this.parentElement) return;
    this.parentElement.children = this.parentElement.children.filter((c) => c !== this);
    this.parentElement = null;
  }
  addEventListener(type, fn) { (this._listeners[type] ||= []).push(fn); }
  click() {
    if (this.disabled) return;
    for (const fn of this._listeners.click || []) fn({ preventDefault() {}, stopPropagation() {}, target: this });
  }
  focus() { this.focused = true; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name]; }
  set textContent(value) { this._text = String(value == null ? "" : value); this.children = []; }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(""); }
}

function walk(root) {
  const out = [root];
  for (const child of root.children) out.push(...walk(child));
  return out;
}

const body = new El("body");
const document = {
  body,
  documentElement: body,
  createElement: (tag) => new El(tag),
  getElementById: (id) => walk(body).find((el) => el.id === id) || null,
  addEventListener() {},
  removeEventListener() {},
};

const calls = [];
let settingsOpened = 0;
let scans = 0;
let clock = 0;
let nextTimer = 1;
const timers = new Map();
let aboutResolve = null;

function advance(ms) {
  const target = clock + ms;
  while (true) {
    let selectedId = null;
    let selected = null;
    for (const [id, timer] of timers) {
      if (timer.due <= target && (!selected || timer.due < selected.due)) {
        selectedId = id; selected = timer;
      }
    }
    if (!selected) break;
    timers.delete(selectedId);
    clock = selected.due;
    selected.fn();
  }
  clock = target;
}

const context = {
  window: { GamepadNav: { scanElements() { scans++; }, setBackHandler() {} } },
  document,
  BTN_ID: "lumen-moon-btn",
  STYLE_ID: "lumen-menu-styles",
  OVERLAY_ID: "lumen-settings-overlay",
  MOON: "🌕",
  pickLang: () => "en",
  I18N: { en: {} },
  injectStyles() {},
  requestOpen() { settingsOpened++; },
  call(fn, args) {
    calls.push({ fn, args });
    if (fn === "GetAboutUpdateStatus") {
      return new Promise((resolve) => { aboutResolve = resolve; });
    }
    return Promise.resolve('{"success":true}');
  },
  setTimeout(fn, delay) {
    const id = nextTimer++;
    timers.set(id, { fn, due: clock + Math.max(0, Number(delay) || 0) });
    return id;
  },
  clearTimeout(id) { timers.delete(id); },
  console,
};
vm.createContext(context);
vm.runInContext(fs.readFileSync("lua/menu/03-styles.js", "utf8"), context, {
  filename: "lua/menu/03-styles.js",
});
vm.runInContext(fs.readFileSync(path, "utf8"), context, { filename: path });

let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.log("FAIL " + name); failures++; }
}

function action(name) {
  return walk(body).find((el) => el.dataset && el.dataset.action === name) || null;
}

async function main() {
  const button = new El("button");
  button.id = context.BTN_ID;
  body.appendChild(button);
  context.decorateAutoFixButton(button);

  context.window.__lumenUpdateAutoFixUI({ jobs: {
    "990080": {
      appid: 990080,
      gameName: "Hogwarts Legacy",
      phase: "applying",
      stage: "downloading",
      progress: 42,
      canSkip: false,
    },
  } });
  check("U1 active work expands the moon into a compact progress pill",
    button.classList.contains("lumen-auto-fix-active")
      && button.textContent.includes("Applying fix")
      && button.textContent.includes("42%"));
  check("U2 pill exposes progress accessibly without changing the moon glyph",
    button.getAttribute("aria-label").includes("42%")
      && button.children[0].textContent === "🌕");

  context.handleMoonButtonClick({ preventDefault() {}, stopPropagation() {} });
  const modal = document.getElementById("lumen-auto-fix-overlay");
  check("U3 clicking the pill opens the named game progress dialog",
    modal && modal.textContent.includes("Hogwarts Legacy")
      && modal.textContent.includes("42%")
      && modal.getAttribute("role") === "dialog");
  context.window.__lumenShowAutoFixModal(990080, true);
  const pendingModal = document.getElementById("lumen-auto-fix-overlay");
  check("U4 active file writes allow waiting or cancelling launch, never unsafe skip",
    action("wait") && action("cancel-launch") && !action("launch-without-fix")
      && scans > 0);
  check("U5 a queued Play clearly says it will resume automatically",
    pendingModal.textContent.toLowerCase().includes("open automatically"));

  context.window.__lumenUpdateAutoFixUI({ jobs: {
    "990080": {
      appid: 990080,
      gameName: "Hogwarts Legacy",
      phase: "waiting_install",
      stage: "preparing",
      progress: 0,
      canSkip: true,
    },
  } });
  context.window.__lumenShowAutoFixModal(990080, true);
  const skip = action("launch-without-fix");
  check("U6 launch without fix is offered only before file application starts",
    skip && !skip.disabled);
  skip.click();
  await Promise.resolve();
  await Promise.resolve();
  check("U7 safe skip cancels queued work before releasing the exact launch",
    calls.some((c) => c.fn === "CancelLuaToolsAutoFix" && c.args.appid === 990080)
      && calls.some((c) => c.fn === "__lumenReleaseAutoFixLaunch" && c.args.appid === 990080));

  context.window.__lumenShowAutoFixTimeout(990080);
  context.window.__lumenUpdateAutoFixUI({ jobs: {
    "990080": {
      appid: 990080,
      gameName: "Hogwarts Legacy",
      phase: "applying",
      stage: "downloading",
      progress: 43,
      canSkip: false,
    },
  } });
  const timeoutModal = document.getElementById("lumen-auto-fix-overlay");
  check("U8 timeout cancels launch but keeps live fix progress and timeout guidance",
    timeoutModal && timeoutModal.textContent.includes("longer than expected")
      && timeoutModal.textContent.includes("43%")
      && action("wait") && !action("cancel-launch"));

  context.window.__lumenUpdateAutoFixUI({ jobs: {} });
  check("U9 completed work starts a smooth contraction without erasing its copy",
    !button.classList.contains("lumen-auto-fix-active")
      && button.textContent.includes("Applying fix"));
  advance(400);
  check("U10 contraction clears the copy only after the exit transition",
    button.textContent === "🌕");
  context.handleMoonButtonClick({ preventDefault() {}, stopPropagation() {} });
  check("U11 the idle moon keeps opening Lumen settings", settingsOpened === 1);

  context.injectStyles();
  const pillCss = document.getElementById("lumen-menu-styles").textContent;
  check("U12 the closed control is a symmetric moon-sized circle",
    pillCss.includes("height:22px;padding:0")
      && pillCss.includes("width:22px;height:22px;flex:0 0 22px"));
  check("U13 the pill body grows directly from the moon without a margin gap",
    pillCss.includes("margin-left:0;padding:0 9px 0 6px"));

  context.showMoonPillMessage("settings", "Lumen settings");
  check("U14 a regular settings message can occupy the pill",
    button.classList.contains("lumen-auto-fix-active")
      && button.textContent.includes("Lumen settings"));
  advance(4700);
  check("U15 the message remains visible for about five seconds",
    button.classList.contains("lumen-auto-fix-active"));
  advance(350);
  check("U16 the regular message begins its smooth contraction",
    !button.classList.contains("lumen-auto-fix-active")
      && button.textContent.includes("Lumen settings"));
  advance(400);

  const hasBootMessages = typeof context.startMoonPillBootMessage === "function";
  check("U17 the moon exposes its one-shot boot message controller", hasBootMessages);
  if (hasBootMessages) {
    context.startMoonPillBootMessage();
    advance(200);
    check("U18 update discovery does not flash Lumen settings while pending",
      !button.classList.contains("lumen-auto-fix-active")
        && !button.textContent.includes("Lumen settings"));

    aboutResolve(JSON.stringify({
      success: true,
      pending: false,
      available: true,
    }));
    await Promise.resolve();
    await Promise.resolve();
    check("U19 an available update is the first and only boot message",
      button.classList.contains("lumen-auto-fix-active")
        && button.textContent.includes("Updates available")
        && !button.textContent.includes("Lumen settings"));
    check("U20 update discovery uses the dedicated non-blocking status RPC once",
      calls.filter((entry) => entry.fn === "GetAboutUpdateStatus").length === 1);
    const canFinishBoot = typeof context.finishMoonPillBootMessage === "function";
    check("U21 boot messaging exposes its resolved-status selector", canFinishBoot);
    if (canFinishBoot) {
      advance(5400);
      context.finishMoonPillBootMessage(null);
      check("U22 a failed update check falls back silently to Lumen settings",
        button.textContent.includes("Lumen settings")
          && !button.textContent.includes("Updates available"));
    }
  }

  process.exitCode = failures ? 1 : 0;
}

main();
