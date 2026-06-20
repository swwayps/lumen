// LM-FRAGMENT open/close relays + addLine() helper
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

  // ── settings overlay (lazy) ────────────────────────────────────────────────
  // Local close — just removes this context's overlay. Exposed as
  // window.__lumenCloseOverlay so the sidecar can close it across all contexts.
  function closeOverlay() {
    var o = document.getElementById(OVERLAY_ID);
    if (o) o.remove();
    if (_escHandler) {
      document.removeEventListener("keydown", _escHandler, true);
      _escHandler = null;
    }
  }
  // Ask the sidecar to close the overlay in EVERY context (the visible one and
  // the hidden duplicates in the other views).
  function requestClose() {
    call("__lumenClose").catch(function () {});
  }
  // Ask the sidecar to open the overlay in every context, so whichever view is
  // currently on top shows it (the menubar button lives in the main window, but
  // the active view may be a store/community web view composited above it).
  function requestOpen() {
    call("__lumenOpen").catch(function () {});
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

