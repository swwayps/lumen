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
  var FX_FALLBACK_RECEIPT_KIND = "online_fix_fallback";

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

  // Inline brand/action icons (currentColor) — no icon font is loaded here.
  var FX_ICONS = {
    luatools: '<svg viewBox="0 0 24 24" width="100%" height="100%" shape-rendering="geometricPrecision" aria-hidden="true">' +
      '<defs><linearGradient id="lumen-lt-logo-gradient" x1="0" y1="0" x2="1" y2="1">' +
      '<stop offset="0" stop-color="#AC4EAD"/><stop offset=".48" stop-color="#9A249A"/>' +
      '<stop offset="1" stop-color="#670867"/></linearGradient>' +
      '<clipPath id="lumen-lt-logo-edge"><circle cx="12" cy="12" r="11.5"/></clipPath></defs>' +
      '<g clip-path="url(#lumen-lt-logo-edge)"><circle cx="12" cy="12" r="12" fill="#fff"/>' +
      '<g transform="rotate(90 12 12)"><path class="lumen-lt-logo-mono" fill="#090A0C" d="M11.979 0C5.678 0 .511 4.86.022 11.037l6.432 2.658c.545-.371 1.203-.59 1.912-.59.063 0 .125.004.188.006l2.861-4.142V8.91c0-2.495 2.028-4.524 4.524-4.524 2.494 0 4.524 2.031 4.524 4.527s-2.03 4.525-4.524 4.525h-.105l-4.076 2.911c0 .052.004.105.004.159 0 1.875-1.515 3.396-3.39 3.396-1.635 0-3.016-1.173-3.331-2.727L.436 15.27C1.862 20.307 6.486 24 11.979 24c6.627 0 11.999-5.373 11.999-12S18.605 0 11.979 0zM7.54 18.21l-1.473-.61c.262.543.714.999 1.314 1.25 1.297.539 2.793-.076 3.332-1.375.263-.63.264-1.319.005-1.949s-.75-1.121-1.377-1.383c-.624-.26-1.29-.249-1.878-.03l1.523.63c.956.4 1.409 1.5 1.009 2.455-.397.957-1.497 1.41-2.454 1.012H7.54zm11.415-9.303c0-1.662-1.353-3.015-3.015-3.015-1.665 0-3.015 1.353-3.015 3.015 0 1.665 1.35 3.015 3.015 3.015 1.663 0 3.015-1.35 3.015-3.015zm-5.273-.005c0-1.252 1.013-2.266 2.265-2.266 1.249 0 2.266 1.014 2.266 2.266 0 1.251-1.017 2.265-2.266 2.265-1.253 0-2.265-1.014-2.265-2.265z"/>' +
      '<path class="lumen-lt-logo-brand" fill="url(#lumen-lt-logo-gradient)" d="M11.979 0C5.678 0 .511 4.86.022 11.037l6.432 2.658c.545-.371 1.203-.59 1.912-.59.063 0 .125.004.188.006l2.861-4.142V8.91c0-2.495 2.028-4.524 4.524-4.524 2.494 0 4.524 2.031 4.524 4.527s-2.03 4.525-4.524 4.525h-.105l-4.076 2.911c0 .052.004.105.004.159 0 1.875-1.515 3.396-3.39 3.396-1.635 0-3.016-1.173-3.331-2.727L.436 15.27C1.862 20.307 6.486 24 11.979 24c6.627 0 11.999-5.373 11.999-12S18.605 0 11.979 0zM7.54 18.21l-1.473-.61c.262.543.714.999 1.314 1.25 1.297.539 2.793-.076 3.332-1.375.263-.63.264-1.319.005-1.949s-.75-1.121-1.377-1.383c-.624-.26-1.29-.249-1.878-.03l1.523.63c.956.4 1.409 1.5 1.009 2.455-.397.957-1.497 1.41-2.454 1.012H7.54zm11.415-9.303c0-1.662-1.353-3.015-3.015-3.015-1.665 0-3.015 1.353-3.015 3.015 0 1.665 1.35 3.015 3.015 3.015 1.663 0 3.015-1.35 3.015-3.015zm-5.273-.005c0-1.252 1.013-2.266 2.265-2.266 1.249 0 2.266 1.014 2.266 2.266 0 1.251-1.017 2.265-2.266 2.265-1.253 0-2.265-1.014-2.265-2.265z"/></g></g>' +
      '<circle class="lumen-lt-logo-mono lumen-lt-logo-edge" cx="12" cy="12" r="11.55" fill="none" stroke="#090A0C" stroke-width=".65"/>' +
      '<circle class="lumen-lt-logo-brand lumen-lt-logo-edge" cx="12" cy="12" r="11.55" fill="none" stroke="url(#lumen-lt-logo-gradient)" stroke-width=".65"/></svg>',
    wrench: '<svg viewBox="0 0 512 512" width="100%" height="100%" fill="currentColor"><path d="M507 109a13 13 0 00-22-6l-74 74-59-10-10-59 74-74a13 13 0 00-6-22 128 128 0 00-164 152L19 359a64 64 0 0090 90l195-195A128 128 0 00507 109z"/></svg>',
    key: '<svg viewBox="0 0 512 512" width="100%" height="100%" fill="currentColor"><path d="M336 0a176 176 0 00-168 228L7 389a24 24 0 00-7 17v82a24 24 0 0024 24h82a24 24 0 0017-7l23-23a24 24 0 007-17v-29h29a24 24 0 0024-24v-29h29a24 24 0 0017-7l32-32A176 176 0 10336 0zm48 176a48 48 0 110-96 48 48 0 010 96z"/></svg>',
    check: '<svg viewBox="0 0 512 512" width="100%" height="100%" fill="currentColor"><path d="M470 105a24 24 0 010 34L207 402a24 24 0 01-34 0L42 271a24 24 0 010-34l23-23a24 24 0 0134 0l91 91 223-223a24 24 0 0134 0z"/></svg>',
    discord: '<svg viewBox="0 0 640 512" width="100%" height="100%" fill="currentColor"><path d="M524 69A487 487 0 00404 32a339 339 0 00-17 34 455 455 0 00-135 0 339 339 0 00-17-34A487 487 0 00116 69C42 179 22 286 32 392a495 495 0 00150 75 361 361 0 0032-52 315 315 0 01-50-24l12-10a354 354 0 00304 0l12 10a318 318 0 01-51 24 358 358 0 0032 52 493 493 0 00151-75c12-123-20-229-100-323zM214 327c-29 0-53-27-53-59s23-59 53-59 54 27 53 59c0 32-24 59-53 59zm212 0c-29 0-53-27-53-59s23-59 53-59 54 27 53 59c0 32-24 59-53 59z"/></svg>',
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

  // downloader.sh tags HTTP 401/403 with errorCode "authentication", so a source
  // refusing the download says so instead of reading as a corrupt archive. No
  // shipped source asks for a credential, so this only reports the refusal.
  function fixesAuthExpired(state) {
    return !!(state && state.errorCode === "authentication");
  }

  function fixesGroupCategories(entries) {
    var groups = [], byKey = {};
    entries = entries && typeof entries.length === "number" ? entries : [];
    for (var i = 0; i < entries.length; i++) {
      var fix = entries[i] || {};
      var key = String(fix.category || "other");
      var normalizedKey = key.toLowerCase().replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "");
      if (normalizedKey === "steamtools-achievements-fix"
          || normalizedKey === "steamtools-achievement-fix") continue;
      if (!byKey[key]) {
        byKey[key] = { key: key, fixes: [] };
        groups.push(byKey[key]);
      }
      byKey[key].fixes.push(fix);
    }
    return groups;
  }

  function fixesNewestRelease(entries) {
    entries = entries && typeof entries.length === "number" ? entries : [];
    var newest = null, newestAt = -Infinity;
    for (var i = 0; i < entries.length; i++) {
      var fix = entries[i] || {};
      var createdAt = Date.parse(String(fix.createdAt || ""));
      if (!isFinite(createdAt)) createdAt = -Infinity;
      if (!newest || createdAt > newestAt) {
        newest = fix;
        newestAt = createdAt;
      }
    }
    return newest;
  }

  function fixesDefaultCategory(official, groups) {
    official = official || {};
    groups = groups || fixesGroupCategories(official.fixes);
    var preferred = official.recommended && String(official.recommended.category || "");
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].key === preferred) return preferred;
    }
    return groups.length ? groups[0].key : "";
  }

  function fixesCategoryLabel(key) {
    var labels = {
      voices38: "voices38", bypass: "Bypass", online_fix: "Online Fix",
      freetp: "FreeTP", denuvowo: "DenuvOwO", other: "Other",
    };
    return labels[String(key || "")] || String(key || "Other");
  }

  // Applied is already communicated by the receipt badge. Keep the featured
  // action's Steam identity stable instead of turning its main icon into state.
  function fixesOfficialIconKey() {
    return "luatools";
  }

  function fixesLuaToolsIcon() {
    return FX_ICONS.luatools;
  }

  function fixesAppliedStates(fixes) {
    fixes = fixes || {};
    return {
      fallbackOnline: fixes.fallbackOnlineApplied === true,
      spacewar: fixes.spacewarApplied === true,
    };
  }

  function fixesFallbackReceiptKind() {
    return FX_FALLBACK_RECEIPT_KIND;
  }

  try {
    window.__lumenFixesAppIdFromImgs = fixesAppIdFromImgs;
    window.__lumenFixesPickGear = fixesPickGear;
    window.__lumenFixesResolveName = fixesResolveName;
    window.__lumenFixesAppAllowed = fixesAppAllowed;
    window.__lumenFixesAuthExpired = fixesAuthExpired;
    window.__lumenFixesGroupCategories = fixesGroupCategories;
    window.__lumenFixesDefaultCategory = fixesDefaultCategory;
    window.__lumenFixesNewestRelease = fixesNewestRelease;
    window.__lumenFixesOfficialIconKey = fixesOfficialIconKey;
    window.__lumenFixesLuaToolsIcon = fixesLuaToolsIcon;
    window.__lumenFixesAppliedStates = fixesAppliedStates;
    window.__lumenFixesFallbackReceiptKind = fixesFallbackReceiptKind;
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
      ".lumen-fx-x:hover,.lumen-fx-x.active-focus{opacity:1;}",
      ".lumen-fx-gname{position:absolute;left:16px;right:16px;bottom:12px;z-index:2;font-size:23px;",
      "font-weight:800;color:#fff;text-shadow:0 2px 8px rgba(0,0,0,.85);white-space:nowrap;",
      "overflow:hidden;text-overflow:ellipsis;}",
      // body + grid of tiles
      ".lumen-fx-body{flex:1 1 auto;overflow-y:auto;overscroll-behavior:contain;padding:16px 16px 18px;}",
      // A view swapped in over the grid centres itself in the SAME box the grid
      // occupied (see fxKeepBodyHeight), so the panel never resizes or jumps.
      ".lumen-fx-body.centred{display:flex;flex-direction:column;justify-content:center;}",
      ".lumen-fx-sub{color:#8f98a0;font-size:12px;line-height:1.4;margin:0 2px 14px;}",
      ".lumen-fx-grid{display:grid;grid-template-columns:minmax(0,2fr) minmax(150px,1fr);",
      "grid-template-rows:repeat(3,minmax(82px,1fr));gap:10px;align-items:stretch;}",
      ".lumen-fx-tile{position:relative;display:flex;flex-direction:column;gap:8px;padding:15px 14px;",
      "border-radius:4px;cursor:pointer;background:rgba(255,255,255,.04);",
      "border:1px solid rgba(255,255,255,.08);transition:background .12s,border-color .12s;}",
      ".lumen-fx-tile .ic{width:22px;height:22px;color:#9aa3ab;transition:color .12s;}",
      ".lumen-fx-tile .tl{font-size:14px;font-weight:700;color:#fff;}",
      ".lumen-fx-tile .ds{font-size:11.5px;line-height:1.36;color:#8f98a0;}",
      ".lumen-fx-tile.featured{grid-column:1;grid-row:1/4;min-height:266px;padding:22px 20px;justify-content:flex-start;}",
      ".lumen-fx-tile.featured .ic{width:44px;height:44px;margin-bottom:4px;}",
      ".lumen-lt-logo-mono,.lumen-lt-logo-brand{transition:opacity .16s ease-out;}",
      ".lumen-lt-logo-brand{opacity:0;}",
      ".lumen-fx-tile.featured .tl{font-size:18px}",
      ".lumen-fx-tile.featured .ds{max-width:88%;font-size:12.5px;line-height:1.48;}",
      ".lumen-fx-grid>.lumen-fx-tile:not(.featured){min-height:0;padding:11px 12px;gap:5px;justify-content:center;}",
      ".lumen-fx-grid>.lumen-fx-tile:not(.featured) .ic{width:17px;height:17px}",
      ".lumen-fx-grid>.lumen-fx-tile:not(.featured) .tl{font-size:12.5px}",
      ".lumen-fx-grid>.lumen-fx-tile:not(.featured) .ds{font-size:10.5px;line-height:1.28;}",
      // Gamepad focus mirrors hover exactly: the pointer and the D-pad should
      // describe the same state, including the danger tile's red icon and the
      // featured tile's logo cross-fade.
      ".lumen-fx-tile:hover,.lumen-fx-tile.active-focus{background:rgba(255,255,255,.07);border-color:#1a9fff;}",
      ".lumen-fx-tile:hover .ic,.lumen-fx-tile.active-focus .ic{color:#fff;}",
      ".lumen-fx-tile.featured:not(.off):hover .lumen-lt-logo-mono,",
      ".lumen-fx-tile.featured:not(.off).active-focus .lumen-lt-logo-mono{opacity:0;}",
      ".lumen-fx-tile.featured:not(.off):hover .lumen-lt-logo-brand,",
      ".lumen-fx-tile.featured:not(.off).active-focus .lumen-lt-logo-brand{opacity:1;}",
      ".lumen-fx-tile.danger:hover,.lumen-fx-tile.danger.active-focus{border-color:#ec5c5c;}",
      ".lumen-fx-tile.danger:hover .ic,.lumen-fx-tile.danger.active-focus .ic{color:#ec5c5c;}",
      ".lumen-fx-tile.off{opacity:.42;cursor:default;}",
      ".lumen-fx-tile.off:hover,.lumen-fx-tile.off.active-focus{background:rgba(255,255,255,.04);border-color:rgba(255,255,255,.08);}",
      ".lumen-fx-tile.off:hover .ic,.lumen-fx-tile.off.active-focus .ic{color:#9aa3ab;}",
      // "needs auth" is carried by the badge alone: the tile keeps its own icon
      // and the normal blue hover, so nothing about it looks broken or disabled.
      ".lumen-fx-tile.auth .lumen-fx-badge{color:#f3ca62;background:rgba(224,179,65,.13);}",
      ".lumen-fx-tile.applied{border-color:rgba(121,199,84,.42);}",
      ".lumen-fx-tile.applied .lumen-fx-badge{color:#9bdc7c;background:rgba(92,156,62,.18);}",
      ".lumen-fx-badge .bic{width:9px;height:9px;flex:0 0 auto;}",
      ".lumen-fx-badge{position:absolute;top:11px;right:11px;display:inline-flex;align-items:center;",
      "gap:4px;font-size:9px;font-weight:700;",
      "text-transform:uppercase;letter-spacing:.5px;color:#8f98a0;background:rgba(255,255,255,.07);",
      "padding:2px 7px;border-radius:9px;}",
      ".lumen-fx-category-row{position:absolute;top:13px;right:13px;display:flex;justify-content:flex-end;margin:0;}",
      ".lumen-fx-category-badge{display:inline-flex;align-items:center;gap:6px;border:1px solid #46515e;",
      "border-radius:999px;background:#2b3038;color:#cdd3da;padding:5px 10px;font:700 10px 'Motiva Sans',Arial;",
      "letter-spacing:.35px;text-transform:uppercase;cursor:default;}",
      "button.lumen-fx-category-badge{cursor:pointer;}",
      "button.lumen-fx-category-badge:hover,button.lumen-fx-category-badge.active-focus{border-color:#1a9fff;color:#fff;}",
      ".lumen-fx-category-menu{position:absolute;right:0;top:calc(100% + 6px);z-index:8;min-width:150px;padding:5px;",
      "border:1px solid #46515e;border-radius:5px;background:#20242b;box-shadow:0 10px 24px rgba(0,0,0,.42);}",
      ".lumen-fx-category-menu button{display:block;width:100%;border:0;border-radius:3px;background:transparent;",
      "color:#b8bcbf;padding:7px 9px;text-align:left;font:600 11px 'Motiva Sans',Arial;cursor:pointer;}",
      ".lumen-fx-category-menu button:hover,.lumen-fx-category-menu button.active,",
      ".lumen-fx-category-menu button.active-focus{background:#303844;color:#fff;}",
      ".lumen-fx-tile.featured>.lumen-fx-badge{top:auto;right:14px;bottom:13px;}",
      "@media(max-width:620px){.lumen-fx-grid{grid-template-columns:minmax(0,1.6fr) minmax(130px,1fr)}.lumen-fx-tile.featured .ds{max-width:100%;}}",
      ".lumen-fx-note{margin-top:14px;display:flex;gap:8px;align-items:flex-start;font-size:12px;",
      "line-height:1.45;color:#e0b341;}",
      // centred loading / status / progress
      ".lumen-fx-center{display:flex;flex-direction:column;align-items:center;gap:14px;",
      "padding:30px 0;color:#b8bcbf;font-size:14px;}",
      ".lumen-fx-status{padding:18px 2px 6px;}",
      ".lumen-fx-msg{font-size:14px;color:#dcdedf;line-height:1.5;margin-bottom:14px;}",
      ".lumen-fx-pbar{height:6px;border-radius:3px;background:#1a1d23;border:1px solid #3d4450;overflow:hidden;}",
      ".lumen-fx-pbar > i{display:block;height:100%;width:100%;background:#1a9fff;transform:scaleX(0);",
      "transform-origin:left center;transition:transform .25s cubic-bezier(.22,1,.36,1);}",
      ".lumen-fx-spin{display:inline-block;width:26px;height:26px;box-sizing:border-box;",
      "border:3px solid rgba(255,255,255,.16);border-top-color:#1a9fff;border-radius:50%;",
      "animation:lumen-rot .7s linear infinite;}",
      ".lumen-fx-foot{flex:0 0 auto;display:flex;justify-content:flex-end;gap:9px;padding:13px 16px;",
      "border-top:1px solid rgba(255,255,255,.06);}",
      ".lumen-fx-btn{cursor:pointer;font:600 13px 'Motiva Sans',Arial;color:#fff;background:#1a9fff;",
      "border:1px solid #1a9fff;border-radius:3px;padding:8px 18px;text-decoration:none;transition:.12s;}",
      ".lumen-fx-btn:hover,.lumen-fx-btn.active-focus{background:#3cb0ff;border-color:#3cb0ff;}",
      ".lumen-fx-btn.secondary{background:transparent;border-color:#3d4450;color:#b8bcbf;}",
      ".lumen-fx-btn.secondary:hover,.lumen-fx-btn.secondary.active-focus{background:rgba(255,255,255,.06);border-color:#4a5663;color:#dcdedf;}",
      ".lumen-fx-lo{display:flex;gap:8px;margin-top:8px;}",
      ".lumen-fx-lo input{flex:1;min-width:0;background:#1a1d23;color:#dcdedf;font:12px monospace;",
      "border:1px solid #3d4450;border-radius:3px;padding:8px 10px;}",
      ".lumen-mbtn:disabled{opacity:.5;cursor:wait;}",
      // in-panel sign-in view: the Fixes Menu body turns into this, so the user
      // never leaves the panel they started from.
      ".lumen-fx-auth{display:flex;flex-direction:column;align-items:center;text-align:center;",
      "padding:4px 26px;}",
      ".lumen-fx-auth-ic{width:46px;height:46px;border-radius:50%;display:flex;align-items:center;",
      "justify-content:center;background:rgba(224,179,65,.12);border:1px solid rgba(224,179,65,.34);",
      "color:#e0b341;margin-bottom:14px;}",
      ".lumen-fx-auth-ic svg{width:21px;height:21px;}",
      ".lumen-fx-auth-ic.busy{background:rgba(102,192,244,.1);border-color:rgba(102,192,244,.3);color:#66c0f4;}",
      ".lumen-fx-auth-ic.done{background:rgba(121,199,84,.12);border-color:rgba(121,199,84,.34);color:#79c754;}",
      ".lumen-fx-auth-ic.bad{background:rgba(236,92,92,.12);border-color:rgba(236,92,92,.34);color:#ec5c5c;}",
      ".lumen-fx-auth-ttl{color:#fff;font-size:17px;font-weight:700;margin-bottom:9px;}",
      ".lumen-fx-auth-copy{color:#b8bcbf;font-size:13px;line-height:1.55;max-width:400px;}",
      ".lumen-fx-auth-row{display:flex;gap:9px;justify-content:center;margin-top:20px;}",
      ".lumen-fx-auth-btn{display:inline-flex;align-items:center;gap:8px;cursor:pointer;",
      "font:600 13px 'Motiva Sans',Arial;color:#fff;background:#5865f2;border:1px solid #5865f2;",
      "border-radius:3px;padding:9px 18px;text-decoration:none;transition:.12s;}",
      ".lumen-fx-auth-btn svg{width:15px;height:15px;}",
      ".lumen-fx-auth-btn:hover{background:#6b76f5;border-color:#6b76f5;}",
      ".lumen-fx-auth-btn.ghost{background:transparent;border-color:#3d4450;color:#b8bcbf;}",
      ".lumen-fx-auth-btn.ghost:hover{background:rgba(255,255,255,.06);color:#dcdedf;}",
      ".lumen-fx-auth-note{margin-top:18px;color:#8f98a0;font-size:11.5px;line-height:1.5;max-width:400px;}",
      ".lumen-fx-auth-alt{margin-top:14px;padding-top:13px;border-top:1px solid rgba(255,255,255,.06);",
      "width:100%;text-align:center;}",
      ".lumen-fx-auth-alt button{background:none;border:0;padding:0;color:#8f98a0;font:12px inherit;",
      "text-decoration:underline;cursor:pointer;}",
      ".lumen-fx-auth-alt button:hover{color:#66c0f4;}",
      ".lumen-fx-auth-spin{width:19px;height:19px;border:2px solid rgba(102,192,244,.25);",
      "border-top-color:#66c0f4;border-radius:50%;animation:lumen-rot .7s linear infinite;}",
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

  // Gamepad UI: join Steam's own navigation tree so the D-pad reaches the entry
  // from the Play row. No-op in Desktop Mode (no native focus controller).
  var _fxBtnFocus = null;
  function attachFixesButtonFocus(btn) {
    if (_fxBtnFocus) { try { _fxBtnFocus(); } catch (e) {} _fxBtnFocus = null; }
    btn.classList.add("Focusable");
    try { _fxBtnFocus = registerNativeInlineFocus(btn); } catch (e) { _fxBtnFocus = null; }
  }

  // The gap Steam leaves between two neighbouring icon buttons inside the
  // cluster, so our entry can reuse the same rhythm. Returns null when the
  // cluster has fewer than two visible icons to measure.
  function measureNativeIconGap(cluster) {
    if (!cluster || typeof cluster.querySelectorAll !== "function") return null;
    var icons = Array.prototype.slice.call(
      cluster.querySelectorAll('[role="button"]'))
      .map(function (el) { return el.getBoundingClientRect(); })
      .filter(function (r) { return r.width > 0 && r.height > 0; })
      .sort(function (a, b) { return a.left - b.left; });
    for (var i = 1; i < icons.length; i++) {
      var gap = icons[i].left - icons[i - 1].right;
      if (gap > 0 && gap < 40) return gap;
    }
    return null;
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
    // The desktop shell and Gamepad UI nest the gear at DIFFERENT depths, so a
    // fixed "two levels up" lands in the wrong place in one of them (in Gamepad
    // UI it put the entry above the Play button). Resolve the action row by
    // LAYOUT instead: walk up from the gear and keep the outermost ancestor that
    // is still a horizontal flex row on the gear's own line. Its child that
    // holds the gear is the icon cluster, and the entry goes just before it —
    // left of the gear in both shells.
    var gearRect = gear.getBoundingClientRect();
    var row = null;
    var rowChild = null;
    var node = gear;
    for (var up = 0; up < 6 && node.parentElement; up++) {
      var parent = node.parentElement;
      var pr = parent.getBoundingClientRect();
      if (pr.height <= 0) break;
      var sameLine = Math.abs(pr.top - gearRect.top) < 40
        && Math.abs((pr.top + pr.height) - (gearRect.top + gearRect.height)) < 40;
      // Once an ancestor is taller than the gear's line we have left the action
      // row; anything above that would stack the entry instead of placing it
      // beside the icons.
      if (!sameLine) break;
      // Plain wrappers on the same line are skipped, not accepted: inserting a
      // sibling into a block wrapper is exactly what pushed the entry above the
      // Play button in Gamepad UI. Only a horizontal flex row can host it.
      var ps = window.getComputedStyle(parent);
      if ((ps.display === "flex" || ps.display === "inline-flex")
          && ps.flexDirection === "row") {
        row = parent;
        rowChild = node;
      }
      node = parent;
    }
    if (row && rowChild && rowChild.parentElement === row
        && rowChild !== gearWrap) {
      btn.style.alignSelf = "center";
      row.insertBefore(btn, rowChild);
      try {
        // Match the entry->cluster gap to the native gap BETWEEN the icon
        // buttons, so the three controls share one rhythm. The row already
        // applies its own `gap`, and the cluster may carry a margin of its own,
        // so target the measured distance instead of adding to it: the needed
        // margin is the native icon gap minus whatever the row's gap supplies.
        var iconGap = measureNativeIconGap(rowChild);
        if (iconGap !== null) {
          var rowGap = parseFloat(window.getComputedStyle(row).columnGap);
          if (!isFinite(rowGap)) rowGap = 0;
          _fxCluster = rowChild;
          _fxClusterOrigMl = rowChild.style.marginLeft;
          // Measure the resulting gap and correct it, rather than deriving it
          // from the box model: the cluster carries its own left inset and the
          // row applies its gap, so the visible distance is the only reliable
          // input. The correction can be negative when the row's gap alone is
          // already wider than one icon step.
          rowChild.style.marginLeft = "0px";
          var actual = rowChild.getBoundingClientRect().left
            - btn.getBoundingClientRect().right;
          var firstIcon = rowChild.querySelector('[role="button"]');
          if (firstIcon) {
            actual = firstIcon.getBoundingClientRect().left
              - btn.getBoundingClientRect().right;
          }
          rowChild.style.marginLeft = Math.round(iconGap - actual) + "px";
        }
      } catch (e) {}
      attachFixesButtonFocus(btn);
      return true;
    }
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
      attachFixesButtonFocus(btn);
      return true;
    }
    // Fallback: original in-row placement left of the gear (may shrink icons).
    if (!gearWrap || !gearWrap.parentElement) return false;
    gearWrap.parentElement.insertBefore(btn, gearWrap);
    attachFixesButtonFocus(btn);
    return true;
  }

  // Remove the entry and restore the icon cluster's original left margin.
  function removeFixesButton() {
    if (_fxBtnFocus) { try { _fxBtnFocus(); } catch (e) {} _fxBtnFocus = null; }
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

  // ── alert / confirm ──────────────────────────────────────────────────────────
  // Both reuse the Lumen modal styles (03-styles) and register with Steam's
  // gamepad navigation, so the confirmation is reachable with the D-pad in
  // Gamepad UI instead of being a dead end.
  function fxModalShell(titleText, message) {
    injectStyles();
    var back = document.createElement("div");
    back.className = "lumen-modal-back";
    var m = document.createElement("div");
    m.className = "lumen-modal";
    var title = document.createElement("div");
    title.className = "mt";
    title.textContent = titleText;
    var body = document.createElement("div");
    body.className = "mb";
    body.textContent = message;
    var row = document.createElement("div");
    row.className = "mrow";
    m.appendChild(title); m.appendChild(body); m.appendChild(row);
    back.appendChild(m);
    return { back: back, row: row };
  }

  function fxModalButton(row, label, primary, onClick) {
    var b = document.createElement("div");
    b.className = "lumen-mbtn" + (primary ? " primary" : "");
    b.setAttribute("role", "button");
    b.textContent = label;
    b.addEventListener("click", onClick);
    row.appendChild(b);
    return b;
  }

  function fxAlert(msg) {
    var shell = fxModalShell(fxStrings().title, msg);
    var trap = null;
    var close = function () {
      if (trap) { try { trap(); } catch (e) {} trap = null; }
      if (shell.back.parentNode) shell.back.remove();
    };
    fxModalButton(shell.row, "OK", true, close);
    shell.back.addEventListener("click", function (e) {
      if (e.target === shell.back) close();
    });
    (document.body || document.documentElement).appendChild(shell.back);
    trap = trapModalFocus(shell.back, close, {
      selector: LUMEN_OVERLAY_ACTION_SELECTOR,
    });
  }

  function fxConfirm(msg, onYes) {
    var S = fxStrings();
    var shell = fxModalShell(S.unfixLabel, msg);
    var trap = null;
    var close = function () {
      if (trap) { try { trap(); } catch (e) {} trap = null; }
      if (shell.back.parentNode) shell.back.remove();
    };
    fxModalButton(shell.row, S.cancel, false, close);
    fxModalButton(shell.row, S.unfixLabel, true, function () {
      close();
      onYes();
    });
    shell.back.addEventListener("click", function (e) {
      if (e.target === shell.back) close();
    });
    (document.body || document.documentElement).appendChild(shell.back);
    // Default the selection to Cancel: the destructive action should never be
    // one accidental A press away.
    trap = trapModalFocus(shell.back, close, {
      selector: LUMEN_OVERLAY_ACTION_SELECTOR,
      preferFirst: true,
    });
  }

  // ── window + flows ───────────────────────────────────────────────────────────

  function fxParse(res) {
    try { return typeof res === "string" ? JSON.parse(res) : res; }
    catch (e) { return null; }
  }
  var _fxEsc = null;
  var _fxFocusTrap = null;
  function fxClose() {
    if (_fxFocusTrap) { _fxFocusTrap(); _fxFocusTrap = null; }
    var o = document.getElementById(FX_OVERLAY_ID);
    if (o) o.remove();
    if (_fxEsc) { document.removeEventListener("keydown", _fxEsc, true); _fxEsc = null; }
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
    // Gamepad UI: hand the window to Steam's focus navigation so the D-pad
    // walks the fix tiles instead of the game page behind it. The tiles are
    // divs with click handlers, hence the wider overlay selector. Re-registered
    // by the MutationObserver inside the trap as the tiles finish loading.
    if (_fxFocusTrap) { _fxFocusTrap(); _fxFocusTrap = null; }
    _fxFocusTrap = trapModalFocus(overlay, fxClose, {
      selector: LUMEN_OVERLAY_ACTION_SELECTOR,
      preferFirst: true,
    });

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
    t.className = "lumen-fx-tile" + (opts.danger ? " danger" : "") +
      (opts.auth ? " auth" : "") + (opts.applied ? " applied" : "") +
      (opts.featured ? " featured" : "") +
      (opts.off ? " off" : "");
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
      // The key rides on the badge, next to the label — the tile icon stays put.
      if (opts.badgeIcon && FX_ICONS[opts.badgeIcon]) {
        var bic = document.createElement("span");
        bic.className = "bic";
        bic.innerHTML = FX_ICONS[opts.badgeIcon];
        b.appendChild(bic);
      }
      var btext = document.createElement("span");
      btext.textContent = opts.badge;
      b.appendChild(btext);
      t.appendChild(b);
    }
    t.addEventListener("click", function (e) {
      e.preventDefault();
      if (opts.off) return;
      onClick();
    });
    return t;
  }

  // The rendered result set, kept for handlers that run outside fxRenderMenu's
  // scope (fxPoll among them).
  var fxLastFixes = null;

  // Freeze the body at the height the tile grid gave it, and release it when the
  // grid comes back. Without this the panel resizes every time a view is swapped
  // in (the sign-in view is ~80px taller than the grid), which reads as the whole
  // window jumping and sitting off-centre.
  function fxKeepBodyHeight(body, keep) {
    if (!body) return;
    try {
      if (keep) {
        var base = Number(body.getAttribute("data-lumen-base-h")) || 0;
        if (base > 0) body.style.minHeight = base + "px";
        body.classList.add("centred");
      } else {
        body.style.minHeight = "";
        body.classList.remove("centred");
      }
    } catch (e) {}
  }

  function fxRenderMenu(win, body, appid, ctx, fixes, gameName) {
    var S = fxStrings();
    fxLastFixes = fixes;
    fxKeepBodyHeight(body, false);
    var installed = !!ctx.isInstalled;
    var underProton = !!ctx.runsUnderProton;
    var official = fixes.luaToolsFixes || {};
    var appliedStates = fixesAppliedStates(fixes);
    var categoryGroups = fixesGroupCategories(official.fixes);
    var selectedCategory = fixesDefaultCategory(official, categoryGroups);

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

    var categoryRow = document.createElement("div");
    categoryRow.className = "lumen-fx-category-row";
    var categoryBadge = null, categoryMenu = null, officialTile = null;
    var selectedGroup = function () {
      for (var i = 0; i < categoryGroups.length; i++) {
        if (categoryGroups[i].key === selectedCategory) return categoryGroups[i];
      }
      return categoryGroups[0] || null;
    };
    var selectedFix = function () {
      var group = selectedGroup();
      return group ? fixesNewestRelease(group.fixes) : null;
    };
    var drawOfficialTile = function () {
      var candidate = selectedFix();
      var needsAuth = !!candidate && official.authConfigured !== true;
      var preparationBlocked = !!candidate && candidate.requiresPreparation === true;
      var nativeBlocked = !!candidate && candidate.hasFix === true && isNative;
      var off = !installed || !candidate || preparationBlocked || nativeBlocked;
      var applied = !!candidate && candidate.applied === true;
      var desc = !candidate ? S.crackNone
        : (nativeBlocked ? S.nativeWarnShort
          : (preparationBlocked ? S.preparationRequired
            : (candidate.description || S.crackDesc)));
      var tile = fxTile(S.luaToolsLabel,
        (nativeBlocked || preparationBlocked) ? desc : (candidate ? S.luaToolsDesc : desc), {
        iconKey: fixesOfficialIconKey(), off: off, warn: nativeBlocked,
        auth: needsAuth, applied: applied, featured: true,
        badge: applied ? S.appliedBadge : (off ? S.unavailable
          : (needsAuth ? S.authRequiredBadge : null)),
        badgeIcon: needsAuth && !applied ? "key" : null,
      }, function () {
        if (!candidate) { fxAlert(S.crackNone); return; }
        if (needsAuth) {
          fxClose();
          if (typeof window.__lumenOpenLuaToolsAccount === "function") {
            window.__lumenOpenLuaToolsAccount();
          }
          return;
        }
        if (preparationBlocked) { fxAlert(S.preparationRequired); return; }
        var apply = function () {
          fxApplyLuaTools(appid, candidate.id, candidate.title || S.crackLabel, ctx, win);
        };
        if (candidate.hasFix === true) protonGate(apply); else apply();
      });
      if (categoryGroups.length) tile.appendChild(categoryRow);
      if (officialTile && officialTile.parentNode) {
        officialTile.parentNode.replaceChild(tile, officialTile);
      } else {
        grid.insertBefore(tile, grid.firstChild);
      }
      officialTile = tile;
    };

    if (categoryGroups.length) {
      categoryBadge = document.createElement(categoryGroups.length > 1 ? "button" : "span");
      if (categoryGroups.length > 1) categoryBadge.type = "button";
      categoryBadge.className = "lumen-fx-category-badge";
      var drawCategoryBadge = function () {
        categoryBadge.textContent = fixesCategoryLabel(selectedCategory)
          + (categoryGroups.length > 1 ? "  ▾" : "");
      };
      drawCategoryBadge();
      categoryRow.appendChild(categoryBadge);
      if (categoryGroups.length > 1) {
        categoryMenu = document.createElement("div");
        categoryMenu.className = "lumen-fx-category-menu";
        categoryMenu.hidden = true;
        categoryGroups.forEach(function (group) {
          var option = document.createElement("button");
          option.type = "button";
          option.textContent = fixesCategoryLabel(group.key);
          option.className = group.key === selectedCategory ? "active" : "";
          option.addEventListener("click", function (e) {
            e.preventDefault(); e.stopPropagation();
            selectedCategory = group.key;
            var options = categoryMenu.querySelectorAll("button");
            for (var i = 0; i < options.length; i++) options[i].className = "";
            option.className = "active";
            categoryMenu.hidden = true;
            drawCategoryBadge(); drawOfficialTile();
          });
          categoryMenu.appendChild(option);
        });
        categoryBadge.addEventListener("click", function (e) {
          e.preventDefault(); e.stopPropagation(); categoryMenu.hidden = !categoryMenu.hidden;
        });
        categoryRow.appendChild(categoryMenu);
      }
    }
    drawOfficialTile();

    // The unauthenticated mirror remains available as a clearly secondary
    // fallback. It never replaces or outranks the official category selection.
    var fallbackOnline = fxTile(S.fallbackOnlineLabel, S.fallbackOnlineDesc,
      { iconKey: "globe", off: true, applied: appliedStates.fallbackOnline,
        badge: appliedStates.fallbackOnline ? S.appliedBadge
          : (installed ? S.checkingBadge : S.unavailable) },
      function () {});
    grid.appendChild(fallbackOnline);
    var replaceFallbackOnline = function (next) {
      if (fallbackOnline.parentNode) fallbackOnline.parentNode.replaceChild(next, fallbackOnline);
      fallbackOnline = next;
    };
    if (installed) {
      call("ResolveOnlineFix", { appid: appid, gameName: gameName || "", contentScriptQuery: "" })
        .then(fxParse).then(function (result) {
          if (result && result.success && result.found && result.url) {
            replaceFallbackOnline(fxTile(S.fallbackOnlineLabel,
              isNative ? S.nativeWarnShort : S.fallbackOnlineDesc,
              { iconKey: "globe", off: isNative, warn: isNative,
                applied: appliedStates.fallbackOnline,
                badge: appliedStates.fallbackOnline ? S.appliedBadge
                  : (isNative ? S.unavailable : null) }, function () {
                protonGate(function () {
                  fxApply(appid, result.url, S.fallbackOnlineLabel, ctx, win,
                    FX_FALLBACK_RECEIPT_KIND);
                });
              }));
          } else {
            replaceFallbackOnline(fxTile(S.fallbackOnlineLabel, S.fallbackOnlineDesc,
              { iconKey: "globe", off: true, applied: appliedStates.fallbackOnline,
                badge: appliedStates.fallbackOnline ? S.appliedBadge : S.unavailable }, function () {}));
          }
        }).catch(function () {
          replaceFallbackOnline(fxTile(S.fallbackOnlineLabel, S.fallbackOnlineDesc,
            { iconKey: "globe", off: true, applied: appliedStates.fallbackOnline,
              badge: appliedStates.fallbackOnline ? S.appliedBadge : S.unavailable }, function () {}));
        });
    }

    grid.appendChild(fxTile(S.aioLabel, S.aioDesc,
      { iconKey: "layers", off: !installed, applied: appliedStates.spacewar,
        badge: appliedStates.spacewar ? S.appliedBadge : null }, function () {
        fxApplySpace(appid);
      }));

    grid.appendChild(fxTile(S.unfixLabel, S.unfixDesc,
      { iconKey: "trash", danger: true, off: !installed }, function () {
        fxConfirm(S.unfixConfirm, function () { fxUnfix(appid, ctx, win); });
      }));

    body.appendChild(grid);
    // Record the grid's natural height so swapped-in views can reuse the box.
    setTimeout(function () {
      try {
        if (!body.style.minHeight && body.offsetHeight > 0) {
          body.setAttribute("data-lumen-base-h", String(body.offsetHeight));
        }
      } catch (e) {}
    }, 0);

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

  // Footer for a download the source refused: Close plus a primary action that
  // retries it. There is nothing for the user to enter here — no shipped source
  // asks for a credential — so the only useful move is trying again.
  function fxFooterRetry(win, onRetry) {
    fxFooterClose(win);
    var f = win.querySelector(".lumen-fx-foot");
    if (!f) return;
    var close = f.querySelector(".lumen-fx-btn");
    if (close) close.className = "lumen-fx-btn secondary";
    var a = document.createElement("a");
    a.href = "#";
    a.className = "lumen-fx-btn";
    a.textContent = fxStrings().authRetry;
    a.addEventListener("click", function (e) {
      e.preventDefault();
      if (typeof onRetry === "function") onRetry();
    });
    f.appendChild(a);
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
  function fxApply(appid, url, fixType, ctx, win, receiptKind) {
    var S = fxStrings();
    if (!ctx.installPath) { fxAlert(S.notInstalled); return; }
    // Show the loading view up front: the start RPC does network work (resolve +
    // begin download), and waiting for it before switching left the tile grid on
    // screen for a few seconds after the click.
    fxShowProgress(win, fixType);
    call("ApplyGameFix", {
      appid: appid, downloadUrl: url, installPath: ctx.installPath,
      fixType: fixType, gameName: ctx.gameName || "", contentScriptQuery: "",
      receiptKind: receiptKind || "",
    }).then(function (res) {
      var p = fxParse(res);
      if (p && p.success) {
        fxPoll(appid, url, fixType, ctx, win,
          receiptKind === FX_FALLBACK_RECEIPT_KIND ? FX_FALLBACK_RECEIPT_KIND : null);
      } else if (fixesAuthExpired(p)) {
        fxFailProgress(win, (p && p.error) ? String(p.error) : S.authViewTitle);
      } else {
        fxFailProgress(win, (p && p.error) ? String(p.error) : S.applyErr);
      }
    }).catch(function () { fxFailProgress(win, S.applyErr); });
  }

  function fxApplyLuaTools(appid, fixId, fixType, ctx, win) {
    var S = fxStrings();
    if (!ctx.installPath) { fxAlert(S.notInstalled); return; }
    // Switch to the loading view immediately so the click feels instant.
    // StartLuaToolsFix resolves the fix and starts the download (a few seconds
    // of network); waiting on it before showing progress was the delay.
    fxShowProgress(win, fixType);
    call("StartLuaToolsFix", {
      appid: appid, fixId: fixId, installPath: ctx.installPath,
      gameName: ctx.gameName || "", contentScriptQuery: "",
    }).then(function (res) {
      var p = fxParse(res);
      if (p && p.success) {
        fxPoll(appid, null, fixType, ctx, win, fixId);
        return;
      }
      if (p && (p.errorCode === "not_signed_in" || p.errorCode === "session_expired")) {
        fxClose();
        if (typeof window.__lumenOpenLuaToolsAccount === "function") {
          window.__lumenOpenLuaToolsAccount();
        }
        return;
      }
      fxFailProgress(win, (p && p.error) ? String(p.error) : S.applyErr);
    }).catch(function () { fxFailProgress(win, S.applyErr); });
  }

  function fxShowProgress(win, fixType) {
    var S = fxStrings();
    var body = win.querySelector(".lumen-fx-body");
    if (!body) return;
    // Same frozen box as the grid and the sign-in view, so the panel holds still.
    fxKeepBodyHeight(body, true);
    body.innerHTML =
      '<div class="lumen-fx-status"><div class="lumen-fx-msg" id="lumen-fx-pmsg"></div>' +
      '<div class="lumen-fx-pbar"><i></i></div></div>';
    body.querySelector("#lumen-fx-pmsg").textContent = S.applying.replace("{fix}", fixType);
    var f = win.querySelector(".lumen-fx-foot");
    if (f) f.remove();
  }

  // The loading view now shows before the start RPC resolves, so a start failure
  // is reported in place (message + Close) instead of as a popup layered over a
  // frozen "Applying…" screen — matching how fxPoll reports later failures.
  function fxFailProgress(win, text) {
    var S = fxStrings();
    var msg = win.querySelector("#lumen-fx-pmsg");
    if (msg) msg.textContent = S.failed.replace("{error}", text || S.unknownError);
    var bar = win.querySelector(".lumen-fx-pbar > i");
    if (bar) bar.style.transform = "scaleX(0)";
    fxFooterClose(win);
  }

  function fxPoll(appid, url, fixType, ctx, win, officialFixId) {
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
          if (bar) bar.style.transform = "scaleX(" + ((pct || 4) / 100) + ")";
          setTimeout(poll, 600);
        } else if (st.status === "extracting") {
          if (msg) msg.textContent = S.extracting;
          if (bar) bar.style.transform = "scaleX(1)";
          setTimeout(poll, 600);
        } else if (st.status === "done") {
          if (bar) bar.style.transform = "scaleX(1)";
          fxApplyOverrides(appid, ctx, win).then(function (launchApplied) {
            if (!officialFixId || !launchApplied) return { success: launchApplied };
            return call("CompleteLuaToolsFixApply", {
              appid: appid, fixId: officialFixId, contentScriptQuery: "",
            }).then(fxParse);
          }).then(function (completed) {
            if (officialFixId && !(completed && completed.success)) {
              if (msg && !win.querySelector(".lumen-fx-lo")) {
                msg.textContent = S.failed.replace("{error}",
                  (completed && completed.error) || S.launchApplyFailed);
              }
            } else if (msg) {
              msg.textContent = S.appliedOk.replace("{fix}", fixType);
            }
            fxFooterClose(win);
          }).catch(function () {
            if (msg) msg.textContent = S.failed.replace("{error}", S.launchApplyFailed);
            fxFooterClose(win);
          });
        } else if (st.status === "failed") {
          if (fixesAuthExpired(st)) {
            // The source refused the download. Report what it said and offer the
            // retry; nothing here is the user's to re-enter.
            if (msg) msg.textContent = st.error || S.authViewTitle;
            fxFooterRetry(win, function () {
              fxApply(appid, url, fixType, ctx, win);
            });
            return;
          }
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
    return call("GetFixLaunchOptions", {
      appid: appid, compatToolName: "", currentLaunchOptions: "",
      installPath: ctx.installPath || "", contentScriptQuery: "",
    }).then(function (res) {
      var p = fxParse(res);
      if (!(p && p.success)) return false;
      if (!(p.apply && p.launchOptions)) return true;
      var opts = String(p.launchOptions);
      return call("__lumenSetLaunchOptions", { appid: Number(appid), options: opts })
        .then(function (r) {
          var ok = false;
          try { ok = (typeof r === "string" ? JSON.parse(r) : r).ok; } catch (e) {}
          if (!ok) fxLaunchHint(win, opts);
          return ok;
        })
        .catch(function () { fxLaunchHint(win, opts); return false; });
    }).catch(function () { return false; });
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

  // Unfix — restore only files recorded by fix applications, drop the SpaceFix
  // mapping, and clear fix-added launch options. No full Steam validation.
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
