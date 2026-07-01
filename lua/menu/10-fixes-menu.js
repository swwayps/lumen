// LM-FRAGMENT library-page "Fixes Menu" — entry next to the game's gear + a
// fixes window in the Lumen / Steam-library visual language.
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.
//
// Placement: a "Fixes Menu" entry is anchored immediately LEFT of the gear
// (Manage) button on a game's library details page. The library renders in the
// main client shell ("Steam" window target), where this bundle runs.
//
// Look: a compact dark window on the Lumen surface (#23262d) topped by the
// game's own library_hero banner (as Steam's own detail pages do), then a 2x2
// grid of flat fix tiles (icon + label + description). Steam-flat execution —
// muted icons, 1px borders, a single #1a9fff accent on hover, no drop-glow,
// no blur, no transform bounce. Alerts/confirms reuse the Lumen modal styles.
//
// Robustness (validated live on the Zorin VM):
//   * appid  — read from the focused game's hero/logo asset URL
//              (steamloopback.host/assets/<appid>/<hash>/library_hero.jpg |
//              logo.png), which appears exactly once on a details page. Steam's
//              CSS class names are hashed, so this asset-URL signal is the
//              stable, locale-independent appid source.
//   * gear   — the leftmost small [role=button] holding a direct <svg> on the
//              right of the action row that is actually VISIBLE (Steam keeps a
//              hidden duplicate action bar; checkVisibility() picks the live one).
//   * native — see fixesmenu.lua (LumenFixesContext.runsUnderProton): a Windows
//              fix only loads under Proton, and slsteam-moon's Proton injection
//              pollutes every client OS signal, so the backend decides from the
//              install dir (*.exe) + forced compat tool.
//
// Performance: NO document.body subtree observer and NO heavy periodic scan. A
// light ~1.5s tick does a single getElementById; only when the entry is absent
// AND a one-selector "are we on a details page?" probe matches does it run the
// (small) gear scan.

  var FX_BTN_ID = "lumen-fixes-btn";
  var FX_SPACER_ID = "lumen-fixes-spacer";
  var FX_OVERLAY_ID = "lumen-fixes-overlay";
  var FX_STYLE_ID = "lumen-fixes-styles";

  // The icon cluster we tightened (see ensureFixesButton): keep a handle + its
  // original left margin so removing the entry restores Steam's spacing.
  var _fxCluster = null, _fxClusterOrigMl = null;

  // The set of LuaTools-added appids ({appid: true}); null until first fetched.
  // The entry is only shown for games in this set (fetched from LumenAddedApps).
  var fxAddedApps = null;

  // Whether the library-page entry is shown (toggled in Lumen settings ->
  // Plugin). Default ON; the stored pref is fetched below and updates this.
  if (typeof window.__lumenFixesMenuEnabled === "undefined") {
    window.__lumenFixesMenuEnabled = true;
  }

  // Inline icons (currentColor) — FontAwesome isn't loaded in the shell context.
  var FX_ICONS = {
    wrench: '<svg viewBox="0 0 512 512" width="100%" height="100%" fill="currentColor"><path d="M507 109a13 13 0 00-22-6l-74 74-59-10-10-59 74-74a13 13 0 00-6-22 128 128 0 00-164 152L19 359a64 64 0 0090 90l195-195A128 128 0 00507 109z"/></svg>',
    globe: '<svg viewBox="0 0 496 512" width="100%" height="100%" fill="currentColor"><path d="M248 8a248 248 0 100 496 248 248 0 000-496zm164 158h-65a312 312 0 00-28-78 193 193 0 0193 78zM248 56c19 0 45 35 56 96H192c11-61 37-96 56-96zM72 248a190 190 0 014-40h74a445 445 0 000 80H76a190 190 0 01-4-40zm32 98h65a312 312 0 0028 78 193 193 0 01-93-78zm65-180h-65a193 193 0 0193-78 312 312 0 00-28 78zm79 290c-19 0-45-35-56-96h112c-11 61-37 96-56 96zm66-144H183a401 401 0 010-80h130a401 401 0 010 80zm9 132a312 312 0 0028-78h65a193 193 0 01-93 78zm37-126a445 445 0 000-80h74a193 193 0 010 80z"/></svg>',
    layers: '<svg viewBox="0 0 576 512" width="100%" height="100%" fill="currentColor"><path d="M288 0L11 124a12 12 0 000 22l277 124 277-124a12 12 0 000-22zm224 220l-53-24-171 76L117 196l-53 24a12 12 0 000 22l224 100 224-100a12 12 0 000-22zm0 124l-53-24-171 76L117 320l-53 24a12 12 0 000 22l224 100 224-100a12 12 0 000-22z"/></svg>',
    trash: '<svg viewBox="0 0 448 512" width="100%" height="100%" fill="currentColor"><path d="M135 21l-13 27H32a16 16 0 000 32h384a16 16 0 000-32h-90l-13-27A32 32 0 00284 0H164a32 32 0 00-29 21zM416 128H32l21 339a48 48 0 0048 45h246a48 48 0 0048-45z"/></svg>',
  };

  // ── PURE helpers (window-exposed for tools/test_fixes_menu.js) ──────────────

  // Pull the focused game's appid from a list of <img> src strings. The details
  // page has exactly one library_hero.jpg and one logo.png under the focused
  // game's /assets/<appid>/ path; the surrounding shelves use header.jpg (other
  // appids), so prefer the hero, then the logo. Returns a number or null.
  function fixesAppIdFromImgs(srcs) {
    if (!srcs || !srcs.length) return null;
    var rank = function (s) {
      if (/\/library_hero\.jpg/.test(s)) return 3;
      if (/\/logo\.png/.test(s)) return 2;
      if (/\/library_capsule/.test(s)) return 1;
      return 0;
    };
    var best = null, bestRank = 0;
    for (var i = 0; i < srcs.length; i++) {
      var s = String(srcs[i] || "");
      var r = rank(s);
      if (r <= bestRank) continue;
      var m = s.match(/\/assets\/(\d+)\//);
      if (m) { best = parseInt(m[1], 10); bestRank = r; }
    }
    return best;
  }

  // Choose the gear from action-row icon-button candidates. Each candidate is
  // { el, x }. The gear is the LEFTMOST of the top-right icon cluster
  // (gear, info, heart shown left to right), so the smallest x wins.
  function fixesPickGear(cands) {
    if (!cands || !cands.length) return null;
    var best = cands[0];
    for (var i = 1; i < cands.length; i++) {
      if (cands[i].x < best.x) best = cands[i];
    }
    return best;
  }

  // The banner game name. We only ever show a name we can trust: the installed
  // game's appmanifest name (ctx.gameName), or a real name from CheckForFixes.
  // When the title isn't installed we show NOTHING rather than an "Unknown
  // Game" placeholder (the not-installed note already explains the state).
  function fixesResolveName(ctx, fixes) {
    ctx = ctx || {};
    fixes = fixes || {};
    if (!ctx.isInstalled) return "";
    if (ctx.gameName) return ctx.gameName;
    var fn = fixes.gameName;
    if (fn && String(fn).indexOf("Unknown Game") !== 0) return fn;
    return "";
  }

  // Whether the entry should show for this game: only games added via LuaTools
  // (present in the fetched added-set). `added` is a map {appid: true} or null
  // while it's still loading (treated as "not yet known" -> hidden).
  function fixesAppAllowed(appid, added) {
    if (!appid || !added) return false;
    return added[appid] === true;
  }

  try {
    window.__lumenFixesAppIdFromImgs = fixesAppIdFromImgs;
    window.__lumenFixesPickGear = fixesPickGear;
    window.__lumenFixesResolveName = fixesResolveName;
    window.__lumenFixesAppAllowed = fixesAppAllowed;
  } catch (e) {}

  // ── styles (Lumen tokens: #23262d surface, #1a9fff accent, Motiva Sans) ─────
  function injectFixesStyles() {
    injectStyles(); // Lumen settings stylesheet (modal/spinner/etc.)
    if (document.getElementById(FX_STYLE_ID)) return;
    var s = document.createElement("style");
    s.id = FX_STYLE_ID;
    s.textContent = [
      // entry next to the gear — mirrors the menubar moon button's restraint
      "#" + FX_BTN_ID + "{display:inline-flex;align-items:center;gap:6px;cursor:pointer;",
      "position:relative;z-index:2;font:13px 'Motiva Sans',Arial,Helvetica,sans-serif;",
      "color:#dcdedf;padding:6px 10px;border-radius:3px;opacity:.9;white-space:nowrap;",
      "-webkit-app-region:no-drag;user-select:none;transition:.12s;}",
      "#" + FX_BTN_ID + ":hover{opacity:1;color:#fff;background:rgba(255,255,255,.08);}",
      "#" + FX_BTN_ID + " .ic{display:inline-flex;width:13px;height:13px;}",
      // overlay + window
      "#" + FX_OVERLAY_ID + "{position:fixed;inset:0;z-index:99998;display:flex;",
      "align-items:center;justify-content:center;background:rgba(0,0,0,.55);",
      "font-family:'Motiva Sans',Arial,Helvetica,sans-serif;}",
      ".lumen-fx-win{display:flex;flex-direction:column;width:580px;max-width:94vw;max-height:90vh;",
      "background:#23262d;border:1px solid rgba(0,0,0,.5);border-radius:4px;overflow:hidden;",
      "box-shadow:0 14px 44px rgba(0,0,0,.55);}",
      // banner (game library_hero) with a fade into the surface
      ".lumen-fx-banner{position:relative;flex:0 0 auto;height:126px;background:#1a1d23;",
      "background-size:cover;background-position:center 28%;}",
      ".lumen-fx-banner:after{content:'';position:absolute;inset:0;background:",
      "linear-gradient(180deg,rgba(20,22,27,.35) 0%,rgba(31,34,40,.25) 45%,#23262d 100%);}",
      ".lumen-fx-bar{position:absolute;top:0;left:0;right:0;z-index:2;display:flex;align-items:center;",
      "justify-content:space-between;padding:13px 16px;}",
      ".lumen-fx-ttl{font-size:13px;font-weight:700;letter-spacing:.4px;text-transform:uppercase;",
      "color:#cdd3da;text-shadow:0 1px 4px rgba(0,0,0,.8);}",
      ".lumen-fx-x{cursor:pointer;color:#fff;font-size:16px;line-height:1;opacity:.8;",
      "text-shadow:0 1px 4px rgba(0,0,0,.8);transition:.12s;}",
      ".lumen-fx-x:hover{opacity:1;}",
      ".lumen-fx-gname{position:absolute;left:16px;right:16px;bottom:12px;z-index:2;font-size:23px;",
      "font-weight:800;color:#fff;text-shadow:0 2px 8px rgba(0,0,0,.85);white-space:nowrap;",
      "overflow:hidden;text-overflow:ellipsis;}",
      // body + grid of tiles
      ".lumen-fx-body{flex:1 1 auto;overflow-y:auto;overscroll-behavior:contain;padding:16px 16px 18px;}",
      ".lumen-fx-sub{color:#8f98a0;font-size:12px;line-height:1.4;margin:0 2px 14px;}",
      ".lumen-fx-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;}",
      ".lumen-fx-tile{position:relative;display:flex;flex-direction:column;gap:8px;padding:15px 14px;",
      "border-radius:4px;cursor:pointer;background:rgba(255,255,255,.04);",
      "border:1px solid rgba(255,255,255,.08);transition:background .12s,border-color .12s;}",
      ".lumen-fx-tile .ic{width:22px;height:22px;color:#9aa3ab;transition:color .12s;}",
      ".lumen-fx-tile .tl{font-size:14px;font-weight:700;color:#fff;}",
      ".lumen-fx-tile .ds{font-size:11.5px;line-height:1.36;color:#8f98a0;}",
      ".lumen-fx-tile:hover{background:rgba(255,255,255,.07);border-color:#1a9fff;}",
      ".lumen-fx-tile:hover .ic{color:#fff;}",
      ".lumen-fx-tile.danger:hover{border-color:#ec5c5c;}",
      ".lumen-fx-tile.danger:hover .ic{color:#ec5c5c;}",
      ".lumen-fx-tile.off{opacity:.42;cursor:default;}",
      ".lumen-fx-tile.off:hover{background:rgba(255,255,255,.04);border-color:rgba(255,255,255,.08);}",
      ".lumen-fx-tile.off:hover .ic{color:#9aa3ab;}",
      ".lumen-fx-badge{position:absolute;top:11px;right:11px;font-size:9px;font-weight:700;",
      "text-transform:uppercase;letter-spacing:.5px;color:#8f98a0;background:rgba(255,255,255,.07);",
      "padding:2px 7px;border-radius:9px;}",
      ".lumen-fx-note{margin-top:14px;display:flex;gap:8px;align-items:flex-start;font-size:12px;",
      "line-height:1.45;color:#e0b341;}",
      // centred loading / status / progress
      ".lumen-fx-center{display:flex;flex-direction:column;align-items:center;gap:14px;",
      "padding:30px 0;color:#b8bcbf;font-size:14px;}",
      ".lumen-fx-status{padding:18px 2px 6px;}",
      ".lumen-fx-msg{font-size:14px;color:#dcdedf;line-height:1.5;margin-bottom:14px;}",
      ".lumen-fx-pbar{height:6px;border-radius:3px;background:#1a1d23;border:1px solid #3d4450;overflow:hidden;}",
      ".lumen-fx-pbar > i{display:block;height:100%;width:0;background:#1a9fff;transition:width .25s ease;}",
      ".lumen-fx-spin{display:inline-block;width:26px;height:26px;box-sizing:border-box;",
      "border:3px solid rgba(255,255,255,.16);border-top-color:#1a9fff;border-radius:50%;",
      "animation:lumen-rot .7s linear infinite;}",
      ".lumen-fx-foot{flex:0 0 auto;display:flex;justify-content:flex-end;padding:13px 16px;",
      "border-top:1px solid rgba(255,255,255,.06);}",
      ".lumen-fx-btn{cursor:pointer;font:600 13px 'Motiva Sans',Arial;color:#fff;background:#1a9fff;",
      "border:1px solid #1a9fff;border-radius:3px;padding:8px 18px;text-decoration:none;transition:.12s;}",
      ".lumen-fx-btn:hover{background:#3cb0ff;border-color:#3cb0ff;}",
      ".lumen-fx-lo{display:flex;gap:8px;margin-top:8px;}",
      ".lumen-fx-lo input{flex:1;min-width:0;background:#1a1d23;color:#dcdedf;font:12px monospace;",
      "border:1px solid #3d4450;border-radius:3px;padding:8px 10px;}",
    ].join("");
    (document.head || document.documentElement).appendChild(s);
  }

  // ── DOM glue ───────────────────────────────────────────────────────────────

  function fixesHeroSrc() {
    var img = document.querySelector('img[src*="library_hero"]');
    return img && img.src ? img.src : "";
  }

  // The focused game's appid from the page's hero/logo asset URLs.
  function currentFixesAppId() {
    var imgs = document.querySelectorAll("img");
    var srcs = [];
    for (var i = 0; i < imgs.length; i++) {
      var s = imgs[i].src || "";
      if (s.indexOf("/assets/") !== -1) srcs.push(s);
    }
    return fixesAppIdFromImgs(srcs);
  }

  // Real on-screen visibility. Steam renders MULTIPLE copies of the app-detail
  // action bar (a hidden/sticky one + the live one); only one is painted.
  function fixesVisible(el) {
    try {
      if (typeof el.checkVisibility === "function") {
        return el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
      }
    } catch (e) {}
    return !!el.offsetParent;
  }

  // Locate the gear (Manage) button on the live action row. Locale-independent.
  // The game-details action bar groups the gear with the favorite/info icons on
  // the SAME row (gear + at least one sibling), whereas other pages that also
  // show a hero + a lone top-right gear (notably the Downloads page while a
  // download is active) have a single icon there. So we only anchor when the
  // topmost visible icon cluster has >= 2 buttons, then take its leftmost (the
  // gear). This keeps the entry off the Downloads page.
  function findGearAnchor() {
    var iw = window.innerWidth || 1280;
    var nodes = document.querySelectorAll('[role="button"]');
    var cands = [];
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var r = el.getBoundingClientRect();
      if (!(r.width >= 18 && r.width <= 48 && r.height >= 18 && r.height <= 48)) continue;
      if (r.top < 40) continue;            // skip the menubar / window controls
      if (r.left < iw * 0.5) continue;     // right side of the window only
      if (!el.querySelector(":scope > svg")) continue;
      if (!fixesVisible(el)) continue;     // skip hidden duplicate action bars
      cands.push({ el: el, x: r.left, y: r.top });
    }
    if (!cands.length) return null;
    var y0 = Infinity;
    for (var j = 0; j < cands.length; j++) if (cands[j].y < y0) y0 = cands[j].y;
    var row = [];
    for (var k = 0; k < cands.length; k++) if (Math.abs(cands[k].y - y0) < 28) row.push(cands[k]);
    if (row.length < 2) return null;       // a lone top gear (Downloads page) is NOT the game action bar
    var pick = fixesPickGear(row);
    return pick ? pick.el : null;
  }

  function makeFixesButton() {
    var b = document.createElement("div");
    b.id = FX_BTN_ID;
    b.setAttribute("role", "button");
    b.setAttribute("tabindex", "0");
    b.title = fxStrings().title;
    b.innerHTML = '<span class="ic">' + FX_ICONS.wrench + "</span><span>" + fxStrings().button + "</span>";
    b.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      openFixesMenu();
    });
    return b;
  }

  // Insert the entry immediately LEFT of the gear. The gear/info/favorite icons
  // live in a FIXED-WIDTH, nowrap flex row (sized to exactly fit the three
  // icons) inside a wider action bar. Inserting our entry INTO that row makes
  // its flexbox shrink the sibling icons — the favorite heart worst of all
  // (its glyph collapsed to ~8px). So we anchor one level out: drop the entry
  // into the WIDE bar, right before the icon-cluster wrapper. The bar has a
  // flex-grow middle child, so the cluster stays flush-right. The gap between
  // the entry and the gear then equals the cluster wrapper's own margin-left
  // (its padding from the rest of the bar) — the entry's own margins can't
  // change it (the grow child absorbs them). So we match the icon rhythm by
  // tightening that margin-left to the native gear/info gap, remembering the
  // original so removeFixesButton() can restore it. Falls back to the in-row
  // placement if the ancestry isn't present.
  function ensureFixesButton(gear) {
    if (document.getElementById(FX_BTN_ID)) return true;
    if (!gear) return false;
    injectFixesStyles();
    var gearWrap = gear.parentElement;                  // wrapper of the gear button
    var iconRow = gearWrap && gearWrap.parentElement;   // fixed-width nowrap icon row
    var clusterWrap = iconRow && iconRow.parentElement; // wrapper pinned to the bar's right
    var bar = clusterWrap && clusterWrap.parentElement; // the wide action bar row
    var btn = makeFixesButton();
    if (bar && clusterWrap && bar.contains(clusterWrap)) {
      btn.style.alignSelf = "center";
      bar.insertBefore(btn, clusterWrap);
      try {
        // Match the entry->gear gap to the native gap between the icon buttons
        // by setting the cluster's left margin (the only lever that moves it).
        var sw = gearWrap.nextElementSibling;
        var infoBtn = sw && (sw.matches('[role="button"]') ? sw : sw.querySelector('[role="button"]'));
        if (infoBtn) {
          var nativeGap = infoBtn.getBoundingClientRect().left - gear.getBoundingClientRect().right;
          if (nativeGap > 0 && nativeGap < 40) {
            _fxCluster = clusterWrap;
            _fxClusterOrigMl = clusterWrap.style.marginLeft; // usually "" (comes from a class)
            clusterWrap.style.marginLeft = Math.round(nativeGap) + "px";
          }
        }
      } catch (e) {}
      return true;
    }
    // Fallback: original in-row placement left of the gear (may shrink icons).
    if (!gearWrap || !gearWrap.parentElement) return false;
    gearWrap.parentElement.insertBefore(btn, gearWrap);
    return true;
  }

  // Remove the entry and restore the icon cluster's original left margin.
  function removeFixesButton() {
    var b = document.getElementById(FX_BTN_ID); if (b) b.remove();
    var s = document.getElementById(FX_SPACER_ID); if (s) s.remove();
    if (_fxCluster) {
      try { _fxCluster.style.marginLeft = _fxClusterOrigMl || ""; } catch (e) {}
      _fxCluster = null; _fxClusterOrigMl = null;
    }
  }
  try { window.__lumenRemoveFixesButton = removeFixesButton; } catch (e) {}

  // Light keep-present tick (re-anchors if the entry ends up in a hidden copy).
  // Steady state is a single getElementById; the (small) gear scan only runs
  // when the entry is absent AND we're on a details page (one querySelector
  // guard). So a snappy ~350ms cadence stays cheap while making the entry
  // appear almost immediately on navigation (the old 800ms+1500ms felt laggy).
  var __fxHost = (typeof location !== "undefined" && location.hostname) || "";
  if (__fxHost !== "store.steampowered.com" && __fxHost !== "steamcommunity.com") {
    // Re-anchor check: O(1) when the entry is already present & visible; only
    // scans for the gear when it's missing (e.g. right after a game switch).
    var fxTick = function () {
      try {
        if (window.__lumenFixesMenuEnabled === false) { removeFixesButton(); return; }
        if (!document.querySelector('img[src*="library_hero"]')) { removeFixesButton(); return; }
        // Only for games added via LuaTools (present in the fetched added-set).
        if (!fixesAppAllowed(currentFixesAppId(), fxAddedApps)) { removeFixesButton(); return; }
        var existing = document.getElementById(FX_BTN_ID);
        if (existing && fixesVisible(existing)) return;   // present & visible -> keep
        if (existing) removeFixesButton();                // stale (its bar went hidden)
        var gear = findGearAnchor();
        if (gear) { ensureFixesButton(gear); }
      } catch (e) {}
    };

    // Steam mounts several game-detail panels at once (a carousel of prev /
    // current / next), each with its OWN action bar, and just swaps which is
    // visible on a game switch — so the newly-shown bar lacks our entry until
    // we re-anchor. A 350ms poll made that a visible flicker. A MutationObserver
    // re-anchors in the SAME frame as the swap (its callback runs before paint),
    // so the entry appears fixed in place. Work is coalesced to at most once per
    // animation frame and the steady-state check is O(1), so it stays cheap
    // despite the client's constant DOM churn.
    if (typeof MutationObserver === "function") {
      var fxRaf = (typeof window.requestAnimationFrame === "function")
        ? window.requestAnimationFrame.bind(window)
        : function (f) { return setTimeout(f, 16); };
      var fxPending = false;
      var fxObs = new MutationObserver(function () {
        if (fxPending) return;
        fxPending = true;
        fxRaf(function () { fxPending = false; fxTick(); });
      });
      try {
        fxObs.observe(document.body || document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
    }
    // Fallback poll (also does the very first anchor); slow, since the observer
    // handles the responsive path.
    if (typeof setInterval === "function") setInterval(fxTick, 1000);
    if (typeof setTimeout === "function") setTimeout(fxTick, 120);
  }

  // ── window + flows ───────────────────────────────────────────────────────────

  function fxParse(res) {
    try { return typeof res === "string" ? JSON.parse(res) : res; }
    catch (e) { return null; }
  }
  var _fxEsc = null;
  function fxClose() {
    var o = document.getElementById(FX_OVERLAY_ID);
    if (o) o.remove();
    if (_fxEsc) { document.removeEventListener("keydown", _fxEsc, true); _fxEsc = null; }
  }

  // Alert/confirm reuse the Lumen modal styles (03-styles).
  function fxAlert(msg) {
    injectStyles();
    var back = document.createElement("div");
    back.className = "lumen-modal-back";
    var m = document.createElement("div");
    m.className = "lumen-modal";
    m.innerHTML = '<div class="mt">' + fxStrings().title + '</div><div class="mb"></div>' +
      '<div class="mrow"><div class="lumen-mbtn primary" data-ok>OK</div></div>';
    m.querySelector(".mb").textContent = msg;
    back.appendChild(m);
    back.addEventListener("click", function (e) { if (e.target === back) back.remove(); });
    m.querySelector("[data-ok]").addEventListener("click", function () { back.remove(); });
    (document.body || document.documentElement).appendChild(back);
  }
  function fxConfirm(msg, onYes) {
    injectStyles();
    var S = fxStrings();
    var back = document.createElement("div");
    back.className = "lumen-modal-back";
    var m = document.createElement("div");
    m.className = "lumen-modal";
    m.innerHTML = '<div class="mt">' + S.unfixLabel + '</div><div class="mb"></div>' +
      '<div class="mrow"><div class="lumen-mbtn" data-no></div>' +
      '<div class="lumen-mbtn primary" data-yes></div></div>';
    m.querySelector(".mb").textContent = msg;
    m.querySelector("[data-no]").textContent = S.cancel;
    m.querySelector("[data-yes]").textContent = S.unfixLabel;
    back.appendChild(m);
    m.querySelector("[data-no]").addEventListener("click", function () { back.remove(); });
    m.querySelector("[data-yes]").addEventListener("click", function () { back.remove(); onYes(); });
    (document.body || document.documentElement).appendChild(back);
  }

  function openFixesMenu() {
    if (document.getElementById(FX_OVERLAY_ID)) return;
    var appid = currentFixesAppId();
    var S = fxStrings();
    if (!appid) { fxAlert(S.noAppId); return; }
    injectFixesStyles();

    var overlay = document.createElement("div");
    overlay.id = FX_OVERLAY_ID;
    overlay.addEventListener("click", function (e) { if (e.target === overlay) fxClose(); });

    var win = document.createElement("div");
    win.className = "lumen-fx-win";

    // banner: the game's own library_hero, title + close + game name overlaid.
    var banner = document.createElement("div");
    banner.className = "lumen-fx-banner";
    var hero = fixesHeroSrc();
    if (hero) banner.style.backgroundImage = "url('" + hero + "')";
    var bar = document.createElement("div");
    bar.className = "lumen-fx-bar";
    var ttl = document.createElement("div");
    ttl.className = "lumen-fx-ttl";
    ttl.textContent = S.title;
    var x = document.createElement("div");
    x.className = "lumen-fx-x";
    x.textContent = "\u2715";
    x.addEventListener("click", fxClose);
    bar.appendChild(ttl);
    bar.appendChild(x);
    var gname = document.createElement("div");
    gname.className = "lumen-fx-gname";
    banner.appendChild(bar);
    banner.appendChild(gname);

    var body = document.createElement("div");
    body.className = "lumen-fx-body";
    body.innerHTML = '<div class="lumen-fx-center"><div class="lumen-fx-spin"></div>' +
      "<div>" + S.loading + "</div></div>";

    win.appendChild(banner);
    win.appendChild(body);
    overlay.appendChild(win);
    (document.body || document.documentElement).appendChild(overlay);

    _fxEsc = function (e) { if (e.key === "Escape") fxClose(); };
    document.addEventListener("keydown", _fxEsc, true);

    Promise.all([
      call("LumenFixesContext", { appid: appid }).then(fxParse).catch(function () { return null; }),
      call("CheckForFixes", { appid: appid, contentScriptQuery: "" }).then(fxParse).catch(function () { return null; }),
    ]).then(function (r) {
      var ctx = r[0] || { isInstalled: false, installPath: "", gameName: "", runsUnderProton: false };
      var fixes = r[1] || {};
      var name = fixesResolveName(ctx, fixes);
      gname.textContent = name;
      fxRenderMenu(win, body, appid, ctx, fixes, name);
    });
  }

  // One fix tile. opts: { iconKey, off, danger, badge }.
  function fxTile(label, desc, opts, onClick) {
    var t = document.createElement("div");
    t.className = "lumen-fx-tile" + (opts.danger ? " danger" : "") + (opts.off ? " off" : "");
    var ic = document.createElement("div");
    ic.className = "ic";
    ic.innerHTML = FX_ICONS[opts.iconKey] || FX_ICONS.wrench;
    var tl = document.createElement("div");
    tl.className = "tl";
    tl.textContent = label;
    var ds = document.createElement("div");
    ds.className = "ds";
    ds.textContent = desc;
    if (opts.warn) ds.style.color = "#e0b341";   // amber caution (native-Linux)
    t.appendChild(ic);
    t.appendChild(tl);
    t.appendChild(ds);
    if (opts.badge) {
      var b = document.createElement("div");
      b.className = "lumen-fx-badge";
      b.textContent = opts.badge;
      t.appendChild(b);
    }
    t.addEventListener("click", function (e) {
      e.preventDefault();
      if (opts.off) return;
      onClick();
    });
    return t;
  }

  function fxRenderMenu(win, body, appid, ctx, fixes, gameName) {
    var S = fxStrings();
    var installed = !!ctx.isInstalled;
    var underProton = !!ctx.runsUnderProton;
    var crackStatus = (fixes.crackFix && fixes.crackFix.status) || 0;
    var crackUrl = fixes.crackFix && fixes.crackFix.url;
    var crackAvail = installed && crackStatus === 200;

    body.innerHTML = "";
    var sub = document.createElement("div");
    sub.className = "lumen-fx-sub";
    sub.textContent = S.intro;
    body.appendChild(sub);

    // A Windows fix only loads under Proton.
    var protonGate = function (proceed) {
      if (underProton) proceed(); else fxAlert(S.nativeWarn);
    };
    // Native Linux game (Steam runs it without Proton) -> a Windows crack/online
    // fix won't take effect. Surface that up front in the tile's description
    // (amber), where the normal blurb would be, for the actionable fixes.
    var isNative = installed && !underProton;

    var grid = document.createElement("div");
    grid.className = "lumen-fx-grid";

    // On a native-Linux game the Windows crack/online fix won't take effect, so
    // mark the tile UNAVAILABLE (dimmed + badge) with the amber reason in the
    // description — it becomes available once the user forces a Proton tool.
    var crackNative = crackAvail && isNative;
    var crackOff = !crackAvail || isNative;
    grid.appendChild(fxTile(S.crackLabel, crackNative ? S.nativeWarnShort : S.crackDesc,
      { iconKey: "wrench", off: crackOff, badge: crackOff ? S.unavailable : null, warn: crackNative },
      function () {
        if (!crackUrl) { fxAlert(S.crackNone); return; }
        protonGate(function () { fxApply(appid, crackUrl, S.crackLabel, ctx, win); });
      }));

    // Online Fix — availability is resolved UP FRONT from the perondepot mirror
    // (like Crack/Bypass), instead of only after a click. The tile shows a
    // brief "checking" state, then settles to enabled (a fix exists) or a
    // disabled UNAVAILABLE tile (none) — mirroring the crack tile. When found,
    // the resolved URL is applied directly on click (no second lookup).
    var onlineTile = fxTile(S.onlineLabel, S.onlineDesc,
      { iconKey: "globe", off: true, badge: installed ? S.checkingBadge : S.unavailable }, function () {});
    grid.appendChild(onlineTile);
    var replaceOnline = function (t2) {
      if (onlineTile.parentNode) onlineTile.parentNode.replaceChild(t2, onlineTile);
      onlineTile = t2;
    };
    if (installed) {
      call("ResolveOnlineFix", { appid: appid, gameName: gameName || "", contentScriptQuery: "" })
        .then(fxParse).then(function (p) {
          if (p && p.success && p.found && p.url) {
            var url = p.url;
            replaceOnline(fxTile(S.onlineLabel, isNative ? S.nativeWarnShort : S.onlineDesc,
              { iconKey: "globe", off: isNative, badge: isNative ? S.unavailable : null, warn: isNative },
              function () {
                protonGate(function () { fxApply(appid, url, S.onlineLabel, ctx, win); });
              }));
          } else {
            replaceOnline(fxTile(S.onlineLabel, S.onlineDesc,
              { iconKey: "globe", off: true, badge: S.unavailable }, function () {}));
          }
        })
        .catch(function () {
          replaceOnline(fxTile(S.onlineLabel, S.onlineDesc,
            { iconKey: "globe", off: true, badge: S.unavailable }, function () {}));
        });
    }

    grid.appendChild(fxTile(S.aioLabel, S.aioDesc,
      { iconKey: "layers", off: !installed }, function () {
        fxApplySpace(appid);
      }));

    grid.appendChild(fxTile(S.unfixLabel, S.unfixDesc,
      { iconKey: "trash", danger: true, off: !installed }, function () {
        fxConfirm(S.unfixConfirm, function () { fxUnfix(appid, ctx, win); });
      }));

    body.appendChild(grid);

    if (!installed) {
      var note = document.createElement("div");
      note.className = "lumen-fx-note";
      note.innerHTML = '<span>\u26A0</span><span></span>';
      note.lastChild.textContent = S.notInstalled;
      body.appendChild(note);
    }
  }

  // Transient busy overlay inside the window (keeps the tiles intact underneath).
  function fxBusy(win, msg) {
    var b = document.createElement("div");
    b.style.cssText = "position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;" +
      "justify-content:center;gap:14px;background:rgba(35,38,45,.9);z-index:5;color:#dcdedf;" +
      "font-size:14px;text-align:center;padding:24px;";
    b.innerHTML = '<div class="lumen-fx-spin"></div><div></div>';
    b.lastChild.textContent = msg;
    win.appendChild(b);
    return function () { try { b.remove(); } catch (e) {} };
  }

  // Replace the footer with a single Close button (end of a flow).
  function fxFooterClose(win) {
    var f = win.querySelector(".lumen-fx-foot");
    if (f) f.remove();
    f = document.createElement("div");
    f.className = "lumen-fx-foot";
    var c = document.createElement("a");
    c.href = "#";
    c.className = "lumen-fx-btn";
    c.textContent = fxStrings().close;
    c.addEventListener("click", function (e) { e.preventDefault(); fxClose(); });
    f.appendChild(c);
    win.appendChild(f);
  }

  // AIO / SpaceFix — FakeAppId 480, no download, no Proton gate.
  function fxApplySpace(appid) {
    var S = fxStrings();
    call("ApplySpaceFix", { appid: appid, contentScriptQuery: "" }).then(function (res) {
      var p = fxParse(res);
      if (p && p.success) { fxClose(); fxAlert(S.aioOk); }
      else { fxAlert((p && p.error) ? String(p.error) : S.applyErr); }
    }).catch(function () { fxAlert(S.applyErr); });
  }

  // Online Fix — resolve the .rar by game name on the mirror, then apply.
  // (Availability is now resolved up-front in fxRenderMenu; kept applying via
  // fxApply with the resolved URL.)

  // Crack / Online apply: start the background download, then poll status.
  function fxApply(appid, url, fixType, ctx, win) {
    var S = fxStrings();
    if (!ctx.installPath) { fxAlert(S.notInstalled); return; }
    call("ApplyGameFix", {
      appid: appid, downloadUrl: url, installPath: ctx.installPath,
      fixType: fixType, gameName: ctx.gameName || "", contentScriptQuery: "",
    }).then(function (res) {
      var p = fxParse(res);
      if (p && p.success) {
        fxShowProgress(win, fixType);
        fxPoll(appid, fixType, ctx, win);
      } else {
        fxAlert((p && p.error) ? String(p.error) : S.applyErr);
      }
    }).catch(function () { fxAlert(S.applyErr); });
  }

  function fxShowProgress(win, fixType) {
    var S = fxStrings();
    var body = win.querySelector(".lumen-fx-body");
    if (!body) return;
    body.innerHTML =
      '<div class="lumen-fx-status"><div class="lumen-fx-msg" id="lumen-fx-pmsg"></div>' +
      '<div class="lumen-fx-pbar"><i></i></div></div>';
    body.querySelector("#lumen-fx-pmsg").textContent = S.applying.replace("{fix}", fixType);
    var f = win.querySelector(".lumen-fx-foot");
    if (f) f.remove();
  }

  function fxPoll(appid, fixType, ctx, win) {
    var S = fxStrings();
    var poll = function () {
      if (!document.getElementById(FX_OVERLAY_ID)) return; // closed
      var msg = win.querySelector("#lumen-fx-pmsg");
      var bar = win.querySelector(".lumen-fx-pbar > i");
      call("GetApplyFixStatus", { appid: appid, contentScriptQuery: "" }).then(function (res) {
        var p = fxParse(res);
        if (!(p && p.success && p.state)) { setTimeout(poll, 600); return; }
        var st = p.state;
        if (st.status === "downloading") {
          var pct = (st.totalBytes > 0) ? Math.floor((st.bytesRead / st.totalBytes) * 100) : 0;
          if (msg) msg.textContent = S.downloading.replace("{percent}", pct);
          if (bar) bar.style.width = (pct || 4) + "%";
          setTimeout(poll, 600);
        } else if (st.status === "extracting") {
          if (msg) msg.textContent = S.extracting;
          if (bar) bar.style.width = "100%";
          setTimeout(poll, 600);
        } else if (st.status === "done") {
          if (msg) msg.textContent = S.appliedOk.replace("{fix}", fixType);
          if (bar) bar.style.width = "100%";
          fxApplyOverrides(appid, ctx, win);
          fxFooterClose(win);
        } else if (st.status === "failed") {
          if (msg) msg.textContent = S.failed.replace("{error}", st.error || S.unknownError);
          fxFooterClose(win);
        } else if (st.status === "cancelled") {
          if (msg) msg.textContent = S.failed.replace("{error}", st.error || S.cancel);
          fxFooterClose(win);
        } else {
          setTimeout(poll, 600);
        }
      }).catch(function () { setTimeout(poll, 800); });
    };
    setTimeout(poll, 600);
  }

  // After a Crack/Online fix: force its Windows DLLs to load under Proton via a
  // WINEDLLOVERRIDES launch option, set through the Lumen relay (SteamClient
  // lives in SharedJSContext). If the relay can't set it, show the line to paste.
  function fxApplyOverrides(appid, ctx, win) {
    call("GetFixLaunchOptions", {
      appid: appid, compatToolName: "", currentLaunchOptions: "",
      installPath: ctx.installPath || "", contentScriptQuery: "",
    }).then(function (res) {
      var p = fxParse(res);
      if (!(p && p.success && p.apply && p.launchOptions)) return;
      var opts = String(p.launchOptions);
      call("__lumenSetLaunchOptions", { appid: Number(appid), options: opts })
        .then(function (r) {
          var ok = false;
          try { ok = (typeof r === "string" ? JSON.parse(r) : r).ok; } catch (e) {}
          if (!ok) fxLaunchHint(win, opts);
        })
        .catch(function () { fxLaunchHint(win, opts); });
    }).catch(function () {});
  }

  // Fallback: render the launch-option line with a Copy button into the window.
  function fxLaunchHint(win, opts) {
    var S = fxStrings();
    var body = win.querySelector(".lumen-fx-body");
    if (!body || body.querySelector(".lumen-fx-lo")) return;
    var wrap = document.createElement("div");
    wrap.className = "lumen-fx-status";
    var msg = document.createElement("div");
    msg.className = "lumen-fx-msg";
    msg.style.fontWeight = "600";
    msg.textContent = S.launchHintTitle;
    var subEl = document.createElement("div");
    subEl.className = "lumen-fx-sub";
    subEl.style.margin = "6px 0 0";
    subEl.textContent = S.launchHintBody;
    var lo = document.createElement("div");
    lo.className = "lumen-fx-lo";
    var inp = document.createElement("input");
    inp.readOnly = true;
    inp.value = opts;
    inp.addEventListener("focus", function () { this.select(); });
    inp.addEventListener("click", function () { this.select(); });
    var copy = document.createElement("a");
    copy.href = "#";
    copy.className = "lumen-fx-btn";
    copy.textContent = S.launchHintCopy;
    copy.addEventListener("click", function (e) {
      e.preventDefault();
      try { inp.focus(); inp.select(); document.execCommand("copy"); } catch (x) {}
      try { if (navigator.clipboard) navigator.clipboard.writeText(opts); } catch (x) {}
      copy.textContent = S.launchHintCopied;
    });
    lo.appendChild(inp);
    lo.appendChild(copy);
    wrap.appendChild(msg);
    wrap.appendChild(subEl);
    wrap.appendChild(lo);
    body.appendChild(wrap);
  }

  // Unfix — drop the SpaceFix mapping + clear the fix launch option, then ask
  // Steam to verify files (restores anything a file-based fix changed).
  function fxUnfix(appid, ctx, win) {
    var S = fxStrings();
    var done = fxBusy(win, S.unfixDesc);
    call("UnFixGame", { appid: appid, installPath: ctx.installPath || "" })
      .then(function (res) {
        var p = fxParse(res);
        if (!(p && p.success)) {
          done();
          fxAlert((p && p.error) ? String(p.error) : S.unfixErr);
          return;
        }
        var after = function () {
          call("__lumenValidateApp", { appid: Number(appid) }).catch(function () {});
          done();
          fxClose();
          fxAlert(S.unfixDone);
        };
        if (p.clearLaunchOptions) {
          call("__lumenSetLaunchOptions", { appid: Number(appid), options: p.launchOptions || "" })
            .then(after).catch(after);
        } else {
          after();
        }
      })
      .catch(function () { done(); fxAlert(S.unfixErr); });
  }

  try { window.__lumenOpenFixesMenu = openFixesMenu; } catch (e) {}

  // Fetch the LuaTools-added appid set (the entry only shows for these games),
  // then refresh periodically so games added mid-session start showing it. Kept
  // as a map {appid: true}; fixesAppAllowed gates the anchor on it.
  function fxLoadAddedApps() {
    try {
      call("LumenAddedApps", {}).then(fxParse).then(function (p) {
        if (!(p && p.success)) return;
        var m = {};
        var a = p.appids;
        if (a && typeof a.length === "number") {
          for (var i = 0; i < a.length; i++) m[a[i]] = true;
        }
        fxAddedApps = m;
      }).catch(function () {});
    } catch (e) {}
  }
  fxLoadAddedApps();
  if (typeof setInterval === "function") setInterval(fxLoadAddedApps, 20000);

  // Load the stored "Fixes Menu enabled" pref (default ON). If disabled, the
  // tick removes the entry; if enabled, nothing changes.
  try {
    call("LumenGetPluginPrefs", {}).then(function (res) {
      var p = fxParse(res);
      if (p && p.success && p.prefs && p.prefs.fixes_menu_enabled === false) {
        window.__lumenFixesMenuEnabled = false;
      }
    }).catch(function () {});
  } catch (e) {}
