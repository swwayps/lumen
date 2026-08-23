const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

class FakeElement {
  constructor(tagName) {
    this.tagName = String(tagName || "").toUpperCase();
    this.className = "";
    this.children = [];
    this.listeners = {};
    this.type = "";
    this._textContent = "";
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  addEventListener(name, listener) {
    this.listeners[name] = listener;
  }

  setAttribute() {}

  set textContent(value) {
    this._textContent = String(value || "");
    this.children = [];
  }

  get textContent() {
    return this._textContent + this.children.map((child) => child.textContent || "").join("");
  }
}

async function main() {
  const context = {
    document: { createElement: (tagName) => new FakeElement(tagName) },
    pickLang: () => "en",
    window: {},
  };
  vm.runInNewContext(
    fs.readFileSync("lua/menu/09-luatools-account.js", "utf8"),
    context,
    { filename: "09-luatools-account.js" },
  );

  assert.strictEqual(typeof context.luaToolsLoadFixesCatalogue, "function");
  assert.strictEqual(typeof context.luaToolsFixesBackButton, "function");
  assert.strictEqual(typeof context.luaToolsIsSelectableFixTag, "function");

  const payload = { success: true, games: [{ appid: 3321460 }] };
  const cachedState = {
    payload,
    query: "crimson",
    activeTag: "voices38-crack",
    page: 3,
  };
  let loads = 0;
  const cached = await context.luaToolsLoadFixesCatalogue(cachedState, () => {
    loads += 1;
    return Promise.resolve({ success: false });
  });
  assert.strictEqual(loads, 0, "Back should not reload the fixes catalogue");
  assert.strictEqual(cached.payload, payload);
  assert.strictEqual(cached.query, "crimson");
  assert.strictEqual(cached.activeTag, "voices38-crack");
  assert.strictEqual(cached.page, 3);

  const freshPayload = { success: true, games: [{ appid: 10 }] };
  const fresh = await context.luaToolsLoadFixesCatalogue(null, () => {
    loads += 1;
    return Promise.resolve(freshPayload);
  });
  assert.strictEqual(loads, 1, "Initial catalogue render should load once");
  assert.strictEqual(fresh.payload, freshPayload);

  let backClicks = 0;
  const back = context.luaToolsFixesBackButton("Back", () => { backClicks += 1; });
  assert.strictEqual(back.tagName, "BUTTON");
  assert.match(back.className, /lumen-fixes-detail-back/);
  back.listeners.click();
  assert.strictEqual(backClicks, 1);

  assert.strictEqual(
    context.luaToolsIsSelectableFixTag({ slug: "steamtools-achievements-fix" }),
    false,
    "SteamTools Achievements Fix is release metadata, not a category",
  );
  assert.strictEqual(
    context.luaToolsIsSelectableFixTag({ slug: "voices38-crack" }),
    true,
  );

  console.log("ok   fixes detail navigation reuses cache and exposes only real categories");

  // Chip palette: the API can hand us any hex, so both chip states have to stay
  // legible on their own. Resting text clears the luminance floor; the selected
  // chip flips its ink so bright fills don't get white text on them.
  assert.strictEqual(typeof context.luaToolsTagPalette, "function");
  assert.strictEqual(context.luaToolsTagPalette("not a colour"), null,
    "a tag without a usable colour falls back to the CSS defaults");

  const floor = 0.3;
  [
    "#0b6ee8", // Ubisoft-dark blue: unreadable as-is on the chip surface
    "#16a34a",
    "#7c3aed",
    "#000000",
    "#edc72d",
    "#ffffff",
  ].forEach((color) => {
    const palette = context.luaToolsTagPalette(color);
    const inkLuminance = context.luaToolsLuminance(
      [1, 3, 5].map((at) => parseInt(palette.ink.slice(at, at + 2), 16)),
    );
    assert.ok(inkLuminance >= floor - 1e-6,
      color + " chip text should clear the luminance floor, got " + inkLuminance);
  });

  assert.strictEqual(context.luaToolsTagPalette("#edc72d").activeInk, "#10131a",
    "a bright selected chip takes dark ink");
  assert.strictEqual(context.luaToolsTagPalette("#0b6ee8").activeInk, "#ffffff",
    "a dark selected chip keeps white ink");
  assert.strictEqual(context.luaToolsTagPalette("#58a6ff").activeFill, "#58a6ff",
    "the selected chip is filled with the tag's own colour");

  let painted = new FakeElement("span");
  painted.style = {};
  assert.strictEqual(context.luaToolsPaintTagChip(painted, "", false), false,
    "a colourless tag leaves the chip to the stylesheet");
  assert.deepStrictEqual(painted.style, {});
  assert.strictEqual(context.luaToolsPaintTagChip(painted, "#edc72d", true), true);
  assert.strictEqual(painted.style.backgroundColor, "#edc72d");
  assert.strictEqual(painted.style.color, "#10131a");

  console.log("ok   tag chips stay readable for any lua.tools colour");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
