(function () {
  "use strict";
  if (window.__lumenInstallReadinessGuardInstalled) return;
  if (!(window.SteamClient && SteamClient.Installs
      && typeof SteamClient.Installs.OpenInstallWizard === "function")) return;

  const installs = SteamClient.Installs;
  const nativeOpenInstallWizard = installs.OpenInstallWizard;
  let readiness = Object.create(null);
  let blockedCalls = Object.create(null);
  let enabled = true;
  let noticeSequence = 0;

  function positiveAppId(value) {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 && Math.floor(number) === number
      ? number : null;
  }

  function singleAppId(args) {
    const appids = args && args[0];
    if (!Array.isArray(appids) || appids.length !== 1) return null;
    return positiveAppId(appids[0]);
  }

  function isBlocked(appid) {
    const state = readiness[String(appid)];
    return !!(state && state.blocking === true
      && Number.isFinite(state.expiresAt) && state.expiresAt > Date.now());
  }

  function notifyBlocked(appid) {
    try {
      if (typeof window.__lumenSend !== "function") return false;
      window.__lumenSend(JSON.stringify({
        id: "install-readiness-guard-" + (++noticeSequence),
        fn: "__lumenInstallBlocked",
        args: { appid: appid },
      }));
      return true;
    } catch (_) { return false; }
  }

  function guardedOpenInstallWizard() {
    try {
      if (enabled) {
        const appid = singleAppId(arguments);
        if (appid !== null && isBlocked(appid)) {
          if (notifyBlocked(appid)) {
            blockedCalls[String(appid)] = Array.prototype.slice.call(arguments);
            return undefined;
          }
        }
      }
    } catch (_) {
      // The guard is deliberately fail-open. Any unexpected state or future
      // Steam bridge change must preserve the native installation path.
    }
    return nativeOpenInstallWizard.apply(installs, arguments);
  }

  installs.OpenInstallWizard = guardedOpenInstallWizard;
  window.__lumenInstallReadinessGuardInstalled = true;

  window.__lumenUpdateInstallReadinessGuard = function (next) {
    const updated = Object.create(null);
    const now = Date.now();
    try {
      if (next && typeof next === "object") {
        Object.keys(next).forEach(function (key) {
          const appid = positiveAppId(key);
          const state = next[key];
          const ttlMs = state && Number(state.ttlMs);
          if (appid === null || !state || state.blocking !== true
              || !Number.isFinite(ttlMs) || ttlMs <= 0) return;
          updated[String(appid)] = {
            blocking: true,
            expiresAt: now + ttlMs,
          };
        });
      }
      readiness = updated;
    } catch (_) {
      readiness = Object.create(null);
    }
  };

  window.__lumenInstallAnyway = function (appid) {
    appid = positiveAppId(appid);
    if (appid === null) return false;
    try {
      const args = blockedCalls[String(appid)];
      if (!args || singleAppId(args) !== appid) return false;
      delete blockedCalls[String(appid)];
      nativeOpenInstallWizard.apply(installs, args);
      return true;
    } catch (_) {
      return false;
    }
  };

  window.__lumenSetInstallReadinessGuardEnabled = function (next) {
    enabled = next !== false;
    if (!enabled && installs.OpenInstallWizard === guardedOpenInstallWizard) {
      installs.OpenInstallWizard = nativeOpenInstallWizard;
    } else if (enabled && installs.OpenInstallWizard === nativeOpenInstallWizard) {
      installs.OpenInstallWizard = guardedOpenInstallWizard;
    }
    return true;
  };
})();
