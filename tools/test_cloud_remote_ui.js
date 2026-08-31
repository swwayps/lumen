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
  "\nwindow.__testCloudMerge = typeof cloudMergeApps === \"function\" ? cloudMergeApps : null;" +
  "\nwindow.__testCloudAppsResolved = typeof cloudAppsResolved === \"function\" ? cloudAppsResolved : null;" +
  "\nwindow.__testCloudRemoteSet = typeof cloudRemoteSet === \"function\" ? cloudRemoteSet : null;" +
  "\nwindow.__testCloudBadgeKind = typeof cloudBadgeKind === \"function\" ? cloudBadgeKind : null;" +
  "\nwindow.__testCloudComparableDraft = typeof cloudComparableDraft === \"function\" ? cloudComparableDraft : null;\n})();";

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

const resolved = context.window.__testCloudAppsResolved;
if (typeof resolved !== "function") {
  console.error("FAIL: cloudAppsResolved is not defined");
  process.exit(1);
}
eq(resolved(7, {}), false,
  "selected account remains loading before its remote listing resolves");
eq(resolved(7, { 7: {} }), true,
  "selected account becomes renderable after an empty remote listing resolves");
eq(resolved(null, {}), true,
  "a local-only view does not wait for a remote account");

const remoteSet = context.window.__testCloudRemoteSet;
if (typeof remoteSet !== "function") {
  console.error("FAIL: cloudRemoteSet is not defined");
  process.exit(1);
}
const presence = remoteSet([{ appid: 311690 }, 534380]);
eq(presence[311690].statsKnown, false,
  "presence-only remote games mark detailed statistics as unknown");

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
eq(byId[311690].statsKnown, true, "structured remote stats remain displayable");

const presenceOnly = merge([], presence, 7)[0];
eq(presenceOnly.statsKnown, false,
  "presence-only remote game never presents made-up zero statistics");

const badgeKind = context.window.__testCloudBadgeKind;
if (typeof badgeKind !== "function") {
  console.error("FAIL: cloudBadgeKind is not defined");
  process.exit(1);
}
eq(badgeKind({ local: true, remote: true }, true), "both",
  "presence in both locations is not mislabeled as synced");
eq(badgeKind({ local: true, remote: false }, true), "local", "local badge kind");
eq(badgeKind({ local: false, remote: true }, true), "cloud", "cloud badge kind");

const comparableDraft = context.window.__testCloudComparableDraft;
if (typeof comparableDraft !== "function") {
  console.error("FAIL: cloudComparableDraft is not defined");
  process.exit(1);
}
const pendingAuth = comparableDraft({
  provider: "local", sync_activity: false, sign_out_provider: null,
  settings: { local: {} }, authenticated: { gdrive: true, onedrive: false },
});
eq(pendingAuth.authenticated.gdrive, true,
  "a staged OAuth login remains part of the draft even after selecting another provider");

if (!cloud.includes("local_appids")) {
  console.error("FAIL: remote RPC payload does not include local_appids");
  process.exit(1);
}
if (!cloud.includes("r.apps")) {
  console.error("FAIL: remote RPC response does not consume structured apps");
  process.exit(1);
}
if (!cloud.includes("if (!cloudAppsResolved(currentAccount, remoteSets))")) {
  console.error("FAIL: cloud games draw does not retain loading until remote state is complete");
  process.exit(1);
}
if (cloud.includes("cloudReadRemoteCache") || cloud.includes("cloudWriteRemoteCache")) {
  console.error("FAIL: stale remote presence cache still influences cloud status");
  process.exit(1);
}
if (cloud.includes('loc = app.local && app.remote ? "synced"')) {
  console.error("FAIL: both-presence still maps to Synced");
  process.exit(1);
}
if (!cloud.includes("appsRemoteFail")) {
  console.error("FAIL: remote provider errors are not rendered explicitly");
  process.exit(1);
}
for (const field of ["endpoint", "sign_payload", "allow_insecure_http",
                     "allow_insecure_tls", "ca_cert_path"]) {
  if (!cloud.includes(field)) {
    console.error(`FAIL: provider settings omit upstream field ${field}`);
    process.exit(1);
  }
}

console.log("test_cloud_remote_ui: ALL PASS");
