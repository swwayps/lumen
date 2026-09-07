// LM-FRAGMENT settings window/overlay (openOverlay) + window.__lumen* exposure
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

  function openOverlay() {
    if (document.getElementById(OVERLAY_ID)) return;
    injectStyles();
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
    var tabFixes = window.__lumenNoPlugin ? null : mkTab(luaToolsStrings().fixesTab, LUA_TOOLS_FIXES_SVG);
    var tabAbout = mkTab(((I18N[pickLang()] || I18N.en).about || I18N.en.about).tab, ABOUT_SVG);
    var sideSpacer = document.createElement("div");
    sideSpacer.className = "lumen-side-spacer";
    side.appendChild(sideSpacer);
    var accountEntry = null, accountName = null, accountCopy = null, accountAvatar = null;
    if (!window.__lumenNoPlugin) {
      accountEntry = document.createElement("button");
      accountEntry.type = "button";
      // Start as "checking", not as "sign in". The auth status is a backend call
      // and at boot it waits its turn behind everything else the open kicked off,
      // so claiming "Sign in to lua.tools" first meant a connected account was
      // told it was signed out for a second before the row corrected itself.
      accountEntry.className = "lumen-account-entry checking";
      accountAvatar = document.createElement("span");
      accountAvatar.className = "lumen-account-avatar";
      var accountSpinner = document.createElement("span");
      accountSpinner.className = "lumen-spin";
      accountAvatar.appendChild(accountSpinner);
      var accountText = document.createElement("span");
      accountName = document.createElement("strong");
      accountName.textContent = "lua.tools";
      accountCopy = document.createElement("small");
      accountCopy.textContent = luaToolsStrings().checking;
      accountText.appendChild(accountName); accountText.appendChild(accountCopy);
      accountEntry.appendChild(accountAvatar); accountEntry.appendChild(accountText);
      side.appendChild(accountEntry);
    }

    // content
    var content = document.createElement("div");
    content.className = "lumen-content";
    var ctop = document.createElement("div");
    ctop.className = "lumen-ctop";
    var h = document.createElement("div");
    h.className = "h";
    var accountBack = document.createElement("button");
    accountBack.type = "button";
    accountBack.className = "lumen-account-back";
    accountBack.innerHTML = LUA_TOOLS_BACK_SVG;
    accountBack.title = luaToolsStrings().back;
    accountBack.setAttribute("aria-label", luaToolsStrings().back);
    accountBack.style.display = "none";
    var x = document.createElement("div");
    x.className = "x";
    x.textContent = "\u2715";
    x.addEventListener("click", requestClose);
    var slsBody, guBody, cloudBody, fixesBody, aboutBody, accountBody;

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
          renderConfig(slsBody, cfg);
        })
        .catch(function (e) {
          slsBody.textContent = "";
          var err = document.createElement("div");
          err.className = "lumen-err";
          err.textContent = (S0.resetFail || "Reset failed: ") + (e && e.message ? e.message : e);
          slsBody.appendChild(err);
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
          reloadGameUpdates(guBody);
        })
        .catch(function (e) {
          var er = document.createElement("div");
          er.className = "lumen-err";
          er.textContent = guStrings().clearFail + (e && e.message ? e.message : e);
          guBody.appendChild(er);
        });
    });

    ctop.appendChild(accountBack); ctop.appendChild(h); ctop.appendChild(clearBtn); ctop.appendChild(restartBtn); ctop.appendChild(resetBtn); ctop.appendChild(x);

    content.appendChild(ctop);
    function makePanel(name) {
      var panel = document.createElement("div");
      panel.id = "lumen-panel-" + name;
      panel.className = "lumen-body lumen-tab-panel";
      panel.style.display = "none";
      content.appendChild(panel);
      return panel;
    }
    slsBody = makePanel("sls");
    guBody = makePanel("gu");
    cloudBody = tabCloud ? makePanel("cloud") : null;
    fixesBody = tabFixes ? makePanel("fixes") : null;
    aboutBody = makePanel("about");
    accountBody = accountEntry ? makePanel("account") : null;
    win.appendChild(side);
    win.appendChild(content);
    overlay.appendChild(win);
    (document.body || document.documentElement).appendChild(overlay);

    // Each tab owns a persistent panel and initializes at most once. Async
    // responses can therefore finish in the background without clearing or
    // replacing whichever tab the user is currently viewing.
    var initialized = { sls: false, gu: false, cloud: false, fixes: false, about: false, account: false };
    var preloadStarted = false;
    var currentTab = "sls";
    var accountPreviousTab = "sls";

    function updateAccountEntry(status) {
      if (!accountEntry) return;
      var configured = !!(status && status.configured);
      var displayName = configured && status.account && status.account.displayName;
      accountName.textContent = displayName || luaToolsStrings().signIn;
      accountCopy.textContent = configured ? luaToolsStrings().connected : luaToolsStrings().unlock;
      accountEntry.classList.remove("checking");
      accountEntry.classList.toggle("connected", configured);
      accountAvatar.textContent = "";
      var avatarUrl = configured && luaToolsSafeAvatar(status.account && status.account.avatarUrl);
      if (avatarUrl) {
        var image = document.createElement("img"); image.src = avatarUrl; image.alt = "";
        accountAvatar.appendChild(image);
      } else {
        // With no Discord picture to show, the row rests on the lua.tools mark and
        // trades it for the profile glyph on hover: branding at a glance, and the
        // "this is your account" affordance the moment you aim at the row.
        accountAvatar.appendChild(luaToolsLogoImage("lumen-account-avatar-brand"));
        var glyph = document.createElement("span");
        glyph.className = "lumen-account-avatar-glyph";
        glyph.innerHTML = LUA_TOOLS_USER_SVG;
        accountAvatar.appendChild(glyph);
      }
    }

    function invalidateFixes() {
      if (!fixesBody) return;
      initialized.fixes = false;
      fixesBody.textContent = "";
      if (currentTab === "fixes") ensureTab("fixes");
    }

    // Warming the other tabs is only worth anything while the window is open.
    // The sidecar handles one call at a time, and this round of preloads includes
    // a manifest-archive scan (GetGameUpdates) and a version check that reaches
    // the network (GetAboutVersions). Left running after a close, they held the
    // loop for seconds — so reopening right after closing did nothing until they
    // finished, which read as "the button stopped working".
    function overlayLive() {
      return !!document.getElementById(OVERLAY_ID);
    }

    function preloadRemainingTabs() {
      if (preloadStarted) return;
      preloadStarted = true;
      var cloudWarm = cloudBody ? ensureTab("cloud") : Promise.resolve();
      Promise.resolve(cloudWarm).catch(function (e) { log("preload Cloud Saves", e); })
        .then(function () {
          if (!overlayLive()) return;
          ensureTab("gu");
          ensureTab("about");
        });
    }

    function loadSlsConfig() {
      slsBody.textContent = "Loading\u2026";
      return call("GetSlsConfig", {})
        .then(function (res) {
          var config = JSON.parse(res);
          if (!config || !config.success) throw new Error((config && config.error) || "load failed");
          renderConfig(slsBody, config);
          // The lightweight default panel is usable before background work is
          // queued. All remaining panels then warm once and retain their DOM.
          preloadRemainingTabs();
          return config;
        })
        .catch(function (e) {
          slsBody.textContent = "";
          var err = document.createElement("div");
          err.className = "lumen-err";
          err.textContent = "Failed to load slsteam-moon config: " + (e && e.message ? e.message : e);
          slsBody.appendChild(err);
        });
    }

    function ensureTab(which) {
      if (initialized[which]) return initialized[which];
      // Nothing gets queued for a window that is already gone. `initialized`
      // stays false, so the tab loads normally on the next open.
      if (!overlayLive()) return Promise.resolve();
      initialized[which] = true;
      var loading;
      if (which === "sls") loading = loadSlsConfig();
      else if (which === "gu") loading = renderGameUpdates(guBody);
      else if (which === "cloud" && cloudBody) loading = renderCloud(cloudBody);
      else if (which === "fixes" && fixesBody) loading = renderLuaToolsFixes(fixesBody);
      else if (which === "about") loading = renderAbout(aboutBody);
      else if (which === "account" && accountBody) loading = renderLuaToolsAccount(accountBody, {
        onStatus: updateAccountEntry,
        onAuthChanged: invalidateFixes,
      });
      initialized[which] = Promise.resolve(loading);
      return initialized[which];
    }

    // Tab switching: update active state, header title, reset-button visibility,
    // then render the tab's body.
    function selectTab(which) {
      currentTab = which;
      disarm();
      cdisarm();
      tabSls.classList.toggle("active", which === "sls");
      tabGu.classList.toggle("active", which === "gu");
      if (tabCloud) tabCloud.classList.toggle("active", which === "cloud");
      if (tabFixes) tabFixes.classList.toggle("active", which === "fixes");
      tabAbout.classList.toggle("active", which === "about");
      if (accountEntry) accountEntry.classList.toggle("active", which === "account");
      guSetTabActive(which === "gu");
      slsBody.style.display = which === "sls" ? "block" : "none";
      guBody.style.display = which === "gu" ? "block" : "none";
      if (cloudBody) cloudBody.style.display = which === "cloud" ? "block" : "none";
      if (fixesBody) fixesBody.style.display = which === "fixes" ? "block" : "none";
      aboutBody.style.display = which === "about" ? "block" : "none";
      if (accountBody) accountBody.style.display = which === "account" ? "block" : "none";
      var warm = !!initialized[which];
      ensureTab(which);
      // The panel keeps its DOM, so coming back to an already-loaded Game
      // Updates tab shows it instantly; confirm the list against disk in the
      // background so a game added meanwhile (LuaTools, the Fixes menu) appears
      // without the user having to reopen the overlay.
      if (which === "gu" && warm) revalidateGameUpdates();
      accountBack.style.display = which === "account" ? "inline-flex" : "none";
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
      } else if (which === "cloud") {
        h.textContent = cloudStrings().title;
        resetBtn.style.display = "none";
        restartBtn.style.display = "none";
        clearBtn.style.display = "none";
      } else if (which === "fixes") {
        h.textContent = luaToolsStrings().fixesTab;
        resetBtn.style.display = "none";
        restartBtn.style.display = "none";
        clearBtn.style.display = "none";
      } else if (which === "about") {
        h.textContent = ((I18N[pickLang()] || I18N.en).about || I18N.en.about).title;
        resetBtn.style.display = "none";
        restartBtn.style.display = "none";
        clearBtn.style.display = "none";
      } else if (which === "account") {
        h.textContent = "";
        var accountTitle = document.createElement("span");
        accountTitle.className = "lumen-account-title";
        accountTitle.appendChild(luaToolsLogoImage("lumen-account-title-mark"));
        var accountTitleText = document.createElement("span");
        accountTitleText.textContent = luaToolsStrings().accountTitle;
        accountTitle.appendChild(accountTitleText);
        h.appendChild(accountTitle);
        resetBtn.style.display = "none";
        restartBtn.style.display = "none";
        clearBtn.style.display = "none";
      } else {
        h.textContent = "slsteam-moon";
        resetBtn.style.display = "";
        restartBtn.style.display = "";
        clearBtn.style.display = "none";
      }
    }
    tabSls.addEventListener("click", function () { selectTab("sls"); });
    tabGu.addEventListener("click", function () { selectTab("gu"); });
    if (tabCloud) tabCloud.addEventListener("click", function () { selectTab("cloud"); });
    if (tabFixes) tabFixes.addEventListener("click", function () { selectTab("fixes"); });
    tabAbout.addEventListener("click", function () { selectTab("about"); });
    if (accountEntry) accountEntry.addEventListener("click", function () {
      if (currentTab !== "account") accountPreviousTab = currentTab;
      selectTab("account");
    });
    accountBack.addEventListener("click", function () { selectTab(accountPreviousTab); });
    var requestedTab = window.__lumenSettingsInitialTab;
    window.__lumenSettingsInitialTab = null;
    selectTab(requestedTab === "account" && accountBody ? "account" : "sls");
    if (accountEntry) {
      call("GetLuaToolsAuthStatus", {}).then(luaToolsParse).then(updateAccountEntry).catch(function () {});
    }

    var onKey = function (e) {
      if (e.key === "Escape") { requestClose(); }
    };
    _escHandler = onKey;
    document.addEventListener("keydown", onKey, true);
    // Gamepad UI: register the window with Steam's own focus navigation so the
    // D-pad walks the tabs and controls instead of the library behind it.
    // Guarded because unit tests load this fragment without 04-overlay-helpers.
    if (typeof setSettingsFocusTrap === "function") {
      setSettingsFocusTrap(overlay, requestClose);
    }
  }

  // Exposed so the sidecar (injector State:broadcast_overlay) can open/close the
  // overlay. The injector decides WHICH context renders it: the active store/
  // community web view if one is on top, otherwise the shell window (where the
  // library/home content itself lives). So this just opens locally on request;
  // the shell is told to open only when no web view is covering its content.
  window.__lumenOpenOverlay = openOverlay;
  window.__lumenCloseOverlay = closeOverlay;
  window.__lumenOpenLuaToolsAccount = function () {
    window.__lumenSettingsInitialTab = "account";
    openOverlay();
  };
