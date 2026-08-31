(function () {
  "use strict";
  if (window.__lumenAutoFixGuardInstalled) return;
  if (!(window.SteamClient && SteamClient.Apps
      && typeof SteamClient.Apps.RunGame === "function")) return;

  window.__lumenAutoFixGuardInstalled = true;
  const apps = SteamClient.Apps;
  const steamUrl = SteamClient.URL;
  const deferred = new Map();
  const bypassed = new Set();
  const CANCEL_DEADLINE_MS = 2500;
  let jobs = Object.create(null);
  let downstreamRunGame = apps.RunGame;
  let downstreamExecuteSteamURL = steamUrl
    && typeof steamUrl.ExecuteSteamURL === "function"
    ? steamUrl.ExecuteSteamURL : null;
  let runGameAttached = false;
  let steamUrlAttached = false;
  let noticeSequence = 0;

  function autoFixState(value) {
    if (!value || typeof value !== "object" || value.cancelOnPlay !== true) return null;
    const phase = String(value.phase || "");
    if (phase !== "waiting_install" && phase !== "needs_login"
        && phase !== "applying" && phase !== "finalizing"
        && phase !== "cancelling" && phase !== "failed") return null;
    return { phase: phase, cancelOnPlay: true, rollback: value.rollback === true };
  }

  function notifyCancel(appid) {
    try {
      if (typeof window.__lumenSend !== "function"
          || typeof window.__lumenKey !== "string" || !window.__lumenKey) return false;
      window.__lumenSend(JSON.stringify({
        id: "auto-fix-guard-" + (++noticeSequence),
        fn: "CancelLuaToolsAutoFix",
        args: { appid: Number(appid) },
        k: window.__lumenKey,
      }));
      return true;
    } catch (_) { return false; }
  }

  function appIdForGameId(gameId) {
    const text = String(gameId == null ? "" : gameId);
    if (jobs[text]) return text;
    try { return String(BigInt(text) & 0xffffffn); }
    catch (_) { return text; }
  }

  function runNative(args) {
    return downstreamRunGame.apply(apps, args);
  }

  function release(appid, failOpen) {
    const pending = deferred.get(appid);
    if (!pending) return false;
    deferred.delete(appid);
    clearTimeout(pending.timer);
    if (failOpen) bypassed.add(appid);
    runNative(pending.args);
    return true;
  }

  function cancel(appid) {
    const pending = deferred.get(appid);
    if (!pending) return false;
    deferred.delete(appid);
    clearTimeout(pending.timer);
    return true;
  }

  function guardedRunGame() {
    const args = Array.prototype.slice.call(arguments);
    const appid = appIdForGameId(args[0]);
    const state = autoFixState(jobs[appid]);
    if (!state || bypassed.has(appid)) return runNative(args);
    if (deferred.has(appid)) return undefined;

    if (!state.rollback) {
      notifyCancel(appid);
      return runNative(args);
    }

    const pending = { args: args, timer: null };
    deferred.set(appid, pending);
    if (!notifyCancel(appid)) {
      deferred.delete(appid);
      return runNative(args);
    }
    pending.timer = setTimeout(function () {
      release(appid, true);
    }, CANCEL_DEADLINE_MS);
    return undefined;
  }

  function guardedExecuteSteamURL(url) {
    const match = /^steam:\/\/uninstall\/(\d+)/i.exec(String(url || ""));
    if (match) {
      const appid = appIdForGameId(match[1]);
      if (jobs[appid]) notifyCancel(appid);
      cancel(appid);
    }
    return downstreamExecuteSteamURL.apply(steamUrl, arguments);
  }

  function attach() {
    if (!runGameAttached) {
      downstreamRunGame = apps.RunGame;
      apps.RunGame = guardedRunGame;
      runGameAttached = true;
    }
    if (steamUrl && downstreamExecuteSteamURL && !steamUrlAttached) {
      downstreamExecuteSteamURL = steamUrl.ExecuteSteamURL;
      steamUrl.ExecuteSteamURL = guardedExecuteSteamURL;
      steamUrlAttached = true;
    }
  }

  function detach() {
    if (runGameAttached && apps.RunGame === guardedRunGame) {
      apps.RunGame = downstreamRunGame;
      runGameAttached = false;
    }
    if (steamUrlAttached && steamUrl
        && steamUrl.ExecuteSteamURL === guardedExecuteSteamURL) {
      steamUrl.ExecuteSteamURL = downstreamExecuteSteamURL;
      steamUrlAttached = false;
    }
    bypassed.clear();
  }

  window.__lumenUpdateAutoFixGuard = function (next) {
    const updated = Object.create(null);
    try {
      if (next && typeof next === "object") {
        Object.keys(next).forEach(function (key) {
          const state = autoFixState(next[key]);
          if (state) updated[String(key)] = state;
        });
      }
    } catch (_) {}
    jobs = updated;

    Array.from(deferred.keys()).forEach(function (appid) {
      const state = autoFixState(jobs[appid]);
      if (!state || !state.rollback) release(appid, false);
    });
    Array.from(bypassed).forEach(function (appid) {
      if (!jobs[appid]) bypassed.delete(appid);
    });
    if (Object.keys(jobs).length > 0) attach(); else detach();
  };
})();
