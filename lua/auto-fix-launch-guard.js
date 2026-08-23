(function () {
  "use strict";
  if (window.__lumenAutoFixGuardInstalled) return;
  if (!(window.SteamClient && SteamClient.Apps &&
      typeof SteamClient.Apps.RunGame === "function")) return;

  window.__lumenAutoFixGuardInstalled = true;
  const nativeRunGame = SteamClient.Apps.RunGame.bind(SteamClient.Apps);
  const deferred = new Map();
  let blocking = Object.create(null);
  let noticeSequence = 0;

  function isBlocking(value) {
    return value === true || !!(value && value.blocking === true);
  }

  function notify(fn, appid) {
    try {
      if (typeof window.__lumenSend !== "function") return;
      window.__lumenSend(JSON.stringify({
        id: "auto-fix-guard-" + (++noticeSequence),
        fn: fn,
        args: { appid: Number(appid) },
      }));
    } catch (_) {}
  }

  function appIdForGameId(gameId) {
    const text = String(gameId == null ? "" : gameId);
    if (blocking[text]) return text;
    try { return String(BigInt(text) & 0xffffffn); }
    catch (_) { return text; }
  }

  function release(appid) {
    const pending = deferred.get(appid);
    if (!pending) return;
    deferred.delete(appid);
    clearTimeout(pending.timer);
    nativeRunGame.apply(null, pending.args);
  }

  function cancel(appid) {
    const pending = deferred.get(appid);
    if (!pending) return false;
    deferred.delete(appid);
    clearTimeout(pending.timer);
    return true;
  }

  function cancelAll() {
    Array.from(deferred.keys()).forEach(cancel);
  }

  if (SteamClient.URL &&
      typeof SteamClient.URL.ExecuteSteamURL === "function") {
    const nativeExecuteSteamURL =
      SteamClient.URL.ExecuteSteamURL.bind(SteamClient.URL);
    SteamClient.URL.ExecuteSteamURL = function (url) {
      if (/^steam:\/\/uninstall\//i.test(String(url || ""))) cancelAll();
      return nativeExecuteSteamURL.apply(null, arguments);
    };
  }

  SteamClient.Apps.RunGame = function () {
    const args = Array.prototype.slice.call(arguments);
    const appid = appIdForGameId(args[0]);
    if (!isBlocking(blocking[appid])) return nativeRunGame.apply(null, args);

    const previous = deferred.get(appid);
    if (previous) clearTimeout(previous.timer);
    const pending = { args: args, timer: null };
    pending.timer = setTimeout(function () {
      if (cancel(appid)) notify("__lumenAutoFixLaunchTimeout", appid);
    }, 120000);
    deferred.set(appid, pending);
    notify("__lumenAutoFixLaunchWait", appid);
    return undefined;
  };

  window.__lumenReleaseAutoFixLaunch = function (appid) {
    release(String(appid));
  };

  window.__lumenCancelAutoFixLaunch = function (appid) {
    cancel(String(appid));
  };

  window.__lumenUpdateAutoFixGuard = function (next) {
    blocking = next && typeof next === "object"
      ? Object.assign(Object.create(null), next)
      : Object.create(null);
    Array.from(deferred.keys()).forEach(function (appid) {
      const state = blocking[appid];
      if (state && state.cancel === true) cancel(appid);
      else if (!isBlocking(state)) release(appid);
    });
  };
})();
