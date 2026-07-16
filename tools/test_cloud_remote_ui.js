// Run: node tools/test_cloud_remote_ui.js
// Cloud Saves merge regression: remote-only games use provider statistics,
// while synced games keep the local scanner's statistics.
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const menuDir = path.join(__dirname, "..", "lua", "menu");
const core = fs.readFileSync(path.join(menuDir, "01-core.js"), "utf8");
const cloud = fs.readFileSync(path.join(menuDir, "12-cloud-tab.js"), "utf8");
const source = core + "\n" + cloud +
  "\nwindow.__testCloudMerge = typeof cloudMergeApps === \"function\" ? cloudMergeApps : null;\n})();";

const context = {
  window: {},
  console: { log() {} },
  setTimeout: () => 0,
  clearTimeout() {},
};
vm.createContext(context);
vm.runInContext(source, context, { filename: "cloud_remote_ui_bundle.js" });

const merge = context.window.__testCloudMerge;
if (typeof merge !== "function") {
  console.error("FAIL: cloudMergeApps is not defined");
  process.exit(1);
}

const merged = merge(
  [{ appid: 534380, account: 7, files: 2, size: 70006 }],
  {
    534380: { appid: 534380, files: 0, size: 0 },
    311690: { appid: 311690, files: 1, size: 5423 },
  },
  7
);

const byId = Object.fromEntries(merged.map((app) => [app.appid, app]));
function eq(got, want, message) {
  if (got !== want) {
    console.error(`FAIL: ${message} (got=${got} want=${want})`);
    process.exit(1);
  }
}

eq(byId[534380].local, true, "synced game remains local");
eq(byId[534380].remote, true, "synced game remains remote");
eq(byId[534380].files, 2, "synced game keeps local file count");
eq(byId[534380].size, 70006, "synced game keeps local byte size");
eq(byId[311690].local, false, "remote-only game is not local");
eq(byId[311690].remote, true, "remote-only game is remote");
eq(byId[311690].files, 1, "remote-only game uses remote file count");
eq(byId[311690].size, 5423, "remote-only game uses remote byte size");

if (!cloud.includes("local_appids")) {
  console.error("FAIL: remote RPC payload does not include local_appids");
  process.exit(1);
}
if (!cloud.includes("r.apps")) {
  console.error("FAIL: remote RPC response does not consume structured apps");
  process.exit(1);
}

console.log("test_cloud_remote_ui: ALL PASS");
