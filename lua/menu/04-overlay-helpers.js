// LM-FRAGMENT open/close relays + addLine() helper
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

  // ── settings overlay (lazy) ────────────────────────────────────────────────
  // Local close — just removes this context's overlay. Exposed as
  // window.__lumenCloseOverlay so the sidecar can close it across all contexts.
  function closeOverlay() {
    if (_settingsFocusTrap) { _settingsFocusTrap(); _settingsFocusTrap = null; }
    var o = document.getElementById(OVERLAY_ID);
    if (o) o.remove();
    if (_escHandler) {
      document.removeEventListener("keydown", _escHandler, true);
      _escHandler = null;
    }
  }
  // Relays are coalesced by time, never by "is one still in flight". Gating on
  // the reply looks tidier but wedges the UI: the sidecar answers over a CDP
  // evaluate, and a context recreation (webhelper restart, navigation) can drop
  // that answer — after which an in-flight flag never clears and the menubar
  // button stops responding for the rest of the session. A window only has to
  // swallow the burst from a double-click.
  var RELAY_COALESCE_MS = 250;
  var _lastRelay = {};
  function relay(fn) {
    var now = Date.now();
    if (now - (_lastRelay[fn] || 0) < RELAY_COALESCE_MS) return;
    _lastRelay[fn] = now;
    call(fn).catch(function () {});
  }

  // Close is TWO steps, and the order matters.
  //
  // The sidecar runs one thread: a backend call occupies it until it returns (a
  // fixes-catalogue fetch can hold it for its full 20s HTTP timeout), and the
  // __lumenClose relay is dispatched from the same loop. So a close that only
  // asked the sidecar sat behind whatever the open tab was loading — the window
  // stayed on screen for the rest of the load and only then vanished.
  //
  // So the visible window is removed HERE, synchronously, and the relay is only
  // the fan-out that clears the duplicate overlays living in the other injected
  // contexts (none of them visible, or we would not have been the one clicked).
  function requestClose() {
    closeOverlay();
    relay("__lumenClose");
  }
  // Open still goes through the sidecar: it targets whichever view is on top,
  // and the menubar we were clicked from may be behind a store/community web
  // view. Opening locally would render the window into a hidden context.
  function requestOpen() {
    relay("__lumenOpen");
  }

  // Steam's Gamepad UI keeps its focus controller in SharedJSContext. The
  // visible Big Picture shell is opened by that context, so reach the same
  // controller through window.opener and register a real modal nav tree, just
  // like LuaTools does for its own overlays. A plain DOM focus() is not enough:
  // Steam handles D-pad/arrow input before document listeners and otherwise
  // moves the focus behind the overlay.
  var _lumenModalNavSequence = 0;
  var LUMEN_GAMEPAD_FOCUS_SOURCE = 0;
  var LUMEN_GAMEPAD_DIRECTION = { UP: 9, DOWN: 10, LEFT: 11, RIGHT: 12 };

  function modalFocusController() {
    var candidates = [];
    try { candidates.push(window.FocusNavController); } catch (_) {}
    try {
      candidates.push(window.GamepadNavTree
        && window.GamepadNavTree.m_context
        && window.GamepadNavTree.m_context.m_controller);
    } catch (_) {}
    try { candidates.push(window.opener && window.opener.FocusNavController); }
    catch (_) {}
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i]
          && typeof candidates[i].NewGamepadNavigationTree === "function") {
        return candidates[i];
      }
    }
    return null;
  }

  function modalFocusContext(controller) {
    var getters = [
      function () {
        return typeof controller.GetActiveContext === "function"
          ? controller.GetActiveContext() : null;
      },
      function () {
        return typeof controller.FindAnActiveContext === "function"
          ? controller.FindAnActiveContext() : null;
      },
      function () { return controller.m_ActiveContext || null; },
      function () { return controller.m_LastActiveContext || null; },
    ];
    for (var i = 0; i < getters.length; i++) {
      try {
        var context = getters[i]();
        if (context) return context;
      } catch (_) {}
    }
    return null;
  }

  function visibleModalAction(element) {
    if (!element || element.isConnected === false || element.disabled) return false;
    try {
      var rect = element.getBoundingClientRect();
      if (!rect || rect.width <= 0 || rect.height <= 0) return false;
      var style = typeof window.getComputedStyle === "function"
        ? window.getComputedStyle(element) : null;
      return !style || (style.display !== "none"
        && style.visibility !== "hidden" && style.opacity !== "0");
    } catch (_) { return false; }
  }

  function consumeModalInput(event) {
    event.preventDefault();
    if (typeof event.stopImmediatePropagation === "function") {
      event.stopImmediatePropagation();
    } else if (typeof event.stopPropagation === "function") {
      event.stopPropagation();
    }
  }

  // A focused text field must keep the "activate" input (the space bar and
  // Enter, which Steam's controller maps to gamepad button 1). Treating that as
  // "click the control" swallowed the space bar, so the Add-game and Fixes
  // search boxes could never take a two-word query like "crimson desert".
  // Directional input is left alone so the D-pad can still move off the field.
  function isTextEntryElement(element) {
    if (!element) return false;
    try {
      if (element.isContentEditable === true) return true;
      var tag = element.tagName;
      if (tag === "TEXTAREA") return true;
      if (tag !== "INPUT") return false;
      var type = element.type
        || (typeof element.getAttribute === "function"
          ? element.getAttribute("type") : "")
        || "text";
      type = String(type).toLowerCase();
      return type === "text" || type === "search" || type === "email"
        || type === "url" || type === "tel" || type === "password"
        || type === "number";
    } catch (_) { return false; }
  }

  // Keep exactly one visible selection inside a modal, mirroring the node that
  // Steam considers focused.
  function paintModalFocus(navigation, element) {
    navigation.elements.forEach(function (candidate) {
      candidate.classList.remove("active-focus");
    });
    if (element) element.classList.add("active-focus");
  }

  function directionalModalAction(elements, currentIndex, button) {
    var currentRect = elements[currentIndex].getBoundingClientRect();
    var currentX = (currentRect.left + currentRect.right) / 2;
    var currentY = (currentRect.top + currentRect.bottom) / 2;
    var bestIndex = -1;
    var bestScore = Infinity;
    for (var i = 0; i < elements.length; i++) {
      if (i === currentIndex) continue;
      var rect = elements[i].getBoundingClientRect();
      var x = (rect.left + rect.right) / 2;
      var y = (rect.top + rect.bottom) / 2;
      var primary;
      var perpendicular;
      var overlaps;
      if (button === LUMEN_GAMEPAD_DIRECTION.UP && y < currentY) {
        primary = currentY - y; perpendicular = Math.abs(currentX - x);
        overlaps = rect.left < currentRect.right && rect.right > currentRect.left;
      } else if (button === LUMEN_GAMEPAD_DIRECTION.DOWN && y > currentY) {
        primary = y - currentY; perpendicular = Math.abs(currentX - x);
        overlaps = rect.left < currentRect.right && rect.right > currentRect.left;
      } else if (button === LUMEN_GAMEPAD_DIRECTION.LEFT && x < currentX) {
        primary = currentX - x; perpendicular = Math.abs(currentY - y);
        overlaps = rect.top < currentRect.bottom && rect.bottom > currentRect.top;
      } else if (button === LUMEN_GAMEPAD_DIRECTION.RIGHT && x > currentX) {
        primary = x - currentX; perpendicular = Math.abs(currentY - y);
        overlaps = rect.top < currentRect.bottom && rect.bottom > currentRect.top;
      } else {
        continue;
      }
      var score = primary + perpendicular * (overlaps ? 0.25 : 3);
      if (score < bestScore) { bestScore = score; bestIndex = i; }
    }
    if (bestIndex >= 0) return bestIndex;
    var backwards = button === LUMEN_GAMEPAD_DIRECTION.UP
      || button === LUMEN_GAMEPAD_DIRECTION.LEFT;
    return (currentIndex + (backwards ? -1 : 1) + elements.length)
      % elements.length;
  }

  // Which descendants of an overlay can hold gamepad focus. The guard modals
  // only expose buttons, but the settings window and the Fixes Menu are built
  // from tabs, tiles and rows that are divs with a click handler, so callers
  // pass their own selector.
  var LUMEN_MODAL_ACTION_SELECTOR = "button.focusable:not([disabled])";
  // The settings window and the Fixes Menu build their controls as divs and
  // buttons with click handlers rather than one focusable button class.
  var LUMEN_OVERLAY_ACTION_SELECTOR = [
    "button:not([disabled])",
    "input:not([disabled])",
    "select:not([disabled])",
    ".lumen-tab",
    ".lumen-account-entry",
    ".lumen-account-back",
    ".lumen-x",
    ".lumen-fx-tile",
    ".lumen-fx-btn",
    ".lumen-fx-x",
    '[role="button"]',
    '[tabindex="0"]',
  ].join(", ");
  var _settingsFocusTrap = null;

  // Attach (or replace) the settings window's gamepad focus scope.
  function setSettingsFocusTrap(overlay, onBack) {
    if (_settingsFocusTrap) { _settingsFocusTrap(); _settingsFocusTrap = null; }
    if (!overlay) return;
    _settingsFocusTrap = trapModalFocus(overlay, onBack, {
      selector: LUMEN_OVERLAY_ACTION_SELECTOR,
      preferFirst: true,
    });
  }

  function modalActionElements(overlay, selector) {
    return Array.prototype.slice.call(
      overlay.querySelectorAll(selector || LUMEN_MODAL_ACTION_SELECTOR))
      .filter(visibleModalAction);
  }

  // Register a single element (the Fixes Menu entry) as a focusable sibling in
  // Steam's EXISTING navigation tree, so the D-pad reaches it from the Play row
  // instead of skipping over it. Unlike a modal, this joins the page's own tree:
  // it must not trap focus. Returns a cleanup function, or null when Steam's
  // controller is unavailable (Desktop Mode).
  function registerNativeInlineFocus(element) {
    var controller = modalFocusController();
    var context = controller && modalFocusContext(controller);
    if (!context || !element) return null;

    function deepestNodeContaining(node, target) {
      if (!node) return null;
      var match = null;
      try {
        if (node.m_element && node.m_element.contains(target)) match = node;
      } catch (_) {}
      var children = node.m_rgChildren || [];
      for (var i = 0; i < children.length; i++) {
        var childMatch = deepestNodeContaining(children[i], target);
        if (childMatch) match = childMatch;
      }
      return match;
    }

    var trees = Array.from(context.m_rgGamepadNavigationTrees || []);
    var owner = null;
    for (var i = 0; i < trees.length && !owner; i++) {
      var parentNode = deepestNodeContaining(
        trees[i].Root || trees[i].m_Root, element);
      if (parentNode) owner = { tree: trees[i], parentNode: parentNode };
    }
    if (!owner) return null;

    try {
      var node = owner.tree.CreateNode(owner.parentNode);
      node.SetProperties({ focusable: true, actionDescriptionMap: {} });
      var unregister = owner.tree.RegisterNavigationItem(node, element);
      // A div only receives DOM focus events once it is a tab stop, and Steam's
      // BTakeFocus marks its own node without touching the DOM. Give the entry a
      // tab stop and also mirror the node's state, so the ring shows up whether
      // focus arrives from the gamepad tree or from the DOM.
      var addedTabStop = false;
      if (!element.hasAttribute("tabindex")) {
        element.setAttribute("tabindex", "0");
        addedTabStop = true;
      }
      function onFocus() { element.classList.add("active-focus"); }
      function onBlur() { element.classList.remove("active-focus"); }
      // Steam moves focus between siblings without a DOM event on plain divs, so
      // poll the node's own flag while this page is alive. One boolean read per
      // frame-ish interval on a single element is negligible, and it stops as
      // soon as the entry is removed.
      var focusPoll = null;
      if (typeof setInterval === "function"
          && typeof node.BHasFocus === "function") {
        focusPoll = setInterval(function () {
          if (!element.isConnected) return;
          var focused = false;
          try { focused = node.BHasFocus() === true; } catch (_) {}
          if (focused === element.classList.contains("active-focus")) return;
          if (focused) element.classList.add("active-focus");
          else element.classList.remove("active-focus");
        }, 120);
      }
      function onButtonDown(event) {
        var detail = event.detail || {};
        if (Number(detail.button) !== 1 || detail.is_repeat) return;
        consumeModalInput(event);
        element.click();
      }
      function onButtonUp(event) {
        if (Number((event.detail || {}).button) === 1) consumeModalInput(event);
      }
      element.addEventListener("vgp_onbuttondown", onButtonDown);
      element.addEventListener("vgp_onbuttonup", onButtonUp);
      element.addEventListener("focus", onFocus);
      element.addEventListener("blur", onBlur);
      return function () {
        if (focusPoll !== null && typeof clearInterval === "function") {
          clearInterval(focusPoll);
        }
        element.removeEventListener("vgp_onbuttondown", onButtonDown);
        element.removeEventListener("vgp_onbuttonup", onButtonUp);
        element.removeEventListener("focus", onFocus);
        element.removeEventListener("blur", onBlur);
        element.classList.remove("active-focus");
        if (addedTabStop) element.removeAttribute("tabindex");
        try { unregister(); } catch (_) {}
      };
    } catch (_) {
      return null;
    }
  }

  function registerNativeModalFocus(overlay, onBack, preferredAction) {
    var options = (preferredAction && typeof preferredAction === "object")
      ? preferredAction : { action: preferredAction };
    var selector = options.selector || LUMEN_MODAL_ACTION_SELECTOR;
    var controller = modalFocusController();
    var context = controller && modalFocusContext(controller);
    var elements = modalActionElements(overlay, selector);
    if (!controller || !context || !elements.length) return null;

    var contextTrees = Array.from(context.m_rgGamepadNavigationTrees || []);
    var parentTree = null;
    try {
      parentTree = typeof controller.GetActiveNavTree === "function"
        ? controller.GetActiveNavTree() : null;
    } catch (_) {}
    parentTree = parentTree || context.m_LastActiveNavTree
      || context.m_LastActiveFocusNavTree || contextTrees[0] || null;
    if (!parentTree) return null;

    var tree = null;
    var unregisterTree = null;
    var unregisterRoot = null;
    var observer = null;
    var disposed = false;
    var items = new Map();

    function dispose() {
      if (disposed) return;
      disposed = true;
      if (observer) observer.disconnect();
      items.forEach(function (item) {
        try { item.unbind(); } catch (_) {}
        try { item.unregister(); } catch (_) {}
      });
      items.clear();
      try { if (unregisterRoot) unregisterRoot(); } catch (_) {}
      try { if (unregisterTree) unregisterTree(); } catch (_) {}
      dropTreeFromContext();
      // Steam adds the tree to its context set asynchronously, so a modal that
      // is closed immediately after opening would be dropped BEFORE Steam even
      // inserted it — leaving a stale modal tree behind that keeps competing
      // for gamepad focus. Sweep again on later ticks; the helper is idempotent.
      if (typeof setTimeout === "function") {
        setTimeout(dropTreeFromContext, 0);
        setTimeout(dropTreeFromContext, 250);
      }
    }

    // Remove this modal's tree from Steam's context. The controller's own
    // unregister callback does not reliably drop it from the tree set.
    function dropTreeFromContext() {
      if (!tree) return;
      try { tree.SetIsEnabled(false); } catch (_) {}
      try { if (typeof tree.Deactivate === "function") tree.Deactivate(); } catch (_) {}
      try {
        if (context
            && typeof context.UnregisterGamepadNavigationTree === "function") {
          context.UnregisterGamepadNavigationTree(tree);
        }
      } catch (_) {}
    }

    function bind(element, navigation) {
      function onFocus() {
        navigation.elements.forEach(function (candidate) {
          candidate.classList.remove("active-focus");
        });
        element.classList.add("active-focus");
      }
      function onBlur() { element.classList.remove("active-focus"); }
      // Steam's BTakeFocus marks its own node and only fires a DOM focus event
      // on natively focusable elements. The settings window and the Fixes Menu
      // are built from plain divs, so give them a tab stop and repaint the
      // highlight from the gamepad event itself — otherwise the modal has focus
      // with nothing visibly selected.
      if (element.tagName !== "BUTTON" && element.tagName !== "INPUT"
          && element.tagName !== "SELECT" && element.tagName !== "TEXTAREA"
          && !element.hasAttribute("tabindex")) {
        element.setAttribute("tabindex", "0");
        element.__lumenTabStop = true;
      }
      function onButtonDown(event) {
        var detail = event.detail || {};
        var button = Number(detail.button);
        if (button === 1) {
          if (detail.is_repeat) return;
          // Let a focused text field type the space bar / submit on Enter (or
          // open the on-screen keyboard on a real gamepad) instead of clicking.
          if (isTextEntryElement(element)) return;
          consumeModalInput(event); element.click(); return;
        }
        if (button === 2) {
          if (detail.is_repeat) return;
          consumeModalInput(event); onBack(); return;
        }
        if (button < LUMEN_GAMEPAD_DIRECTION.UP
            || button > LUMEN_GAMEPAD_DIRECTION.RIGHT) return;
        var currentIndex = navigation.elements.indexOf(element);
        if (currentIndex < 0) return;
        consumeModalInput(event);
        var nextIndex = directionalModalAction(
          navigation.elements, currentIndex, button);
        var next = navigation.items.get(navigation.elements[nextIndex]);
        if (next && next.node && typeof next.node.BTakeFocus === "function") {
          next.node.BTakeFocus(LUMEN_GAMEPAD_FOCUS_SOURCE, button);
          paintModalFocus(navigation, navigation.elements[nextIndex]);
        }
      }
      function onButtonUp(event) {
        var button = Number((event.detail || {}).button);
        // Mirror onButtonDown: leave the activate button alone on a text field.
        if (button === 1 && isTextEntryElement(element)) return;
        if (button === 1 || button === 2
            || (button >= LUMEN_GAMEPAD_DIRECTION.UP
              && button <= LUMEN_GAMEPAD_DIRECTION.RIGHT)) {
          consumeModalInput(event);
        }
      }
      element.addEventListener("vgp_onbuttondown", onButtonDown);
      element.addEventListener("vgp_onbuttonup", onButtonUp);
      element.addEventListener("focus", onFocus);
      element.addEventListener("blur", onBlur);
      return function () {
        element.removeEventListener("vgp_onbuttondown", onButtonDown);
        element.removeEventListener("vgp_onbuttonup", onButtonUp);
        element.removeEventListener("focus", onFocus);
        element.removeEventListener("blur", onBlur);
        element.classList.remove("active-focus");
        if (element.__lumenTabStop) {
          element.removeAttribute("tabindex");
          delete element.__lumenTabStop;
        }
      };
    }

    var navigation = { elements: [], items: items };
    function sync() {
      if (disposed) return;
      var next = modalActionElements(overlay, selector);
      items.forEach(function (item, element) {
        if (next.indexOf(element) >= 0 && element.isConnected !== false) return;
        try { item.unbind(); } catch (_) {}
        try { item.unregister(); } catch (_) {}
        items.delete(element);
      });
      next.forEach(function (element) {
        if (items.has(element)) return;
        var node = tree.CreateNode(tree.Root || tree.m_Root);
        node.SetProperties({ focusable: true, actionDescriptionMap: {} });
        items.set(element, {
          node: node,
          unregister: tree.RegisterNavigationItem(node, element),
          unbind: bind(element, navigation),
        });
      });
      navigation.elements = next;
    }

    // Give the selection to the preferred action, or to the first item when the
    // caller has no preference. Called on open AND whenever a later sync brings
    // in the first items: the Fixes Menu and the settings tabs render their
    // contents asynchronously, so the modal would otherwise sit focused with
    // nothing highlighted and the D-pad doing nothing.
    function focusPreferred() {
      if (disposed || !navigation.elements.length) return false;
      var preferred = null;
      for (var i = 0; i < navigation.elements.length; i++) {
        var candidate = navigation.elements[i];
        if (options.action && candidate.dataset
            && candidate.dataset.action === options.action) {
          preferred = candidate; break;
        }
      }
      preferred = preferred
        || (options.preferFirst
          ? navigation.elements[0]
          : navigation.elements[navigation.elements.length - 1]);
      var item = preferred && items.get(preferred);
      if (!item || typeof item.node.BTakeFocus !== "function") return false;
      item.node.BTakeFocus(LUMEN_GAMEPAD_FOCUS_SOURCE);
      paintModalFocus(navigation, preferred);
      return true;
    }

    try {
      tree = controller.NewGamepadNavigationTree(
        context, "LumenModal-" + (++_lumenModalNavSequence), parentTree,
        { virtualFocus: false, modal: true, historyMode: "none" });
      var root = tree.Root || tree.m_Root;
      root.SetProperties({ layout: 6, actionDescriptionMap: {} });
      unregisterRoot = tree.RegisterNavigationItem(root, overlay);
      sync();
      unregisterTree = typeof controller.RegisterGamepadNavigationTree === "function"
        ? controller.RegisterGamepadNavigationTree(tree, window) : null;
      tree.SetIsEnabled(true);
      tree.Activate(true);
      tree.TakeFocus(LUMEN_GAMEPAD_FOCUS_SOURCE);
      focusPreferred();
      if (typeof MutationObserver === "function") {
        observer = new MutationObserver(function () {
          if (!overlay.isConnected) { dispose(); return; }
          sync();
          // Nothing selected yet (contents arrived after the modal opened, or
          // the focused item was replaced by a re-render): take focus again.
          if (!overlay.querySelector(".active-focus")) focusPreferred();
        });
        observer.observe(overlay, { childList: true, subtree: true,
          attributes: true, attributeFilter: ["class", "style", "disabled", "hidden"] });
      }
      return dispose;
    } catch (_) {
      dispose();
      return null;
    }
  }

  // Desktop mode and older clients without Steam's native controller retain a
  // small DOM-only fallback. It is scoped to the open modal and fully removed
  // on close, so it adds no steady-state listener or polling overhead.
  function trapModalFocus(overlay, onBack, preferredAction) {
    var options = (preferredAction && typeof preferredAction === "object")
      ? preferredAction : { action: preferredAction };
    var selector = options.selector || LUMEN_MODAL_ACTION_SELECTOR;
    var nativeCleanup = registerNativeModalFocus(
      overlay, onBack, options);
    if (nativeCleanup) return nativeCleanup;
    var disposed = false;

    function buttons() {
      return Array.prototype.slice.call(overlay.querySelectorAll(selector));
    }

    function preferred(items) {
      for (var i = 0; i < items.length; i++) {
        if (options.action && items[i].dataset
            && items[i].dataset.action === options.action) return items[i];
      }
      if (options.preferFirst) return items[0] || null;
      return items[items.length - 1] || items[0] || null;
    }

    function focus(button) {
      if (!button) return false;
      try { button.focus({ preventScroll: true }); }
      catch (_) { try { button.focus(); } catch (_) { return false; } }
      return true;
    }

    function consume(event) {
      event.preventDefault();
      if (typeof event.stopImmediatePropagation === "function") {
        event.stopImmediatePropagation();
      } else if (typeof event.stopPropagation === "function") {
        event.stopPropagation();
      }
    }

    function onKeydown(event) {
      if (disposed || !overlay.parentElement) return;
      var key = event.key;
      if (key === "Escape" || key === "BrowserBack") {
        consume(event);
        onBack();
        return;
      }

      var items = buttons();
      if (!items.length) return;
      var active = document.activeElement;
      var index = items.indexOf(active);
      // A focused text field keeps the arrows (caret) plus space/Enter (typing
      // and submit); only Tab still steps between the modal's controls so the
      // keyboard user can leave the field.
      var editable = isTextEntryElement(active);
      var backward = (key === "Tab" && event.shiftKey === true)
        || (!editable && (key === "ArrowLeft" || key === "ArrowUp"));
      var forward = (key === "Tab" && event.shiftKey !== true)
        || (!editable && (key === "ArrowRight" || key === "ArrowDown"));

      if (backward || forward) {
        consume(event);
        if (index < 0) {
          focus(preferred(items));
          return;
        }
        var delta = backward ? -1 : 1;
        focus(items[(index + delta + items.length) % items.length]);
        return;
      }

      if (!editable && (key === "Enter" || key === " " || key === "Spacebar")) {
        consume(event);
        if (index < 0) {
          focus(preferred(items));
        } else {
          active.click();
        }
      }
    }

    function onFocus(event) {
      if (disposed || !overlay.parentElement || overlay.contains(event.target)) return;
      focus(preferred(buttons()));
    }

    document.addEventListener("keydown", onKeydown, true);
    document.addEventListener("focusin", onFocus, true);
    focus(preferred(buttons()));
    setTimeout(function () {
      if (!disposed && overlay.parentElement
          && !overlay.contains(document.activeElement)) focus(preferred(buttons()));
    }, 0);

    return function () {
      if (disposed) return;
      disposed = true;
      document.removeEventListener("keydown", onKeydown, true);
      document.removeEventListener("focusin", onFocus, true);
    };
  }

  // Append an info/warning line (icon + text) with the given severity class.
  function addLine(wrap, text, cls, icon) {
    var w = document.createElement("div");
    w.className = "lumen-line " + cls;
    var ic = document.createElement("span");
    ic.className = "i";
    ic.textContent = icon;
    var tx = document.createElement("span");
    tx.textContent = text;
    w.appendChild(ic); w.appendChild(tx);
    wrap.appendChild(w);
  }
