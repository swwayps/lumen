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

  // A custom theme is allowed to completely rearrange Steam's titlebar. Keep
  // the recovery button outside every theme-owned stacking context, and use
  // the native titlebar only as a source of geometry. This layer never catches
  // input itself; only the 32px Lumen button does.
  var ACCESS_LAYER_ID = "lumen-access-layer";
  var fallbackHost = null;
  var lastFallbackHost = null;
  var fallbackMutationObserver = null;
  var fallbackResizeObserver = null;
  var fallbackPositionTimer = null;
  // Placement is a theme-session decision. Hit-testing can be transient while
  // Steam opens popups or a theme finishes an animation; it must never turn a
  // valid Help-side anchor into a fallback two seconds later. We only choose a
  // different mode when the active theme changes or the anchored DOM subtree
  // is genuinely destroyed.
  var accessPlacementTheme = null;
  var accessPlacementMode = null;

  function currentThemeKey() {
    // The menu channel is composed before the theme asset channel, so the
    // applied marker may legitimately appear a little later during startup.
    // The configured key is injected with the menu bundle and is therefore the
    // stable identity for this whole theme session.
    if (typeof window.__lumenConfiguredTheme === "string")
      return window.__lumenConfiguredTheme;
    return window.__lumenThemeApplied || "";
  }

  function rememberPlacement(btn, mode) {
    var theme = currentThemeKey();
    accessPlacementTheme = theme;
    accessPlacementMode = mode;
    if (btn && btn.dataset) btn.dataset.lumenTheme = theme;
  }

  function nodeIsConnected(node) {
    return !!(node && document.documentElement && document.documentElement.contains(node));
  }

  function ensureAccessLayer() {
    var layer = document.getElementById(ACCESS_LAYER_ID);
    if (layer) return layer;
    layer = document.createElement("div");
    layer.id = ACCESS_LAYER_ID;
    (document.documentElement || document.body).appendChild(layer);
    return layer;
  }

  function stopFallbackObservers() {
    if (fallbackMutationObserver) fallbackMutationObserver.disconnect();
    if (fallbackResizeObserver) fallbackResizeObserver.disconnect();
    if (fallbackPositionTimer) clearTimeout(fallbackPositionTimer);
    fallbackMutationObserver = null;
    fallbackResizeObserver = null;
    fallbackPositionTimer = null;
  }

  // Insert the button after the menubar's last item (Help in every locale, so
  // it sits at the end of the menu row), else appended. Idempotent.
  function ensureButton(found) {
    if (document.getElementById(BTN_ID)) return true;
    injectStyles();
    var remembered = findFallbackHost(found);
    if (remembered) lastFallbackHost = remembered;
    var btn = makeButton();
    rememberPlacement(btn, "native");
    var bar = found.bar;
    var helpWrapper = found.helpItem;
    while (helpWrapper && helpWrapper.parentElement !== bar) helpWrapper = helpWrapper.parentElement;
    if (helpWrapper && helpWrapper.nextSibling) bar.insertBefore(btn, helpWrapper.nextSibling);
    else bar.appendChild(btn);
    return true;
  }

  // Themes may replace the complete menubar after Lumen has anchored, which
  // detaches both the button and the observer's old root. Keep the normal
  // anchor, but guarantee a fixed recovery entry if replacement repeats.
  function removeAccessButton(btn) {
    if (!btn) return;
    var wasFallback = btn.classList && btn.classList.contains("lumen-fallback");
    var host = wasFallback ? fallbackHost : null;
    if (wasFallback) stopFallbackObservers();
    btn.remove();
    if (host && host.classList && host.classList.contains("lumen-fallback-host"))
      host.classList.remove("lumen-fallback-host");
    if (wasFallback) {
      fallbackHost = null;
      var layer = document.getElementById(ACCESS_LAYER_ID);
      if (layer && (!layer.children || layer.children.length === 0)) layer.remove();
    }
  }

  // The main titlebar contains a flexible spacer between the root menu
  // and Steam's account/download/window-control cluster. A body-fixed fallback
  // at a hard-coded right offset lands directly over the dynamic download
  // indicator. Prefer the widest sibling in that titlebar row: even when a
  // theme puts content inside the spacer, the collision scan can still use its
  // genuinely free portion.
  function findFallbackHost(found) {
    found = found || findMenubar();
    var bar = found && found.bar, parent = bar && bar.parentElement;
    if (!parent || !parent.children || typeof bar.getBoundingClientRect !== "function") return null;
    var kids = Array.from(parent.children), barIndex = kids.indexOf(bar);
    var barRect = bar.getBoundingClientRect(), best = null, bestWidth = 0;
    for (var i = barIndex + 1; i < kids.length; i++) {
      var node = kids[i];
      if (!node || typeof node.getBoundingClientRect !== "function") continue;
      var rect = node.getBoundingClientRect();
      var overlapsRow = rect.height > 0 && rect.y < barRect.y + barRect.height &&
        rect.y + rect.height > barRect.y;
      if (overlapsRow && rect.width >= 40 && rect.width > bestWidth) {
        best = node; bestWidth = rect.width;
      }
    }
    if (best) lastFallbackHost = best;
    return best;
  }

  function setFallbackPosition(btn, left, top) {
    btn.style.setProperty("left", Math.round(left) + "px", "important");
    btn.style.setProperty("right", "auto", "important");
    btn.style.setProperty("top", Math.round(top) + "px", "important");
  }

  function freeHostHit(hit, host) {
    if (!hit) return false;
    if (hit === host || (hit.contains && hit.contains(host))) return true;
    if (!host.contains || !host.contains(hit)) return false;

    // Empty structural wrappers inside the spacer are harmless, but a theme
    // may also put icon-only controls there. Reject semantic controls, text,
    // pointer cursors and compact hit boxes without knowing any theme classes.
    for (var node = hit; node && node !== host; node = node.parentElement) {
      var tag = String(node.tagName || "").toLowerCase();
      var role = node.getAttribute ? node.getAttribute("role") : "";
      var tab = node.getAttribute ? node.getAttribute("tabindex") : null;
      if (tag === "button" || tag === "a" || tag === "input" || tag === "select" ||
          role === "button" || role === "menuitem" || (tab !== null && tab !== "-1") ||
          (node.textContent || "").trim() !== "") return false;
      try {
        if (getComputedStyle(node).cursor === "pointer") return false;
      } catch (e) {}
      var rect = node.getBoundingClientRect ? node.getBoundingClientRect() : null;
      if (rect && rect.width > 0 && rect.height > 0 && rect.width <= 96 && rect.height <= 64)
        return false;
    }
    return true;
  }

  function fallbackPositionSafe(btn, host, left, top) {
    if (!document.elementFromPoint) return true;
    setFallbackPosition(btn, left, top);
    var oldPointer = btn.style.getPropertyValue("pointer-events");
    var oldPriority = btn.style.getPropertyPriority("pointer-events");
    btn.style.setProperty("pointer-events", "none", "important");
    var inset = 3, size = 32;
    var points = [
      [left + size / 2, top + size / 2],
      [left + inset, top + inset], [left + size - inset, top + inset],
      [left + inset, top + size - inset], [left + size - inset, top + size - inset],
      [left + size / 2, top + inset], [left + size / 2, top + size - inset],
      [left + inset, top + size / 2], [left + size - inset, top + size / 2]
    ];
    var safe = true;
    for (var i = 0; i < points.length; i++) {
      if (!freeHostHit(document.elementFromPoint(points[i][0], points[i][1]), host)) {
        safe = false;
        break;
      }
    }
    if (oldPointer) btn.style.setProperty("pointer-events", oldPointer, oldPriority);
    else btn.style.removeProperty("pointer-events");
    return safe;
  }

  function placeFallbackButton(btn, host) {
    if (!btn || !host || !nodeIsConnected(host)) return false;
    var rect = host.getBoundingClientRect();
    if (!rect || rect.width < 40 || rect.height <= 0) return false;
    fallbackHost = host;
    lastFallbackHost = host;
    var size = 32, gap = 4;
    var minLeft = rect.left + gap;
    var maxLeft = rect.right - size - gap;
    if (maxLeft < minLeft) return false;
    var top = rect.top + Math.max(0, (rect.height - size) / 2);
    var candidates = [maxLeft];
    var parent = host.parentElement;

    // Fixed/absolute controls can visually overlap the flex spacer without
    // affecting its layout. Their actual edges are useful fast candidates;
    // elementFromPoint below remains the final authority.
    if (parent && parent.children) {
      Array.from(parent.children).forEach(function (node) {
        if (node === host || !node.getBoundingClientRect) return;
        var other = node.getBoundingClientRect();
        if (!other || other.width <= 0 || other.height <= 0 ||
            other.bottom <= top || other.top >= top + size) return;
        candidates.push(other.left - size - gap, other.right + gap);
      });
    }
    candidates = candidates.filter(function (left, index, all) {
      return left >= minLeft && left <= maxLeft &&
        all.findIndex(function (other) { return Math.abs(other - left) < 1; }) === index;
    }).sort(function (a, b) { return b - a; });

    for (var i = 0; i < candidates.length; i++) {
      if (fallbackPositionSafe(btn, host, candidates[i], top)) return true;
    }
    // Boundary candidates handle normal layouts. This bounded scan is only a
    // fallback for controls nested in unusual wrappers and runs on titlebar
    // changes, never per frame.
    for (var left = maxLeft; left >= minLeft; left -= 8) {
      if (fallbackPositionSafe(btn, host, left, top)) return true;
    }
    setFallbackPosition(btn, minLeft, top);
    return false;
  }

  function currentFallbackPositionSafe(btn, host) {
    if (!btn || !host || !nodeIsConnected(host)) return false;
    var rect = btn.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0 &&
      fallbackPositionSafe(btn, host, rect.left, rect.top);
  }

  function scheduleFallbackPosition() {
    if (fallbackPositionTimer) return;
    fallbackPositionTimer = setTimeout(function () {
      fallbackPositionTimer = null;
      var btn = document.getElementById(BTN_ID);
      if (btn && btn.classList.contains("lumen-fallback") && fallbackHost)
        placeFallbackButton(btn, fallbackHost);
    }, 0);
  }

  function watchFallbackHost(host) {
    stopFallbackObservers();
    var root = host && host.parentElement;
    if (!root) return;
    fallbackMutationObserver = new MutationObserver(scheduleFallbackPosition);
    try {
      fallbackMutationObserver.observe(root, {
        childList: true, subtree: true, characterData: true, attributes: true,
        attributeFilter: ["class", "style", "hidden"]
      });
    } catch (e) {}
    if (typeof ResizeObserver !== "undefined") {
      try {
        fallbackResizeObserver = new ResizeObserver(scheduleFallbackPosition);
        fallbackResizeObserver.observe(host);
        Array.from(root.children || []).forEach(function (node) {
          fallbackResizeObserver.observe(node);
        });
      } catch (e) {
        if (fallbackResizeObserver) fallbackResizeObserver.disconnect();
        fallbackResizeObserver = null;
      }
    }
  }

  function ensureFallbackButton(found) {
    var old = document.getElementById(BTN_ID);
    if (old) removeAccessButton(old);
    injectStyles();
    var btn = makeButton();
    btn.classList.add("lumen-fallback");
    btn.innerHTML = MOON_SVG;
    rememberPlacement(btn, "fallback");
    var host = findFallbackHost(found);
    if (!host && nodeIsConnected(lastFallbackHost)) host = lastFallbackHost;
    var layer = ensureAccessLayer();
    layer.appendChild(btn);
    if (host) {
      host.classList.add("lumen-fallback-host");
      btn.classList.add("lumen-fallback-slot");
      placeFallbackButton(btn, host);
      watchFallbackHost(host);
    } else {
      setFallbackPosition(btn, 4, 4);
    }
  }

  var observer = null;
  function startObserver(bar) {
    if (observer) observer.disconnect();
    // Scoped to the menubar node ONLY (never document.body) so it's cheap and
    // re-adds the button if React reconciles the bar and drops our child.
    observer = new MutationObserver(function () {
      if (!document.getElementById(BTN_ID)) {
        var f = findMenubar();
        if (f) {
          if (accessPlacementMode === "fallback" || currentThemeKey())
            ensureFallbackButton(f);
          else ensureButton(f);
        }
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
      // Custom themes always use the isolated access layer from their first
      // frame. The default Steam UI keeps the native Help-side placement.
      if (currentThemeKey()) ensureFallbackButton(f);
      else ensureButton(f);
      startObserver(f.bar);
      startAccessWatchdog();
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

  var missingChecks = 0;
  var accessWatchdogStarted = false;
  function startAccessWatchdog() {
    if (accessWatchdogStarted) return;
    accessWatchdogStarted = true;
    function checkAccess() {
      var btn = document.getElementById(BTN_ID);
      var obstructed = false;
      // Our full-screen overlay intentionally sits above the native button.
      // It is not loss of access: closing the overlay exposes the same button.
      if (document.getElementById(OVERLAY_ID)) {
        missingChecks = 0;
        setTimeout(checkAccess, 2000);
        return;
      }
      // Theme changes are the only normal reset boundary. Choose the new
      // theme's final placement immediately: custom themes go straight to the
      // isolated fallback layer, while Steam's default returns beside Help.
      // This avoids the old native-for-one-cycle -> fallback jump.
      var themeKey = currentThemeKey();
      if (accessPlacementTheme !== null && accessPlacementTheme !== themeKey) {
        var restored = findMenubar();
        if (btn) removeAccessButton(btn);
        lastFallbackHost = null;
        if (themeKey) ensureFallbackButton(restored);
        else if (restored) ensureButton(restored);
        else ensureFallbackButton();
        if (restored) startObserver(restored.bar);
        missingChecks = 0;
        setTimeout(checkAccess, 2000);
        return;
      }
      if (btn && btn.classList.contains("lumen-fallback") && fallbackHost &&
          !currentFallbackPositionSafe(btn, fallbackHost)) {
        placeFallbackButton(btn, fallbackHost);
      }
      if (btn) {
        // A native Help-side anchor remains where it was selected for this
        // theme session. Popups and theme transitions routinely make
        // elementFromPoint report another composited surface for one or two
        // checks; moving the button in response is both visible and wrong.
        if (accessPlacementMode === "native" && nodeIsConnected(btn)) {
          missingChecks = 0;
          setTimeout(checkAccess, 2000);
          return;
        }
        var cs = getComputedStyle(btn), rect = btn.getBoundingClientRect();
        var hit = null;
        if (rect.width > 0 && rect.height > 0 && document.elementFromPoint) {
          hit = document.elementFromPoint(rect.left + rect.width / 2,
                                          rect.top + rect.height / 2);
        }
        var reachable = !document.elementFromPoint || hit === btn || btn.contains(hit);
        if (cs.display !== "none" && cs.visibility !== "hidden" &&
            Number(cs.opacity || 1) > 0 && rect.width > 0 && rect.height > 0 && reachable) {
          missingChecks = 0;
          setTimeout(checkAccess, 2000);
          return;
        }
        obstructed = true;
        removeAccessButton(btn);
      }
      missingChecks++;
      var found = findMenubar();
      if (found && !obstructed) {
        if (accessPlacementMode === "fallback" || themeKey) ensureFallbackButton(found);
        else ensureButton(found);
        startObserver(found.bar);
        missingChecks = 0;
      } else {
        // A destroyed native menubar is the exceptional case where keeping the
        // old position is impossible. Give React two reconciliation cycles,
        // then preserve access via the fallback layer.
        if (missingChecks >= 3 || obstructed) {
          ensureFallbackButton(found);
          missingChecks = 0;
        }
      }
      setTimeout(checkAccess, 2000);
    }
    setTimeout(checkAccess, 2000);
  }

  // Only anchor the menubar button in the main client shell. This script is
  // ALSO injected into the store/community web views (so the overlay can render
  // on top of them), but those have no Steam menubar — and their own page nav
  // can contain text matching our labels, which made findMenubar() inject a
  // stray moon button into the page header (the "gap" bug). In a web view we
  // only need the overlay globals, already exposed above; skip the button.
  var __lumenHost = (typeof location !== "undefined" && location.hostname) || "";
  if (window.__lumenBrowserTarget === true) {
    var reportBrowserVisibility = function () {
      call("__lumenViewVisibility", { visible: !document.hidden }).catch(function () {});
    };
    document.addEventListener("visibilitychange", reportBrowserVisibility);
    reportBrowserVisibility();
  }
  if (window.__lumenShellTarget === false || __lumenHost === "store.steampowered.com" ||
      __lumenHost === "steamcommunity.com") {
    log("web view (" + __lumenHost + "): overlay-only, no menubar button");
  } else {
    tryAnchor();
  }
  log("loaded");
})();
