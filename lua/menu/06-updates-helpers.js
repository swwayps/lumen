// LM-FRAGMENT Game Updates helpers (icons, build timeline, verRow, validate prompt)
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.


  // Moon icon (SVG, currentColor) used for the slsteam-moon tab.
  var MOON_SVG = '<svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="6" fill="currentColor"/></svg>';
  // Download/version icon for the Game Updates tab.
  var GU_SVG = '<svg viewBox="0 0 16 16" width="16" height="16"><path fill="currentColor" d="M8 1a1 1 0 0 1 1 1v6.6l2-2 1.4 1.4L8 12.4 3.6 8 5 6.6l2 2V2a1 1 0 0 1 1-1zM3 13h10v2H3z"/></svg>';
  // Info icon for the About tab.
  var ABOUT_SVG = '<svg viewBox="0 0 16 16" width="16" height="16"><path fill="currentColor" d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zM7 4h2v2H7V4zm0 3h2v5H7V7z"/></svg>';

  // ── Game Updates helpers ────────────────────────────────────────────────
  var _nameCache = {};
  function capsuleUrl(appid) {
    return "https://cdn.cloudflare.steamstatic.com/steam/apps/" + appid + "/header.jpg";
  }
  // Resolve an app name via the same Steam store API luatools.js uses. Cached;
  // resolves to null on any failure (caller falls back to the appid).
  function fetchAppName(appid) {
    if (_nameCache[appid]) return Promise.resolve(_nameCache[appid]);
    try {
      return fetch("https://store.steampowered.com/api/appdetails?appids=" + appid + "&filters=basic")
        .then(function (r) { return r.json(); })
        .then(function (j) {
          var d = j && j[appid] && j[appid].success && j[appid].data;
          var name = d && d.name ? d.name : null;
          if (name) _nameCache[appid] = name;
          return name;
        })
        .catch(function () { return null; });
    } catch (e) { return Promise.resolve(null); }
  }
  // Unix seconds -> dd/mm/yyyy (UTC). 0/missing -> em dash.
  function fmtDate(unix) {
    if (!unix) return "\u2014";
    var d = new Date(unix * 1000);
    var p = function (n) { return (n < 10 ? "0" : "") + n; };
    return p(d.getUTCDate()) + "/" + p(d.getUTCMonth() + 1) + "/" + d.getUTCFullYear();
  }

  // The "base" depot whose timeline represents the game's builds. Picking the
  // right one is heuristic (no clean on-disk signal for "main content depot"):
  //   1) ignore "stub" depots whose biggest manifest is tiny vs the game's
  //      largest depot (<5%) — e.g. Wallpaper Engine's appid-depot 431960 is a
  //      ~15 KB launcher while the real content (431961) is ~867 KB.
  //   2) among the rest, prefer the appid-depot if it survived (it's the base
  //      game for most titles, e.g. BoI 250900); else the depot with the most
  //      archived versions (the actively-updated content), tie-break lowest id.
  function depotMaxSize(d) {
    var m = 0;
    (d.versions || []).forEach(function (v) { if ((v.size || 0) > m) m = v.size; });
    return m;
  }
  function baseDepot(game) {
    var all = game.depots || [];
    if (all.length === 0) return null;
    // 1) Workshop content (depot id == appid) holds workshop snapshots, not game
    //    builds. The backend flags it; never use it for the game's timeline.
    var depots = all.filter(function (d) { return !d.workshop; });
    if (depots.length === 0) return null;
    // 2) Prefer depots actually installed (real game content on disk). Fall back
    //    to every non-workshop depot when nothing is installed yet (e.g. added
    //    via LuaTools but not downloaded).
    var inst = depots.filter(function (d) { return d.installed; });
    var pool = inst.length > 0 ? inst : depots;
    // 3) Drop stub depots (tiny launcher depots) by manifest size.
    var largest = 0;
    pool.forEach(function (d) { var s = depotMaxSize(d); if (s > largest) largest = s; });
    var threshold = largest / 20;  // 5%
    var cands = pool.filter(function (d) { return depotMaxSize(d) >= threshold; });
    if (cands.length === 0) cands = pool;
    // 4) Prefer the depot whose id == appid (only reachable here when it's real
    //    content, not workshop), else the one with the most archived versions
    //    (ties -> lowest id).
    for (var i = 0; i < cands.length; i++) {
      if (cands[i].depot === game.appid) return cands[i];
    }
    var best = null;
    cands.forEach(function (d) {
      var dn = (d.versions || []).length, bn = best ? (best.versions || []).length : -1;
      if (!best || dn > bn || (dn === bn && d.depot < best.depot)) best = d;
    });
    return best;
  }

  // The game's selectable build timeline, taken from its BASE depot only and
  // collapsed to one row per calendar day (a day can hold several manifests),
  // newest first. Mixing every depot here produced duplicate-looking dates and
  // surfaced ancient DLC-only dates that aren't real game builds.
  function gameBuilds(game) {
    var bd = baseDepot(game);
    if (!bd) return [];
    var byDay = {};
    (bd.versions || []).forEach(function (v) {
      var k = fmtDate(v.date);
      var e = byDay[k] || { date: v.date, fromLua: false, installed: false, pinned: false };
      if (v.date > e.date) e.date = v.date;
      if (v.fromLuaTools) e.fromLua = true;
      if (v.installed) e.installed = true;
      if (v.pinned) e.pinned = true;
      byDay[k] = e;
    });
    var arr = [];
    Object.keys(byDay).forEach(function (k) { arr.push(byDay[k]); });
    arr.sort(function (a, b) { return b.date - a.date; });
    return arr;
  }

  // Mark the "from LuaTools" build in the main list, combining two signals:
  //   1) LOGICAL (precise): gameBuilds already flags a build whose gid matches
  //      the base depot's setManifestid in the .lua — that IS the LuaTools
  //      build. If present, keep it.
  //   2) EMPIRICAL (fallback): most base depots have no setManifestid, so we
  //      can't know the literal build. slsteam-moon only archives a depot AFTER
  //      the LuaTools install, so the OLDEST archived build (bottom row) is the
  //      one present at install. Mark that.
  function markLuaToolsBuild(builds) {
    if (builds.length === 0) return;
    if (builds.some(function (b) { return b.fromLua; })) return;  // literal pin
    builds[builds.length - 1].fromLua = true;  // oldest (list is newest-first)
  }

  // A small selectable version row (radio dot + label + optional badges).
  function verRow(opts) {
    var row = document.createElement("div");
    row.className = "lumen-ver" + (opts.selected ? " sel" : "");
    var dot = document.createElement("span");
    dot.className = "dot";
    row.appendChild(dot);
    var lbl = document.createElement("span");
    lbl.textContent = opts.label;
    row.appendChild(lbl);
    if (opts.gid) {
      var g = document.createElement("span");
      g.className = "vgid";
      g.textContent = opts.gid;
      row.appendChild(g);
    }
    (opts.badges || []).forEach(function (b) {
      var s = document.createElement("span");
      s.className = "lumen-badge " + b.cls;
      s.textContent = b.text;
      row.appendChild(s);
    });
    row.addEventListener("click", opts.onClick);
    return row;
  }

  // Confirm modal shown after a build is pinned: applying a pin only takes
  // effect once Steam re-verifies the game's files, so offer to kick that off
  // now. Declining is fine — the user can validate later from the game's
  // properties. The validate is relayed into SharedJSContext (SteamClient),
  // see injector State:validate_app.
  function showValidatePrompt(appid) {
    var GU = I18N.en.gu;
    injectStyles();
    var back = document.createElement("div");
    back.className = "lumen-modal-back";
    var card = document.createElement("div");
    card.className = "lumen-modal";
    var t = document.createElement("div");
    t.className = "mt";
    t.textContent = GU.validateTitle;
    var b = document.createElement("div");
    b.className = "mb";
    b.textContent = GU.validateBody;
    var row = document.createElement("div");
    row.className = "mrow";
    var close = function () { if (back.parentNode) back.remove(); };
    var decline = document.createElement("button");
    decline.className = "lumen-mbtn";
    decline.textContent = GU.validateDecline;
    decline.addEventListener("click", function (e) { e.stopPropagation(); close(); });
    var confirm = document.createElement("button");
    confirm.className = "lumen-mbtn primary";
    confirm.textContent = GU.validateConfirm;
    confirm.addEventListener("click", function (e) {
      e.stopPropagation();
      call("__lumenValidateApp", { appid: appid }).catch(function (err) { log("validate", err); });
      close();
    });
    // Clicking the backdrop dismisses (same as declining).
    back.addEventListener("click", function (e) { if (e.target === back) close(); });
    row.appendChild(decline); row.appendChild(confirm);
    card.appendChild(t); card.appendChild(b); card.appendChild(row);
    back.appendChild(card);
    (document.body || document.documentElement).appendChild(back);
  }

  // Generic confirm/acknowledge modal, same visual as showValidatePrompt.
  // opts: { title, body, confirmText, declineText, onConfirm }. With no
  // declineText only the primary button shows (an acknowledgement dialog).
  // onConfirm runs after the primary button closes the modal; the backdrop and
  // the decline button just dismiss.
  function showConfirm(opts) {
    opts = opts || {};
    injectStyles();
    var back = document.createElement("div");
    back.className = "lumen-modal-back";
    var card = document.createElement("div");
    card.className = "lumen-modal";
    var t = document.createElement("div");
    t.className = "mt";
    t.textContent = opts.title || "";
    var b = document.createElement("div");
    b.className = "mb";
    b.textContent = opts.body || "";
    var row = document.createElement("div");
    row.className = "mrow";
    var close = function () { if (back.parentNode) back.remove(); };
    if (opts.declineText) {
      var decline = document.createElement("button");
      decline.className = "lumen-mbtn";
      decline.textContent = opts.declineText;
      decline.addEventListener("click", function (e) { e.stopPropagation(); close(); });
      row.appendChild(decline);
    }
    var confirm = document.createElement("button");
    confirm.className = "lumen-mbtn primary";
    confirm.textContent = opts.confirmText || "OK";
    confirm.addEventListener("click", function (e) {
      e.stopPropagation();
      close();
      if (typeof opts.onConfirm === "function") opts.onConfirm();
    });
    back.addEventListener("click", function (e) { if (e.target === back) close(); });
    row.appendChild(confirm);
    card.appendChild(t); card.appendChild(b); card.appendChild(row);
    back.appendChild(card);
    (document.body || document.documentElement).appendChild(back);
  }

  // Non-dismissable progress modal for a multi-step action (source fetch). Returns
  // { update(msg), close() }. Same visual as the other modals, no buttons.
  function showProgress(title) {
    injectStyles();
    var back = document.createElement("div");
    back.className = "lumen-modal-back";
    var card = document.createElement("div");
    card.className = "lumen-modal";
    var t = document.createElement("div");
    t.className = "mt";
    t.textContent = title || "";
    var b = document.createElement("div");
    b.className = "mb";
    b.textContent = "";
    card.appendChild(t);
    card.appendChild(b);
    back.appendChild(card);
    (document.body || document.documentElement).appendChild(back);
    return {
      update: function (msg) { b.textContent = msg || ""; },
      close: function () { if (back.parentNode) back.remove(); },
    };
  }

  // Prompt shown when a build is pinned for an ALREADY-INSTALLED game. A verify
  // can't switch the installed build to the pin (Steam computes a zero delta and
  // keeps the current files), so the only reliable way is to uninstall and
  // reinstall fresh. Offers Steam's own uninstall flow; the pin is already
  // saved, so a later reinstall comes down at the pinned build. Relayed into
  // SharedJSContext via injector __lumenUninstallApp.
  function showUninstallPrompt(appid) {
    var GU = I18N.en.gu;
    injectStyles();
    var back = document.createElement("div");
    back.className = "lumen-modal-back";
    var card = document.createElement("div");
    card.className = "lumen-modal";
    var t = document.createElement("div");
    t.className = "mt";
    t.textContent = GU.uninstallTitle;
    var b = document.createElement("div");
    b.className = "mb";
    b.textContent = GU.uninstallBody;
    var row = document.createElement("div");
    row.className = "mrow";
    var close = function () { if (back.parentNode) back.remove(); };
    var decline = document.createElement("button");
    decline.className = "lumen-mbtn";
    decline.textContent = GU.uninstallDecline;
    decline.addEventListener("click", function (e) { e.stopPropagation(); close(); });
    var confirm = document.createElement("button");
    confirm.className = "lumen-mbtn primary";
    confirm.textContent = GU.uninstallConfirm;
    confirm.addEventListener("click", function (e) {
      e.stopPropagation();
      call("__lumenUninstallApp", { appid: appid }).catch(function (err) { log("uninstall", err); });
      close();
      // The pin only lands on a fresh reinstall AND needs Steam to re-read the
      // pinned appinfo at startup, so guide the user to restart after the
      // uninstall, then reinstall. RestartSteam is the plugin's own RPC.
      showConfirm({
        title: GU.uninstallRestartTitle, body: GU.uninstallRestartBody,
        confirmText: GU.restartNow, declineText: GU.restartLater,
        onConfirm: function () {
          call("RestartSteam", {}).catch(function (err) { log("RestartSteam", err); });
        },
      });
    });
    back.addEventListener("click", function (e) { if (e.target === back) close(); });
    row.appendChild(decline); row.appendChild(confirm);
    card.appendChild(t); card.appendChild(b); card.appendChild(row);
    back.appendChild(card);
    (document.body || document.documentElement).appendChild(back);
  }

  // A game counts as installed if any of its depots has a current on-disk gid
  // (its appmanifest is present). Used to skip the validate prompt for a
  // not-installed game: pinning a build you haven't downloaded has nothing to
  // verify, so we just store the pin and let the normal install pick it up.
  function isGameInstalled(game) {
    if (!game || !game.depots) return false;
    return game.depots.some(function (d) { return !!d.installed; });
  }

  // Label a depot row: shared Steam runtimes (flagged by the backend) get a
  // friendly name + id so their old manifest dates don't read as game builds;
  // everything else is just "Depot <id>".
  function depotLabel(d) {
    if (d.shared) return I18N.en.gu.sharedRuntime + " (" + d.depot + ")";
    return I18N.en.gu.depot + " " + d.depot;
  }

