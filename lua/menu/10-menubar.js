// LM-FRAGMENT menubar button (findMenubar, anchoring) + bootstrap + IIFE close
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.


  // ── menubar button ──────────────────────────────────────────────────────────
  var MENU_LABELS = ["Steam", "View", "Friends", "Games", "Help"];

  // Find the native menubar. Each label (View/Friends/Games/Help) is a leaf div
  // wrapped in its own container, and all those wrappers share a common menubar
  // row. So: collect the label leaves, then climb from one until we hit the
  // lowest ancestor that contains >= 3 of them — that ancestor is the menubar.
  // Selector-free (class names are hashed and churn across Steam updates), tuned
  // against the live DOM on the test VM. Returns { bar, helpItem } or null.
  function findMenubar() {
    var nodes = document.querySelectorAll("div,span,button,a");
    var leaves = [];
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.children && el.children.length !== 0) continue; // leaf only
      var txt = (el.textContent || "").trim();
      if (MENU_LABELS.indexOf(txt) === -1) continue;
      leaves.push({ txt: txt, el: el });
    }
    if (leaves.length < 3) return null;

    function countIn(node) {
      var c = 0;
      for (var j = 0; j < leaves.length; j++) if (node.contains(leaves[j].el)) c++;
      return c;
    }
    var bar = null, n = leaves[0].el.parentElement;
    while (n) {
      if (countIn(n) >= 3) { bar = n; break; }
      n = n.parentElement;
    }
    if (!bar) return null;

    var helpItem = null;
    for (var k = 0; k < leaves.length; k++) if (leaves[k].txt === "Help") helpItem = leaves[k].el;
    return { bar: bar, helpItem: helpItem };
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

  // Insert the button into the menubar, after the wrapper that holds "Help"
  // (so it sits at the end of the menu row), else appended. Idempotent.
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

  // Anchor with a few bounded retries (the menubar may not exist at first paint);
  // no infinite polling — give up gracefully if never found.
  var attempts = 0;
  function tryAnchor() {
    window.__lumenAnchorAttempts = (window.__lumenAnchorAttempts || 0) + 1;
    if (document.getElementById(BTN_ID)) return;
    var f = findMenubar();
    window.__lumenLastFind = f ? "found" : "null";
    if (f) {
      ensureButton(f);
      startObserver(f.bar);
      log("anchored full-moon button");
      return;
    }
    attempts++;
    if (attempts <= 30) setTimeout(tryAnchor, 1000); // up to ~30s after load
    else log("menubar not found; giving up (graceful)");
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
