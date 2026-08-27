// Run: node tools/test_overlay_close.js
//
// The settings window must disappear the moment the X is clicked, even while a
// tab is mid-load. The sidecar is single-threaded, so the __lumenClose relay can
// sit behind a backend call for as long as that call takes (a fixes-catalogue
// fetch can hold the loop for its full 20s HTTP timeout). A close that waited on
// the relay therefore stayed on screen for the rest of the load, and each extra
// click queued another relay that fired late — reclosing a reopened window.
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

function fragment(name) {
  return fs.readFileSync(path.join(__dirname, "..", "lua", "menu", name), "utf8");
}

// 01-core opens the shared IIFE and owns OVERLAY_ID + call(); 04 has the relays.
// The appended closer exports them so the test can drive them directly.
const source = [
  fragment("01-core.js"),
  fragment("04-overlay-helpers.js"),
  "window.__t = { requestClose: requestClose, requestOpen: requestOpen };",
  "})();",
].join("\n");

function harness() {
  const relays = [];
  let overlayPresent = true;
  let clock = 1000;
  const overlay = { remove() { overlayPresent = false; } };
  const window = {
    Millennium: {
      callServerMethod(plugin, fn) {
        // A relay that never settles stands in for the blocked sidecar loop, and
        // for the answer being dropped outright on a context recreation.
        const relay = { fn };
        relay.promise = new Promise((resolve) => { relay.settle = resolve; });
        relays.push(relay);
        return relay.promise;
      },
    },
  };
  const document = {
    getElementById: () => (overlayPresent ? overlay : null),
    removeEventListener() {},
  };
  vm.runInNewContext(source,
    { window, document, Promise, JSON, Error, console, Date: { now: () => clock } },
    { filename: "overlay-close.js" });
  return {
    relays,
    api: window.__t,
    isOpen: () => overlayPresent,
    reopen: () => { overlayPresent = true; },
    advance: (ms) => { clock += ms; },
    names: () => relays.map((relay) => relay.fn),
  };
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

async function main() {
  const h = harness();

  h.api.requestClose();
  assert.strictEqual(h.isOpen(), false,
    "the window must be gone synchronously, not when the relay resolves");
  assert.deepStrictEqual(h.relays.map((relay) => relay.fn), ["__lumenClose"],
    "closing still fans out to the other injected contexts");

  h.api.requestClose();
  h.api.requestClose();
  h.api.requestClose();
  assert.strictEqual(h.relays.length, 1,
    "a burst of closes collapses into one fan-out");

  // The first relay is still unsettled — and stays that way, standing in for a
  // dropped answer. Once the coalescing window passes, relays must go out again:
  // gating on the reply instead would wedge the window shut/open for good.
  h.advance(300);
  h.reopen();
  h.api.requestClose();
  assert.strictEqual(h.relays.length, 2,
    "a later close fans out even though the previous relay never answered");
  assert.strictEqual(h.isOpen(), false);

  // Reopening right after closing is the case that broke: the open must reach the
  // sidecar, not be swallowed because an earlier relay is unanswered.
  h.reopen();
  h.api.requestOpen();
  assert.deepStrictEqual(h.names(), ["__lumenClose", "__lumenClose", "__lumenOpen"],
    "an open right after a close is relayed, not dropped");

  // Open cannot be handled locally (it has to target whichever view is on top),
  // but a double-click must not pile up either.
  const o = harness();
  o.api.requestOpen();
  o.api.requestOpen();
  o.api.requestOpen();
  assert.deepStrictEqual(o.names(), ["__lumenOpen"], "a double-click sends one open");
  o.advance(300);
  o.api.requestOpen();
  assert.deepStrictEqual(o.names(), ["__lumenOpen", "__lumenOpen"],
    "a deliberate second open still goes out");

  console.log("ok   the X closes the window instantly, and relays never wedge or pile up");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
