// LM-FRAGMENT Game Updates helpers (icons, build timeline, verRow, validate prompt)
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.


  // Moon icon (SVG, currentColor) used for the slsteam-moon tab.
  var MOON_SVG = '<svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="6" fill="currentColor"/></svg>';
  // Download/version icon for the Game Updates tab.
  var GU_SVG = '<svg viewBox="0 0 16 16" width="16" height="16"><path fill="currentColor" d="M8 1a1 1 0 0 1 1 1v6.6l2-2 1.4 1.4L8 12.4 3.6 8 5 6.6l2 2V2a1 1 0 0 1 1-1zM3 13h10v2H3z"/></svg>';
  // Info icon for the About tab.
  var ABOUT_SVG = '<svg viewBox="0 0 16 16" width="16" height="16"><path fill="currentColor" d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zM7 4h2v2H7V4zm0 3h2v5H7V7z"/></svg>';
  // Cloud icon for the Cloud Saves tab.
  var CLOUD_SVG = '<svg viewBox="0 0 16 16" width="16" height="16"><path fill="currentColor" d="M12.2 6.5A4 4 0 0 0 4.5 6 3 3 0 0 0 4 12h8a2.75 2.75 0 0 0 .2-5.5z"/></svg>';

  // ── Game Updates helpers ────────────────────────────────────────────────
  // appid -> Promise<{name, image}|null>. One store-API "basic" lookup per app,
  // shared by the name label and the capsule fallback (the in-flight promise is
  // cached so concurrent callers don't double-fetch).
  var _basicCache = {};
  function capsuleUrl(appid) {
    return "https://cdn.cloudflare.steamstatic.com/steam/apps/" + appid + "/header.jpg";
  }
  // Fetch the store's basic appdetails (name + header image), cached. Resolves
  // to null on any failure. Same API luatools.js uses.
  function fetchAppBasic(appid) {
    if (_basicCache[appid]) return _basicCache[appid];
    var p;
    try {
      p = fetch("https://store.steampowered.com/api/appdetails?appids=" + appid + "&filters=basic")
        .then(function (r) { return r.json(); })
        .then(function (j) {
          var d = j && j[appid] && j[appid].success && j[appid].data;
          if (!d) return null;
          return { name: d.name || null, image: d.header_image || d.capsule_image || null };
        })
        .catch(function () { return null; });
    } catch (e) { p = Promise.resolve(null); }
    _basicCache[appid] = p;
    return p;
  }
  // Resolve an app name; null on failure (caller falls back to the appid).
  function fetchAppName(appid) {
    return fetchAppBasic(appid).then(function (b) { return b && b.name ? b.name : null; });
  }
  // Load a game's capsule into `img`. Newer/unreleased titles don't have the
  // legacy static /steam/apps/<id>/header.jpg (it 404s), so on error fall back
  // to the store's own header_image (served from a different CDN path); hide the
  // image only if that fails too.
  function loadCapsule(appid, img) {
    var fellBack = false;
    img.addEventListener("error", function () {
      if (fellBack) { img.style.visibility = "hidden"; return; }
      fellBack = true;
      fetchAppBasic(appid).then(function (b) {
        if (b && b.image) img.src = b.image;
        else img.style.visibility = "hidden";
      });
    });
    img.src = capsuleUrl(appid);
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
    // Product metadata is authoritative. The backend selects one real base
    // content depot and excludes DLC/shared/platform siblings from the main
    // release history. Keep the heuristic below only for older or cache-less
    // installs that do not expose historyDepot yet.
    if (game.historyDepot) {
      for (var h = 0; h < all.length; h++) {
        if (all[h].depot === game.historyDepot) return all[h];
      }
    }
    // Metadata was available but no archived base depot matched it. Returning
    // an empty timeline is safer than promoting a DLC or shared component to a
    // game build. The heuristic remains only for legacy/cache-less installs.
    if (game.metadataAvailable) return null;
    // 1) Workshop content (depot id == appid) holds workshop snapshots, not game
    //    builds. The backend flags it; never use it for the game's timeline.
    var nonWs = all.filter(function (d) { return !d.workshop; });
    if (nonWs.length === 0) return null;
    // 1b) Shared runtime depots (Steamworks Common Redistributables) carry
    //     ancient fixed dates that aren't game builds, so using one as the base
    //     shows a bogus build (e.g. 18/02/2013). Prefer real content depots; fall
    //     back to the shared ones only if that's all there is, so the timeline is
    //     never empty.
    var depots = nonWs.filter(function (d) { return !d.shared; });
    if (depots.length === 0) depots = nonWs;
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
    if (opts.disabled) {
      row.classList.add("disabled");
    }
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
    if (opts.disabled) {
      var GU = guStrings();
      var badge = document.createElement("span");
      badge.style.cursor = "pointer";
      var title, body;
      if (opts.synthetic) {
        badge.className = "lumen-badge synth";
        badge.textContent = GU.syntheticBadge;
        title = GU.syntheticTitle;
        body = GU.syntheticBody;
      } else {
        badge.className = "lumen-badge err";
        badge.textContent = GU.offlineBadge;
        title = GU.offlineTitle;
        body = GU.offlineBody;
      }
      badge.title = body;

      var infoSpan = document.createElement("span");
      infoSpan.className = "info";
      infoSpan.textContent = "i";
      badge.appendChild(infoSpan);

      row.appendChild(badge);

      var showWarn = function (e) {
        e.stopPropagation();
        showConfirm({
          title: title,
          body: body,
          confirmText: GU.ok
        });
      };
      badge.addEventListener("click", showWarn);
    } else {
      row.addEventListener("click", opts.onClick);
    }
    return row;
  }

  // Confirm modal shown after a build is pinned: applying a pin only takes
  // effect once Steam re-verifies the game's files, so offer to kick that off
  // now. Declining is fine — the user can validate later from the game's
  // properties. The validate is relayed into SharedJSContext (SteamClient),
  // see injector State:validate_app.
  function showValidatePrompt(appid) {
    var GU = guStrings();
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

  // Save a build selection first, then offer validation only when switching an
  // installed game to a different build. If saving fails, keep the current UI
  // and do not offer an action that would validate the wrong selection.
  function applyPinForInstalledGame(appid, applyPin, shouldValidate) {
    return Promise.resolve(applyPin ? applyPin() : null)
      .then(function () {
        if (shouldValidate) showValidatePrompt(appid);
      })
      .catch(function (err) { log("apply-pin", err); });
  }

  // Pinning a build for a NOT-installed game now takes effect LIVE: slsteam-moon
  // applies the pin in memory (the EvaluateConfigChanges reconcile hook reads
  // the ManifestPins config on the fly), downstream of Steam's in-session
  // appinfo refresh, so no restart is needed. Just write the pin (and move the
  // selection); installing from the library then comes down at the pinned
  // build. NOTE: this assumes the game was already added in a previous session
  // (it's in this list, so it has a stplug .lua and was provisioned at the last
  // boot). A game added THIS session still needs a restart before its first
  // install (separate add-without-restart limitation) — that path keeps its own
  // restart prompt in runImport.
  function showPinRestartPrompt(applyPin) {
    Promise.resolve(applyPin ? applyPin() : null)
      .catch(function (err) { log("apply-pin", err); });
  }

  // A game counts as installed if any of its depots has a current on-disk gid
  // (its appmanifest is present). Used to skip the validate prompt for a
  // not-installed game: pinning a build you haven't downloaded has nothing to
  // verify, so we just store the pin and let the normal install pick it up.
  function isGameInstalled(game) {
    if (!game || !game.depots) return false;
    return game.depots.some(function (d) { return !!d.installed; });
  }

  // Label a depot row from provisioned appinfo metadata. Known Steam tools keep
  // their specific names; base content carries the game/platform; DLC names are
  // resolved from their associated AppID by the renderer. DepotID stays on its
  // own secondary line so every row remains unambiguous.
  function depotLabel(d, game) {
    if (d.name) return d.name;
    if (d.shared) return guStrings().sharedRuntime;
    var GU = guStrings();
    var label = d.kind === "dlc" ? GU.dlcContent
      : (d.kind === "base" ? ((game && game.name ? game.name + " — " : "") + GU.baseContent)
        : GU.depot);
    var platform = depotPlatformLabel(d.oslist);
    var language = d.language ? d.language : "";
    if (platform) label += " — " + platform;
    if (language) label += " — " + language;
    return label;
  }

  function depotPlatformLabel(oslist) {
    var GU = guStrings();
    var names = { windows: GU.windowsContent, linux: GU.linuxContent, macos: GU.macosContent };
    var values = String(oslist || "").split(",").filter(Boolean);
    return values.map(function (value) { return names[value] || value; }).join(" / ");
  }
