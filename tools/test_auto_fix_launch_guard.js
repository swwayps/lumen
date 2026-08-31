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
function nativeRunGame(...args) { calls.push(args); return "started"; }
const context = {
  window: {},
  SteamClient: { Apps: { RunGame: nativeRunGame }, URL: {
    ExecuteSteamURL(url) { steamUrls.push(url); return "handled"; },
  } },
  setTimeout(fn, ms) { timers.push({ fn, ms }); return timers.length; },
  clearTimeout() {},
  console,
};
context.window.SteamClient = context.SteamClient;
context.window.__lumenKey = "test-key";
context.window.__lumenSend = function (raw) { notices.push(JSON.parse(raw)); };
vm.runInNewContext(source, context);

check("G1 an idle guard leaves Steam's exact native RunGame installed",
  context.SteamClient.Apps.RunGame === nativeRunGame);

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "waiting_install", cancelOnPlay: true },
});
const prewrite = context.SteamClient.Apps.RunGame("990080", "prewrite", -1, 4);
check("G2 pre-write work is cancelled without delaying native Play",
  prewrite === "started" && calls.length === 1 && calls[0][1] === "prewrite"
    && notices[0] && notices[0].fn === "CancelLuaToolsAutoFix"
    && notices[0].args.appid === 990080);

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", cancelOnPlay: true, rollback: true },
});
const applying = context.SteamClient.Apps.RunGame("990080", "rollback", -1, 5);
check("G3 live writes defer only the matching Play while requesting cancellation",
  applying === undefined && calls.length === 1
    && notices[notices.length - 1].fn === "CancelLuaToolsAutoFix");
check("G4 the Play path never requests a blocking modal",
  notices.every((notice) => !String(notice.fn).includes("LaunchWait")));

context.SteamClient.Apps.RunGame("3321460", "owned", -1, 6);
check("G5 unrelated and owned games keep the native launch path",
  calls.length === 2 && calls[1][0] === "3321460" && calls[1][1] === "owned");

context.window.__lumenUpdateAutoFixGuard({});
check("G6 terminal cleanup replays the exact deferred call once and detaches",
  calls.length === 3 && calls[2][0] === "990080" && calls[2][1] === "rollback"
    && context.SteamClient.Apps.RunGame === nativeRunGame);

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", cancelOnPlay: true, rollback: true },
});
context.SteamClient.Apps.RunGame("990080", "deadline", -1, 7);
const deadline = timers[timers.length - 1];
if (deadline) deadline.fn();
context.window.__lumenUpdateAutoFixGuard({});
check("G7 a bounded fail-open deadline can never leave Play pending",
  deadline && deadline.ms > 0 && deadline.ms <= 2500
    && calls.length === 4 && calls[3][1] === "deadline");

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", cancelOnPlay: true, rollback: true },
});
delete context.window.__lumenSend;
const noBridge = context.SteamClient.Apps.RunGame("990080", "no-bridge", -1, 8);
check("G8 a missing cancellation bridge fails open immediately",
  noBridge === "started" && calls.length === 5 && calls[4][1] === "no-bridge");
context.window.__lumenSend = function (raw) { notices.push(JSON.parse(raw)); };

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", cancelOnPlay: true, rollback: true },
});
delete context.window.__lumenKey;
const noToken = context.SteamClient.Apps.RunGame("990080", "no-token", -1, 9);
check("G8b a missing binding token also fails open immediately",
  noToken === "started" && calls.length === 6 && calls[5][1] === "no-token");
context.window.__lumenKey = "test-key";

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", cancelOnPlay: true, rollback: true },
});
const beforeDuplicateNotices = notices.length;
context.SteamClient.Apps.RunGame("990080", "first", -1, 9);
context.SteamClient.Apps.RunGame("990080", "second", -1, 10);
context.window.__lumenUpdateAutoFixGuard({});
check("G9 repeated Play cannot queue or launch the game twice",
  calls.length === 7 && calls[6][1] === "first"
    && notices.length === beforeDuplicateNotices + 1);

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", cancelOnPlay: true, rollback: true },
});
context.SteamClient.Apps.RunGame("990080", "survives-unrelated-uninstall", -1, 11);
context.SteamClient.URL.ExecuteSteamURL("steam://uninstall/3357650");
context.window.__lumenUpdateAutoFixGuard({});
check("G10 uninstalling another game cannot cancel the exact pending Play",
  calls.length === 8 && calls[7][1] === "survives-unrelated-uninstall"
    && steamUrls[0] === "steam://uninstall/3357650");

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", cancelOnPlay: true, rollback: true },
});
context.SteamClient.Apps.RunGame("990080", "must-not-survive", -1, 12);
context.SteamClient.URL.ExecuteSteamURL("steam://uninstall/990080");
context.window.__lumenUpdateAutoFixGuard({});
check("G10b uninstalling the same game drops its deferred Play and cancels work",
  calls.length === 8 && steamUrls[1] === "steam://uninstall/990080"
    && notices[notices.length - 1].fn === "CancelLuaToolsAutoFix"
    && notices[notices.length - 1].args.appid === 990080);

vm.runInNewContext(source, context);
context.window.__lumenUpdateAutoFixGuard({});
check("G11 reinjection is idempotent and does not replace native RunGame",
  calls.length === 8 && context.SteamClient.Apps.RunGame === nativeRunGame);

context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", cancelOnPlay: true, rollback: true },
});
const guardRunGame = context.SteamClient.Apps.RunGame;
function laterSteamWrapper(...args) { return guardRunGame.apply(this, args); }
context.SteamClient.Apps.RunGame = laterSteamWrapper;
context.window.__lumenUpdateAutoFixGuard({});
context.window.__lumenUpdateAutoFixGuard({
  "990080": { phase: "applying", cancelOnPlay: true, rollback: true },
});
let interleavedResult;
try {
  interleavedResult = context.SteamClient.Apps.RunGame("3321460", "interleaved", -1, 13);
} catch (error) {
  interleavedResult = error;
}
context.window.__lumenUpdateAutoFixGuard({});
check("G12 another Steam wrapper installed above the guard cannot create recursion",
  interleavedResult === "started" && calls.length === 9
    && calls[8][1] === "interleaved"
    && context.SteamClient.Apps.RunGame === laterSteamWrapper);

process.exitCode = failures ? 1 : 0;
