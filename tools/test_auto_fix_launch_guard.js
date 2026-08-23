const fs = require("fs");
const vm = require("vm");

const path = "lua/auto-fix-launch-guard.js";
if (!fs.existsSync(path)) {
  console.error("FAIL auto-fix launch guard asset is missing");
  process.exit(1);
}

const source = fs.readFileSync(path, "utf8");
let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.log("FAIL " + name); failures++; }
}

const calls = [];
const steamUrls = [];
const timers = [];
const notices = [];
const context = {
  window: {},
  SteamClient: { Apps: {
    RunGame(...args) { calls.push(args); return "started"; },
  }, URL: {
    ExecuteSteamURL(url) { steamUrls.push(url); return "handled"; },
  } },
  setTimeout(fn) { timers.push(fn); return timers.length; },
  clearTimeout() {},
  console,
};
context.window.SteamClient = context.SteamClient;
context.window.__lumenSend = function (raw) { notices.push(JSON.parse(raw)); };
vm.runInNewContext(source, context);

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", blocking: true },
});
const deferred = context.SteamClient.Apps.RunGame("990080", "", -1, 4);
check("G1 a pending automatic fix defers the matching game launch",
  deferred === undefined && calls.length === 0
    && notices[0] && notices[0].fn === "__lumenAutoFixLaunchWait"
    && notices[0].args.appid === 990080);

context.SteamClient.Apps.RunGame("3321460", "", -1, 4);
check("G2 unrelated games keep the native launch path",
  calls.length === 1 && calls[0][0] === "3321460");

context.window.__lumenUpdateAutoFixGuard({});
check("G3 completing the fix resumes the exact deferred launch once",
  calls.length === 2 && calls[1][0] === "990080"
    && calls[1][1] === "" && calls[1][2] === -1 && calls[1][3] === 4);

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", blocking: true },
});
context.SteamClient.Apps.RunGame("990080", "safe", -1, 7);
timers[timers.length - 1]();
context.window.__lumenUpdateAutoFixGuard({});
check("G4 timeout cancels the attempt instead of launching into partial files",
  calls.length === 2
    && notices[notices.length - 1]
    && notices[notices.length - 1].fn === "__lumenAutoFixLaunchTimeout");

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "waiting_install", blocking: true },
});
context.SteamClient.Apps.RunGame("990080", "without-fix", -1, 8);
if (typeof context.window.__lumenReleaseAutoFixLaunch === "function") {
  context.window.__lumenReleaseAutoFixLaunch("990080");
}
check("G5 launch-without-fix releases the exact queued native call",
  calls.length === 3 && calls[2][1] === "without-fix" && calls[2][3] === 8);

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", blocking: true },
});
context.SteamClient.Apps.RunGame("990080", "cancelled", -1, 9);
if (typeof context.window.__lumenCancelAutoFixLaunch === "function") {
  context.window.__lumenCancelAutoFixLaunch("990080");
}
context.window.__lumenUpdateAutoFixGuard({});
check("G6 cancel launch drops only the queued launch attempt",
  calls.length === 3);

vm.runInNewContext(source, context);
context.window.__lumenUpdateAutoFixGuard({});
check("G7 reinjection is idempotent and never stacks RunGame wrappers",
  calls.length === 3);

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", blocking: true },
});
context.SteamClient.Apps.RunGame("990080", "must-not-survive", -1, 10);
context.SteamClient.URL.ExecuteSteamURL("steam://uninstall/3357650");
context.window.__lumenReleaseAutoFixLaunch("990080");
check("G8 any uninstall invalidates every deferred launch before Steam handles it",
  calls.length === 3
    && steamUrls.length === 1
    && steamUrls[0] === "steam://uninstall/3357650");

process.exitCode = failures ? 1 : 0;
