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
  // Close is TWO steps, and the order matters.
  //
  // The sidecar runs one thread: a backend call occupies it until it returns (a
  // fixes-catalogue fetch can hold it for its full 20s HTTP timeout), and the
  // __lumenClose relay is dispatched from the same loop. So a close that only
  // asked the sidecar sat behind whatever the open tab was loading — the window
  // stayed on screen for the rest of the load and only then vanished. Worse,
  // every extra click on the X queued another relay, and those stale closes
  // landed later, shutting the window again after the user had reopened it.
  //
  // So the visible window is removed HERE, synchronously, and the relay is only
  // the fan-out that clears the duplicate overlays living in the other injected
  // contexts. It carries no user-visible latency, so one in flight is enough.
  var _closePending = false;
  function requestClose() {
    closeOverlay();
    if (_closePending) return;
    _closePending = true;
    var done = function () { _closePending = false; };
    call("__lumenClose").then(done, done);
  }
  // Open still goes through the sidecar: it targets whichever view is on top,
  // and the menubar we were clicked from may be behind a store/community web
  // view. Opening locally would render the window into a hidden context.
  var _openPending = false;
  function requestOpen() {
    if (_openPending) return;
    _openPending = true;
    var done = function () { _openPending = false; };
    call("__lumenOpen").then(done, done);
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

