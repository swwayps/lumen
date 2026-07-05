// LM-FRAGMENT "slsteam-moon not loaded" warning modal + one-shot boot check
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

  // ── "slsteam-moon didn't load" warning ───────────────────────────────────────
  // The moment the moon button anchors in the main client shell (Steam finished
  // loading), ask the backend whether SLSsteam.so is actually mapped into the
  // running Steam client. If it isn't, this session is UN-injected: LuaTools
  // games show a "Buy" button and won't install/launch. We surface a one-shot
  // modal offering an auto-fix (reinstall latest slsteam-moon + repair the
  // *steam*.desktop launchers + relaunch Steam injected). If slsteam-moon IS
  // loaded, we stay silent and boot proceeds normally.
  //
  // Shown once per session (window.__lumenSlsWarned) and only from the shell
  // branch of the menubar bootstrap (never the store/community web views).

  // A small acknowledgement modal (title + pre-wrapped body + one OK button),
  // reusing the shared confirm-modal styling.
  function slsAck(title, body, okLabel) {
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
    b.style.whiteSpace = "pre-line";
    b.textContent = body || "";
    var row = document.createElement("div");
    row.className = "mrow";
    var close = function () { if (back.parentNode) back.remove(); };
    var ok = document.createElement("button");
    ok.className = "lumen-mbtn primary";
    ok.textContent = okLabel || "OK";
    ok.addEventListener("click", function (e) { e.stopPropagation(); close(); });
    back.addEventListener("click", function (e) { if (e.target === back) close(); });
    row.appendChild(ok);
    card.appendChild(t); card.appendChild(b); card.appendChild(row);
    back.appendChild(card);
    (document.body || document.documentElement).appendChild(back);
  }

  // Kick off the auto-fix: the backend opens a terminal running autofix.sh. On
  // success show the "running" note; on failure show the manual command / error.
  function runSlsAutofix() {
    var S = slsStrings();
    call("RunSlsAutofix", {})
      .then(function (res) {
        var r = JSON.parse(res);
        if (r && r.success) {
          slsAck(S.openedTitle, S.openedBody, S.ok);
        } else {
          var err = (r && r.error) || "";
          var body = /terminal/i.test(err) ? S.noTerm : (S.fail + err);
          slsAck(S.title, body, S.ok);
        }
      })
      .catch(function (e) {
        slsAck(S.title, S.fail + (e && e.message ? e.message : e), S.ok);
      });
  }

  // The warning modal itself: title, two body paragraphs, and two buttons —
  // "Ignore" (dismiss) and the primary "Auto-fix".
  function showSlsWarn() {
    // Only ever one warning at a time (the injector may broadcast to the on-top
    // context; guard so a re-broadcast can't stack modals).
    if (document.getElementById("lumen-sls-warn")) return;
    var S = slsStrings();
    injectStyles();
    var back = document.createElement("div");
    back.id = "lumen-sls-warn";
    back.className = "lumen-modal-back";
    var card = document.createElement("div");
    card.className = "lumen-modal";

    var t = document.createElement("div");
    t.className = "mt";
    t.textContent = S.title;

    var b1 = document.createElement("div");
    b1.className = "mb";
    b1.style.marginBottom = "10px";
    b1.textContent = S.body1;
    var b2 = document.createElement("div");
    b2.className = "mb";
    b2.textContent = S.body2;

    var row = document.createElement("div");
    row.className = "mrow";
    var close = function () { if (back.parentNode) back.remove(); };

    var ignore = document.createElement("button");
    ignore.className = "lumen-mbtn";
    ignore.textContent = S.ignore;
    ignore.addEventListener("click", function (e) { e.stopPropagation(); close(); });

    var fix = document.createElement("button");
    fix.className = "lumen-mbtn primary";
    fix.textContent = S.autofix;
    fix.addEventListener("click", function (e) {
      e.stopPropagation();
      close();
      runSlsAutofix();
    });

    back.addEventListener("click", function (e) { if (e.target === back) close(); });
    row.appendChild(ignore); row.appendChild(fix);
    card.appendChild(t); card.appendChild(b1); card.appendChild(b2); card.appendChild(row);
    back.appendChild(card);
    (document.body || document.documentElement).appendChild(back);
  }

  // One-shot: ask the backend whether slsteam-moon is loaded; warn if not.
  // Guarded so re-injection (CDP context recreation) doesn't re-warn. The warn
  // is BROADCAST (not shown locally) so it renders in whichever view is on top:
  // the store/community web view composites above the shell, so a shell-local
  // modal would sit hidden behind it. The injector fires window.__lumenShowSlsWarn
  // in the on-top context (see State:broadcast_sls_warn).
  function maybeWarnSlsNotLoaded() {
    if (window.__lumenSlsWarned) return;
    window.__lumenSlsWarned = true;
    call("GetSlsLoaded", {})
      .then(function (res) {
        var r = JSON.parse(res);
        if (r && r.success && r.loaded === false) {
          call("__lumenSlsWarn", {}).catch(function () {
            // Broadcast failed — fall back to a local render so the user still
            // sees it (may be behind the store, but better than nothing).
            showSlsWarn();
          });
        }
      })
      .catch(function () {
        // Backend unreachable — say nothing (can't confirm a problem).
      });
  }

  // Live-introspectable over CDP like the other window.__lumen* helpers.
  try { window.__lumenShowSlsWarn = showSlsWarn; } catch (e) {}
