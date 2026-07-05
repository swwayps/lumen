// LM-FRAGMENT menubar button (findMenubar, anchoring) + bootstrap + IIFE close
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.


  // ── menubar button ──────────────────────────────────────────────────────────
  // Find the native menubar WITHOUT reading the localized labels. The old code
  // matched the English words View/Friends/Games/Help, so the button never
  // anchored on a non-English client (e.g. pt-BR: Exibir/Amigos/Jogos/Ajuda) —
  // findMenubar() returned null and no moon button appeared. Steam ships in ~30
  // UI languages, so hard-coding label sets per language doesn't scale.
  //
  // The menubar (captured live via CDP) is a compact row whose direct children
  // are the menu items, e.g.:
  //   <div .menubar>
  //     <div .item> <logo/> "Steam" </div>   <- item 0: logo + bare text node
  //     <div .item> <div>Exibir</div> </div>
  //     <div .item> <div>Amigos</div> </div>  ...
  // The FIRST item's text is "Steam" in every locale (it's the brand, not a
  // translated word), but it's NOT a leaf (it holds the logo + a bare text
  // node), so anchoring on a "Steam" leaf finds nothing. Instead scan for the
  // row itself: a small container (<= 12 children) whose direct children are
  // >= 4 short-text items, ONE of which reads exactly "Steam". Language
  // independent and selector-free (class names are hashed and churn).
  // Returns { bar, helpItem } or null.
  function findMenubar() {
    // A menu entry is a short, single-line element (its text is the label).
    function isItem(node) {
      var t = (node.textContent || "").trim();
      return t.length > 0 && t.length <= 24 && t.indexOf("\n") === -1;
    }

    var nodes = document.querySelectorAll("div,span,button,a");
    for (var i = 0; i < nodes.length; i++) {
      var bar = nodes[i];
      var kids = bar.children;
      if (!kids || kids.length < 4 || kids.length > 12) continue;
      var items = 0, hasSteam = false;
      for (var j = 0; j < kids.length; j++) {
        if (!isItem(kids[j])) continue;
        items++;
        if ((kids[j].textContent || "").trim() === "Steam") hasSteam = true;
      }
      // Steam menubar = the brand item + the localized View/Friends/Games/Help.
      if (hasSteam && items >= 4) {
        return { bar: bar, helpItem: bar.lastElementChild };
      }
    }
    return null;
  }

  function makeButton() {
    var b = document.createElement("div");
    b.id = BTN_ID;
    b.textContent = MOON;
    b.title = "Lumen settings";
    b.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      // Broadcast so the overlay opens in whichever view is on top (store /
      // community web views composite above this menubar window).
      requestOpen();
    });
    return b;
  }

  // Insert the button after the menubar's last item (Help in every locale, so
  // it sits at the end of the menu row), else appended. Idempotent.
  function ensureButton(found) {
    if (document.getElementById(BTN_ID)) return true;
    injectStyles();
    var btn = makeButton();
    var bar = found.bar;
    var helpWrapper = found.helpItem;
    while (helpWrapper && helpWrapper.parentElement !== bar) helpWrapper = helpWrapper.parentElement;
    if (helpWrapper && helpWrapper.nextSibling) bar.insertBefore(btn, helpWrapper.nextSibling);
    else bar.appendChild(btn);
    return true;
  }

  var observer = null;
  function startObserver(bar) {
    if (observer) return;
    // Scoped to the menubar node ONLY (never document.body) so it's cheap and
    // re-adds the button if React reconciles the bar and drops our child.
    observer = new MutationObserver(function () {
      if (!document.getElementById(BTN_ID)) {
        var f = findMenubar();
        if (f) ensureButton(f);
      }
    });
    try { observer.observe(bar, { childList: true }); } catch (e) {}
  }

  // Anchor with retries. The menubar may not exist at first paint, and on a
  // COLD Steam start it can take well over 30s to render/stabilize — the menu
  // script is injected early. We retry fast for the first ~30s, then slower for
  // a few minutes, until the menubar appears. (The old code gave up after ~30s
  // and the re-add observer only starts AFTER a successful find, so a late
  // menubar left the button missing — the "button gone after restart" bug.)
  var attempts = 0;
  var MAX_ATTEMPTS = 150; // ~30s fast + ~4min slow; the shell always shows one
  function tryAnchor() {
    window.__lumenAnchorAttempts = (window.__lumenAnchorAttempts || 0) + 1;
    if (document.getElementById(BTN_ID)) return;
    var f = findMenubar();
    window.__lumenLastFind = f ? "found" : "null";
    if (f) {
      ensureButton(f);
      startObserver(f.bar);
      log("anchored full-moon button");
      // Steam has finished loading (the menubar exists): this is the moment to
      // check whether slsteam-moon actually injected, and warn if it didn't.
      maybeWarnSlsNotLoaded();
      return;
    }
    attempts++;
    if (attempts <= MAX_ATTEMPTS) setTimeout(tryAnchor, attempts <= 30 ? 1000 : 2000);
    else log("menubar not found after extended wait; giving up (graceful)");
  }

  // Only anchor the menubar button in the main client shell. This script is
  // ALSO injected into the store/community web views (so the overlay can render
  // on top of them), but those have no Steam menubar — and their own page nav
  // can contain text matching our labels, which made findMenubar() inject a
  // stray moon button into the page header (the "gap" bug). In a web view we
  // only need the overlay globals, already exposed above; skip the button.
  var __lumenHost = (typeof location !== "undefined" && location.hostname) || "";
  if (__lumenHost === "store.steampowered.com" || __lumenHost === "steamcommunity.com") {
    log("web view (" + __lumenHost + "): overlay-only, no menubar button");
  } else {
    tryAnchor();
  }
  log("loaded");
})();
