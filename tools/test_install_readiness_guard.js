const fs = require("fs");
const vm = require("vm");

const guardPath = "lua/install-readiness-guard.js";
if (!fs.existsSync(guardPath)) {
  console.error("FAIL install readiness guard implementation is missing");
  process.exit(1);
}
const source = fs.readFileSync(guardPath, "utf8");
let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.error("FAIL " + name); failures += 1; }
}

function harness() {
  const nativeCalls = [];
  const notices = [];
  let now = 1000;
  const installs = {
    OpenInstallWizard() {
      const args = Array.prototype.slice.call(arguments);
      nativeCalls.push({ self: this, args });
      return "native-result";
    },
  };
  const window = {
    SteamClient: { Installs: installs },
    __lumenSend(raw) { notices.push(JSON.parse(raw)); },
  };
  const context = {
    window,
    SteamClient: window.SteamClient,
    Date: { now() { return now; } },
    JSON,
    Number,
    String,
    Array,
    Object,
    Math,
    Map,
  };
  vm.runInNewContext(source, context);
  return {
    window, installs, nativeCalls, notices,
    setNow(value) { now = value; },
  };
}

const h = harness();
const unknown = h.installs.OpenInstallWizard([10]);
check("G1 unknown apps pass through with the native result",
  unknown === "native-result" && h.nativeCalls.length === 1
    && h.nativeCalls[0].self === h.installs
    && h.nativeCalls[0].args[0][0] === 10);

h.window.__lumenUpdateInstallReadinessGuard({
  20: { blocking: true, ttlMs: 5000 },
  30: { blocking: false, ttlMs: 5000 },
});
const blocked = h.installs.OpenInstallWizard([20], "library-context");
check("G2 an explicitly blocked single app never reaches Steam",
  blocked === undefined && h.nativeCalls.length === 1
    && h.notices.length === 1
    && h.notices[0].fn === "__lumenInstallBlocked"
    && h.notices[0].args.appid === 20);

const ready = h.installs.OpenInstallWizard([30]);
check("G3 an explicitly ready app passes through",
  ready === "native-result" && h.nativeCalls.length === 2);

h.installs.OpenInstallWizard([20, 30]);
check("G4 bulk installs always pass through unchanged",
  h.nativeCalls.length === 3
    && h.nativeCalls[2].args[0].join(",") === "20,30");

h.setNow(7000);
h.installs.OpenInstallWizard([20]);
check("G5 expired state fails open",
  h.nativeCalls.length === 4);

h.window.__lumenUpdateInstallReadinessGuard({ 20: { blocking: true, ttlMs: 5000 } });
const allowed = h.window.__lumenInstallAnyway(20);
check("G6 install-anyway invokes the captured native wizard immediately",
  allowed === true && h.nativeCalls.length === 5
    && h.nativeCalls[4].args[0][0] === 20
    && h.nativeCalls[4].args[1] === "library-context");

h.window.__lumenUpdateInstallReadinessGuard({ 20: { blocking: true, ttlMs: "bad" } });
h.installs.OpenInstallWizard([20]);
check("G7 malformed state fails open",
  h.nativeCalls.length === 6);

const restored = h.window.__lumenSetInstallReadinessGuardEnabled(false);
h.installs.OpenInstallWizard([20]);
check("G8 disabling the guard restores the exact native function",
  restored === true && h.installs.OpenInstallWizard.name === "OpenInstallWizard"
    && h.nativeCalls.length === 7);

const relayless = harness();
relayless.window.__lumenUpdateInstallReadinessGuard({
  40: { blocking: true, ttlMs: 5000 },
});
delete relayless.window.__lumenSend;
relayless.installs.OpenInstallWizard([40]);
check("G9 a missing modal relay fails open instead of silently swallowing Install",
  relayless.nativeCalls.length === 1);

h.window.__lumenSetInstallReadinessGuardEnabled(true);
h.window.__lumenUpdateInstallReadinessGuard({ 50: { blocking: true, ttlMs: 5000 } });
h.installs.OpenInstallWizard([50]);
check("G10 re-enabling reinstalls the wrapper without touching the native function",
  h.installs.OpenInstallWizard.name === "guardedOpenInstallWizard"
    && h.nativeCalls.length === 7 && h.notices.length === 2);

process.exitCode = failures ? 1 : 0;
