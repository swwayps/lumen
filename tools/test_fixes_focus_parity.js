"use strict";

// The Fixes Menu is driven by pointer AND gamepad, so every hover affordance
// needs a matching focus rule — otherwise the D-pad lands on a tile that looks
// untouched (the danger tile keeping a grey icon was the visible symptom).
// Also guards the alert/confirm helpers, whose absence made "Unfix" a dead end.

const fs = require("fs");

const fixes = fs.readFileSync("lua/menu/10-fixes-menu.js", "utf8");
let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.error("FAIL " + name); failures += 1; }
}

// Every call site must resolve: these were dropped once and the menu silently
// stopped responding.
const called = new Set();
for (const match of fixes.matchAll(/\b(fxAlert|fxConfirm)\s*\(/g)) called.add(match[1]);
for (const name of called) {
  check(name + " used by the menu is defined in the same closure",
    new RegExp("function\\s+" + name + "\\s*\\(").test(fixes));
}
check("the destructive confirm is reachable by gamepad",
  /function fxConfirm[\s\S]{0,900}trapModalFocus/.test(fixes));

// Hover/focus parity for the states a user can see on a tile.
const parity = [
  ["tile highlight", /\.lumen-fx-tile:hover,\.lumen-fx-tile\.active-focus\{/],
  ["tile icon", /\.lumen-fx-tile:hover \.ic,\.lumen-fx-tile\.active-focus \.ic\{/],
  ["danger border", /\.lumen-fx-tile\.danger:hover,\.lumen-fx-tile\.danger\.active-focus\{/],
  ["danger icon turns red", /\.lumen-fx-tile\.danger:hover \.ic,\.lumen-fx-tile\.danger\.active-focus \.ic\{/],
  ["featured logo cross-fade", /\.lumen-fx-tile\.featured:not\(\.off\)\.active-focus \.lumen-lt-logo-brand\{/],
  ["close button", /\.lumen-fx-x:hover,\.lumen-fx-x\.active-focus\{/],
];
for (const [label, pattern] of parity) {
  check("gamepad focus matches hover for the " + label, pattern.test(fixes));
}

const styles = fs.readFileSync("lua/menu/03-styles.js", "utf8");
check("settings tabs highlight under gamepad focus",
  /\.lumen-tab\.active-focus\{/.test(styles));
check("the focus ring itself stays visible at Gamepad UI scale",
  /\.active-focus\{outline:3px solid/.test(styles));

process.exitCode = failures ? 1 : 0;
