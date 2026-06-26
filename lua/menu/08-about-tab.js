// LM-FRAGMENT About tab (renderAbout): versions + Reload All + Update All
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

  // The About tab: shows the installed vs latest release of each of the three
  // stack components (slsteam-moon / Lumen / LuaTools plugin) and an "Update
  // All" that opens a terminal running the installer. Versions come from
  // GetAboutVersions (releases are canonical; the installer stamps the tag).
  function renderAbout(body) {
    var S = (I18N[pickLang()] || I18N.en).about || I18N.en.about;
    body.textContent = "";

    var intro = document.createElement("div");
    intro.className = "lumen-about-intro";
    intro.textContent = S.intro;
    body.appendChild(intro);

    // ── versions list ────────────────────────────────────────────────────────
    // Render the three component rows INSTANTLY (names are known client-side),
    // each showing a loading spinner where the version line and the state pill
    // go. The single GetAboutVersions RPC (installed from versions.json + latest
    // from the releases API) fills them in when it resolves — nothing waits on
    // the network to draw the list.
    var list = document.createElement("div");
    body.appendChild(list);

    var COMPS = [
      { key: "slsteam_moon", name: "slsteam-moon" },
      { key: "plugin", name: "LuaTools plugin" },
      { key: "lumen", name: "Lumen" },
    ];
    // A --noplugin install ships no LuaTools plugin, so drop its row (boot.lua
    // sets window.__lumenNoPlugin, and GetAboutVersions omits it too).
    if (window.__lumenNoPlugin) {
      COMPS = COMPS.filter(function (c) { return c.key !== "plugin"; });
    }
    var rowsByKey = {};
    COMPS.forEach(function (c) {
      var row = versionRow(c.name, S);
      rowsByKey[c.key] = row;
      list.appendChild(row.el);
    });

    call("GetAboutVersions", {})
      .then(function (res) {
        var data = JSON.parse(res);
        if (!data || !data.success) throw new Error((data && data.error) || "load failed");
        var got = {};
        (data.components || []).forEach(function (c) { got[c.key] = c; });
        COMPS.forEach(function (c) {
          var row = rowsByKey[c.key];
          if (!row) return;
          if (got[c.key]) row.fill(got[c.key]);
          else row.fail();
        });
      })
      .catch(function (e) {
        log("GetAboutVersions", e);
        COMPS.forEach(function (c) { if (rowsByKey[c.key]) rowsByKey[c.key].fail(); });
      });

    // ── actions ──────────────────────────────────────────────────────────────
    var actions = document.createElement("div");
    actions.className = "lumen-about-actions";

    actions.appendChild(actionRow(S.updateTitle, S.updateDesc, S.updateBtn, {
      onConfirmed: function (btn) {
        btn.classList.add("busy");
        call("UpdateAll", {})
          .then(function (res) {
            btn.classList.remove("busy");
            var r = typeof res === "string" ? JSON.parse(res) : res;
            if (r && r.success) {
              aboutModal(S.updateOpenedTitle, S.updateOpenedBody, S.ok);
            } else {
              var msg = r && r.error ? String(r.error) : "";
              // A missing terminal returns a specific error; show the manual
              // command in that case, otherwise the generic failure.
              if (msg.indexOf("No terminal") !== -1) {
                aboutModal(S.updateTitle, S.updateNoTerm, S.ok);
              } else {
                aboutModal(S.updateTitle, S.updateFail + msg, S.ok);
              }
            }
          })
          .catch(function (e) {
            btn.classList.remove("busy");
            log("UpdateAll", e);
            aboutModal(S.updateTitle, S.updateFail + (e && e.message ? e.message : e), S.ok);
          });
      },
    }));

    body.appendChild(actions);

    // ── credit ─────────────────────────────────────────────────────────────
    var credit = document.createElement("div");
    credit.className = "lumen-about-credit";
    credit.textContent = "by SWay";
    body.appendChild(credit);
  }

  // One version row, rendered in a LOADING state first: name + a spinner where
  // the version line goes + a spinner where the state pill goes. Returns
  // { el, fill(c), fail() }: fill() swaps the spinners for the real version text
  // and state pill once GetAboutVersions resolves; fail() shows an unknown state.
  function versionRow(name, S) {
    var row = document.createElement("div");
    row.className = "lumen-about-ver";

    var left = document.createElement("div");
    left.style.cssText = "flex:1;min-width:0;";
    var nm = document.createElement("div");
    nm.className = "nm";
    nm.textContent = name;
    left.appendChild(nm);
    var vv = document.createElement("div");
    vv.className = "vv";
    left.appendChild(vv);                  // version line: empty while loading
    row.appendChild(left);

    var right = document.createElement("span");
    right.className = "lumen-about-right";
    right.appendChild(spinnerEl());        // single loading spinner (pill slot)
    row.appendChild(right);

    function setPill(state) {
      right.textContent = "";
      var pill = document.createElement("span");
      pill.className = "lumen-about-state " +
        (state === "current" ? "cur" : state === "update" ? "upd" : "unk");
      pill.textContent = state === "current" ? S.upToDate
        : state === "update" ? S.updateAvailable : S.unknown;
      right.appendChild(pill);
    }

    function fill(c) {
      var inst = c.installed && c.installed !== "" ? c.installed : S.unknown;
      var latest = c.latest && c.latest !== "" ? c.latest : S.unknown;
      if (c.installedBuild) inst += " (" + c.installedBuild + ")";
      if (c.latestBuild) latest += " (" + c.latestBuild + ")";
      vv.textContent = S.installed + ": " + inst + "  \u00b7  " + S.latest + ": " + latest;
      setPill(c.state);
    }

    function fail() {
      vv.textContent = S.installed + ": " + S.unknown + "  \u00b7  " + S.latest + ": " + S.unknown;
      setPill("unknown");
    }

    return { el: row, fill: fill, fail: fail };
  }

  // A small rotating loading spinner element.
  function spinnerEl() {
    var s = document.createElement("span");
    s.className = "lumen-spin";
    return s;
  }

  // One action card: title + description + a button. When `confirmLabel` is
  // given the button is two-click (arm -> confirm) so a live reload can't fire
  // by accident; otherwise it acts on the first click. `onConfirmed(btn)` runs
  // when the action is triggered.
  function actionRow(title, desc, btnLabel, opts) {
    opts = opts || {};
    var row = document.createElement("div");
    row.className = "lumen-about-act";

    var txt = document.createElement("div");
    txt.className = "txt";
    var at = document.createElement("div");
    at.className = "at";
    at.textContent = title;
    var ad = document.createElement("div");
    ad.className = "ad";
    ad.textContent = desc;
    txt.appendChild(at); txt.appendChild(ad);
    row.appendChild(txt);

    var btn = document.createElement("div");
    btn.className = "lumen-about-btn";
    btn.textContent = btnLabel;

    if (opts.confirmLabel) {
      var armed = false, armTimer = null;
      var disarm = function () {
        armed = false;
        if (armTimer) { clearTimeout(armTimer); armTimer = null; }
        btn.classList.remove("confirm");
        btn.textContent = btnLabel;
      };
      btn.addEventListener("click", function () {
        if (btn.classList.contains("busy")) return;
        if (!armed) {
          armed = true;
          btn.classList.add("confirm");
          btn.textContent = opts.confirmLabel;
          armTimer = setTimeout(disarm, 3000);
          return;
        }
        disarm();
        opts.onConfirmed(btn);
      });
    } else {
      btn.addEventListener("click", function () {
        if (btn.classList.contains("busy")) return;
        opts.onConfirmed(btn);
      });
    }
    row.appendChild(btn);
    return row;
  }

  // A small info modal (reusing the validate-prompt modal styling) with a single
  // OK button. Body may contain newlines (pre-wrapped).
  function aboutModal(title, bodyText, okLabel) {
    var back = document.createElement("div");
    back.className = "lumen-modal-back";
    var modal = document.createElement("div");
    modal.className = "lumen-modal";
    var mt = document.createElement("div");
    mt.className = "mt";
    mt.textContent = title;
    var mb = document.createElement("div");
    mb.className = "mb";
    mb.style.whiteSpace = "pre-wrap";
    mb.textContent = bodyText;
    var mrow = document.createElement("div");
    mrow.className = "mrow";
    var ok = document.createElement("div");
    ok.className = "lumen-mbtn primary";
    ok.textContent = okLabel || "OK";
    var close = function () { if (back.parentNode) back.remove(); };
    ok.addEventListener("click", close);
    back.addEventListener("click", function (e) { if (e.target === back) close(); });
    mrow.appendChild(ok);
    modal.appendChild(mt); modal.appendChild(mb); modal.appendChild(mrow);
    back.appendChild(modal);
    (document.body || document.documentElement).appendChild(back);
  }

