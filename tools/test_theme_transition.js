"use strict";
const fs = require("fs");
const source = fs.readFileSync("lua/menu/14-themes-tab.js", "utf8");

function check(condition, message) {
  if (!condition) { console.error("FAIL: " + message); process.exit(1); }
}

check(source.includes('reload:true'),
  "every applyThemeConfig transaction explicitly stages a reload build");
check(source.includes('if(cfg.active){applyThemeConfig({enabled:on},body)'),
  "Enable themes reloads when a previously selected theme exists");
const busy = source.indexOf("showThemeApplying(body)");
const transaction = source.indexOf('themeCall("LumenThemesSetConfig",transaction)');
check(busy >= 0 && transaction >= 0 && busy < transaction,
  "theme switching blocks the UI before the potentially slow theme build starts");
check(source.includes('classList.add("lumen-theme-busy")'),
  "theme switching exposes an immediate visible busy state");
console.log("test_theme_transition: ok");
