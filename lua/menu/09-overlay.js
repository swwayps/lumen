// LM-FRAGMENT settings window/overlay (openOverlay) + window.__lumen* exposure
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

  function openOverlay() {
    if (document.getElementById(OVERLAY_ID)) return;
    injectStyles();
    applyAdaptivePalette();
    var S0 = I18N[pickLang()] || I18N.en;

    var overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;
    overlay.addEventListener("click", function (e) {
      if (e.target === overlay) requestClose();
    });

    var win = document.createElement("div");
    win.className = "lumen-win";

    // sidebar
    var side = document.createElement("div");
    side.className = "lumen-side";
    var sTitle = document.createElement("div");
    sTitle.className = "lumen-side-title";
    sTitle.textContent = "Lumen";
    side.appendChild(sTitle);

    function mkTab(label, svg) {
      var t = document.createElement("div");
      t.className = "lumen-tab";
      var i = document.createElement("span");
      i.className = "ico";
      i.innerHTML = svg;
      var l = document.createElement("span");
      l.textContent = label;
      t.appendChild(i); t.appendChild(l);
      side.appendChild(t);
      return t;
    }
    var tabSls = mkTab("slsteam-moon", MOON_SVG);
    var tabGu = mkTab(guStrings().tab, GU_SVG);
    // Cloud Saves tab only when CloudRedirect is installed (window.__lumenCloud,
    // set by boot.lua). Absent -> the tab isn't created and nothing cloud runs.
    var tabCloud = window.__lumenCloud ? mkTab(cloudStrings().tab, CLOUD_SVG) : null;
    var tabThemes = mkTab(themeStrings().tab, THEMES_SVG);
    var tabAbout = mkTab(((I18N[pickLang()] || I18N.en).about || I18N.en.about).tab, ABOUT_SVG);

    // content
    var content = document.createElement("div");
    content.className = "lumen-content";
    var ctop = document.createElement("div");
    ctop.className = "lumen-ctop";
    var h = document.createElement("div");
    h.className = "h";
    var x = document.createElement("div");
    x.className = "x";
    x.textContent = "\u2715";
    x.addEventListener("click", requestClose);

    // Reset-to-defaults button: header-right (slsteam-moon tab only). Two-click
    // confirm so it can't fire by accident; on success the backend returns fresh
    // {schema,values} and we re-render the tab in place.
    var resetBtn = document.createElement("div");
    resetBtn.className = "reset";
    resetBtn.textContent = S0.reset || "Reset to defaults";
    var armed = false, armTimer = null;
    var disarm = function () {
      armed = false;
      if (armTimer) { clearTimeout(armTimer); armTimer = null; }
      resetBtn.classList.remove("confirm");
      resetBtn.textContent = S0.reset || "Reset to defaults";
    };
    resetBtn.addEventListener("click", function () {
      if (!armed) {
        armed = true;
        resetBtn.classList.add("confirm");
        resetBtn.textContent = S0.resetConfirm || "Click again to confirm";
        armTimer = setTimeout(disarm, 3000);
        return;
      }
      disarm();
      call("ResetSlsConfig", {})
        .then(function (res) {
          var cfg = JSON.parse(res);
          if (!cfg || !cfg.success) throw new Error((cfg && cfg.error) || "reset failed");
          renderConfig(body, cfg);
        })
        .catch(function (e) {
          body.textContent = "";
          var err = document.createElement("div");
          err.className = "lumen-err";
          err.textContent = (S0.resetFail || "Reset failed: ") + (e && e.message ? e.message : e);
          body.appendChild(err);
        });
    });

    // Native restart: available with or without the optional LuaTools plugin.
    // Confirmation is explicit because Steam and its open windows will close.
    var restartBtn = document.createElement("div");
    restartBtn.className = "reset lumen-restart";
    restartBtn.textContent = S0.restart || "Restart Steam";
    var restartPending = false;
    restartBtn.addEventListener("click", function () {
      if (restartPending) return;
      showConfirm({
        title: S0.restartTitle || "Restart Steam?",
        body: S0.restartBody || "Steam will close and reopen through slsteam-moon. Continue?",
        declineText: S0.restartCancel || "Cancel",
        confirmText: S0.restartConfirm || "Restart Steam",
        onConfirm: function () {
          if (restartPending) return;
          restartPending = true;
          call("RestartSteam", {})
            .then(function (res) {
              var result = typeof res === "string" ? JSON.parse(res) : res;
              if (!result || !result.success) {
                throw new Error((result && result.error) || "restart failed");
              }
            })
            .catch(function (e) {
              restartPending = false;
              showConfirm({
                title: S0.restartFailTitle || "Could not restart Steam",
                body: (S0.restartFail || "Restart failed: ")
                  + (e && e.message ? e.message : e),
                confirmText: (S0.about && S0.about.ok) || "OK",
              });
            });
        },
      });
    });

    // Clear-stored-versions button: header-right (Game Updates tab only). Drops
    // archived manifests EXCEPT installed/pinned ones; two-click confirm.
    var clearBtn = document.createElement("div");
    clearBtn.className = "reset";
    clearBtn.textContent = guStrings().clearManifests;
    clearBtn.title = guStrings().clearHint;
    clearBtn.style.display = "none";
    _guClearBtnRef = clearBtn;
    var carmed = false, carmTimer = null;
    var cdisarm = function () {
      carmed = false;
      if (carmTimer) { clearTimeout(carmTimer); carmTimer = null; }
      clearBtn.classList.remove("confirm");
      clearBtn.textContent = guStrings().clearManifests;
    };
    clearBtn.addEventListener("click", function () {
      if (!carmed) {
        carmed = true;
        clearBtn.classList.add("confirm");
        clearBtn.textContent = guStrings().clearConfirm;
        carmTimer = setTimeout(cdisarm, 3000);
        return;
      }
      cdisarm();
      call("ClearManifests", {})
        .then(function (res) {
          var r = JSON.parse(res);
          if (!r || !r.success) throw new Error((r && r.error) || "clear failed");
          renderGameUpdates(body);
        })
        .catch(function (e) {
          var er = document.createElement("div");
          er.className = "lumen-err";
          er.textContent = guStrings().clearFail + (e && e.message ? e.message : e);
          body.appendChild(er);
        });
    });

    ctop.appendChild(h); ctop.appendChild(clearBtn); ctop.appendChild(restartBtn); ctop.appendChild(resetBtn); ctop.appendChild(x);

    var body = document.createElement("div");
    body.className = "lumen-body";

    content.appendChild(ctop);
    content.appendChild(body);
    win.appendChild(side);
    win.appendChild(content);
    overlay.appendChild(win);
    (document.body || document.documentElement).appendChild(overlay);

    function loadSlsConfig() {
      body.textContent = "Loading\u2026";
      call("GetSlsConfig", {})
        .then(function (res) {
          var config = JSON.parse(res);
          if (!config || !config.success) throw new Error((config && config.error) || "load failed");
          renderConfig(body, config);
        })
        .catch(function (e) {
          body.textContent = "";
          var err = document.createElement("div");
          err.className = "lumen-err";
          err.textContent = "Failed to load slsteam-moon config: " + (e && e.message ? e.message : e);
          body.appendChild(err);
        });
    }

    // Tab switching: update active state, header title, reset-button visibility,
    // then render the tab's body.
    function selectTab(which) {
      disarm();
      cdisarm();
      tabSls.classList.toggle("active", which === "sls");
      tabGu.classList.toggle("active", which === "gu");
      if (tabCloud) tabCloud.classList.toggle("active", which === "cloud");
      tabThemes.classList.toggle("active", which === "themes");
      tabAbout.classList.toggle("active", which === "about");
      if (which === "gu") {
        h.textContent = "";
        var gt = document.createElement("span");
        gt.textContent = guStrings().title;
        h.appendChild(gt);
        var exp = document.createElement("span");
        exp.className = "lumen-exp";
        exp.textContent = guStrings().experimental;
        h.appendChild(exp);
        var info = document.createElement("span");
        info.className = "lumen-info";
        info.textContent = "i";
        info.title = guStrings().experimentalHint;
        h.appendChild(info);
        resetBtn.style.display = "none";
        restartBtn.style.display = "none";
        clearBtn.style.display = "";
        renderGameUpdates(body);
      } else if (which === "cloud") {
        h.textContent = cloudStrings().title;
        resetBtn.style.display = "none";
        restartBtn.style.display = "none";
        clearBtn.style.display = "none";
        renderCloud(body);
      } else if (which === "themes") {
        h.textContent = themeStrings().title;
        resetBtn.style.display = "none";
        restartBtn.style.display = "none";
        clearBtn.style.display = "none";
        renderThemes(body);
      } else if (which === "about") {
        h.textContent = ((I18N[pickLang()] || I18N.en).about || I18N.en.about).title;
        resetBtn.style.display = "none";
        restartBtn.style.display = "none";
        clearBtn.style.display = "none";
        renderAbout(body);
      } else {
        h.textContent = "slsteam-moon";
        resetBtn.style.display = "";
        restartBtn.style.display = "";
        clearBtn.style.display = "none";
        loadSlsConfig();
      }
    }
    tabSls.addEventListener("click", function () { selectTab("sls"); });
    tabGu.addEventListener("click", function () { selectTab("gu"); });
    if (tabCloud) tabCloud.addEventListener("click", function () { selectTab("cloud"); });
    tabThemes.addEventListener("click", function () { selectTab("themes"); });
    tabAbout.addEventListener("click", function () { selectTab("about"); });
    var returnTab = null;
    try { returnTab = sessionStorage.getItem("lumen-return-tab"); sessionStorage.removeItem("lumen-return-tab"); } catch (e) {}
    selectTab(returnTab === "themes" ? "themes" : "sls");

    var onKey = function (e) {
      if (e.key === "Escape") { requestClose(); }
    };
    _escHandler = onKey;
    document.addEventListener("keydown", onKey, true);
  }

  // Exposed so the sidecar (injector State:broadcast_overlay) can open/close the
  // overlay. The injector decides WHICH context renders it: the active store/
  // community web view if one is on top, otherwise the shell window (where the
  // library/home content itself lives). So this just opens locally on request;
  // the shell is told to open only when no web view is covering its content.
  window.__lumenOpenOverlay = openOverlay;
  window.__lumenCloseOverlay = closeOverlay;
