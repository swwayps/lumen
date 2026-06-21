// LM-FRAGMENT Game Updates tab (renderDlcSubpage, gameCard, renderGameUpdates)
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

  // DLC / per-component sub-page: each of the game's depots is independently
  // pinnable (SetDlcPin / ClearDlcPin). We can't map depot->DLC appid purely
  // from on-disk data, so depots are labelled by id (a best-effort name lookup
  // could be added later). master-detail: a back arrow returns to the list.
  function renderDlcSubpage(body, game, onBack) {
    var GU = I18N.en.gu;
    body.textContent = "";
    var back = document.createElement("div");
    back.className = "lumen-back";
    back.innerHTML = "\u2190 ";
    var bt = document.createElement("span");
    bt.textContent = GU.back;
    back.appendChild(bt);
    back.addEventListener("click", onBack);
    body.appendChild(back);

    var hd = document.createElement("div");
    hd.className = "lumen-sub-title";
    hd.textContent = GU.dlcTitle;
    body.appendChild(hd);
    // Danger warning: per-depot overrides can mix incompatible versions.
    addLine(body, GU.depotWarn, "danger", "\u26A0");

    if (!game.depots || game.depots.length === 0) {
      var empty = document.createElement("div");
      empty.className = "lumen-empty";
      empty.textContent = GU.emptyDlc;
      body.appendChild(empty);
      return;
    }

    game.depots.forEach(function (d) {
      var head = document.createElement("div");
      head.className = "lumen-game-head";
      head.style.cursor = "default";
      var meta = document.createElement("div");
      meta.className = "lumen-game-meta";
      var name = document.createElement("div");
      name.className = "lumen-game-name";
      name.textContent = depotLabel(d);
      meta.appendChild(name);
      head.appendChild(meta);
      body.appendChild(head);

      var vers = document.createElement("div");
      vers.className = "lumen-vers";
      var anyPinned = d.versions.some(function (v) { return v.pinned; });
      var rows = [];
      var select = function (target) {
        rows.forEach(function (r) { r.classList.toggle("sel", r === target); });
      };

      var latest = verRow({
        label: GU.latest, selected: !anyPinned,
        onClick: function () {
          call("ClearDlcPin", { json: JSON.stringify({ appid: game.appid, depot: d.depot }) })
            .then(function () { select(latest); if (isGameInstalled(game)) showValidatePrompt(game.appid); })
            .catch(function (e) { log("ClearDlcPin", e); });
        },
      });
      rows.push(latest);
      vers.appendChild(latest);

      d.versions.forEach(function (v) {
        var badges = [];
        if (v.pinned) badges.push({ cls: "lock", text: GU.pinned });
        if (v.installed) badges.push({ cls: "cur", text: GU.current });
        if (v.fromLuaTools) badges.push({ cls: "lt", text: GU.fromLua });
        var row = verRow({
          label: fmtDate(v.date), gid: v.gid, selected: v.pinned, badges: badges,
          onClick: function () {
            // Write the pin (and move the selection) ONLY if the user follows
            // through the modal; "Not now"/"Later"/dismiss cancels it and the
            // previous selection stands.
            var applyPin = function () {
              return call("SetDlcPin", { json: JSON.stringify({ appid: game.appid, depot: d.depot, gid: v.gid }) })
                .then(function () { select(row); })
                .catch(function (e) { log("SetDlcPin", e); });
            };
            if (isGameInstalled(game)) {
              if (v.installed) applyPin();                      // already on this gid
              else showUninstallPrompt(game.appid, applyPin);   // confirm uninstall first
            } else {
              showPinRestartPrompt(applyPin);                   // confirm restart first
            }
          },
        });
        rows.push(row);
        vers.appendChild(row);
        // Trash: drop this archived version's manifest (frees space). Not offered
        // for installed/pinned versions — those are still needed on disk.
        if (!v.installed && !v.pinned) {
          var del = document.createElement("span");
          del.className = "lumen-del";
          del.textContent = "\uD83D\uDDD1";
          del.title = GU.delTitle;
          del.addEventListener("click", function (e) {
            e.stopPropagation();
            call("DeleteManifest", { json: JSON.stringify({ depot: d.depot, gid: v.gid }) })
              .then(function () { if (row.parentNode) row.remove(); })
              .catch(function (er) { log("DeleteManifest", er); });
          });
          row.appendChild(del);
        }
      });
      body.appendChild(vers);
    });
  }

  // One game card: capsule + name + a subtle "Advanced" link. The build
  // timeline shows inline by default (collapsed to a few rows + Show more), so
  // picking a version is the obvious action and "Advanced" (per-depot
  // overrides) stays low-key.
  function gameCard(game) {
    var GU = I18N.en.gu;
    var wrap = document.createElement("div");
    wrap.className = "lumen-game";

    var head = document.createElement("div");
    head.className = "lumen-game-head";
    head.style.cursor = "default";
    var cap = document.createElement("img");
    cap.className = "lumen-cap";
    // Defer offscreen capsule loads/decoding (native, behaviour-preserving: if
    // unsupported the image just loads eagerly as before). Set before .src.
    cap.loading = "lazy";
    cap.decoding = "async";
    // loadCapsule tries the static header.jpg, then the store's header_image for
    // newer titles whose static capsule isn't published yet.
    loadCapsule(game.appid, cap);
    head.appendChild(cap);

    var meta = document.createElement("div");
    meta.className = "lumen-game-meta";
    var name = document.createElement("div");
    name.className = "lumen-game-name";
    var nm = document.createElement("span");
    nm.textContent = "App " + game.appid;
    name.appendChild(nm);
    fetchAppName(game.appid).then(function (n) { if (n) nm.textContent = n; });
    var lockBadge = document.createElement("span");
    lockBadge.className = "lumen-badge lock";
    lockBadge.textContent = GU.locked;
    if (game.locked) name.appendChild(lockBadge);
    var setLocked = function (locked) {
      game.locked = locked;
      if (locked && !lockBadge.parentNode) name.appendChild(lockBadge);
      else if (!locked && lockBadge.parentNode) lockBadge.remove();
    };
    var sub = document.createElement("div");
    sub.className = "lumen-game-sub";
    sub.textContent = "" + game.appid;
    meta.appendChild(name); meta.appendChild(sub);
    head.appendChild(meta);

    var vers = document.createElement("div");
    vers.className = "lumen-vers";

    var adv = document.createElement("div");
    adv.className = "lumen-adv";
    adv.textContent = GU.advanced + " \u203a";
    adv.title = GU.advancedHint;
    adv.addEventListener("click", function (e) {
      e.stopPropagation();
      renderDlcSubpage(vers.__bodyRef, game, function () { reloadGameUpdates(vers.__bodyRef); });
    });
    head.appendChild(adv);

    wrap.appendChild(head);
    wrap.appendChild(vers);

    // Inline timeline, visible by default, collapsed to the most recent few.
    // Selecting a build moves the radio IN PLACE (no list re-render) so scroll
    // position and the Show-more expansion are preserved.
    var DEFAULT_SHOWN = 3;
    var builds = gameBuilds(game);
    markLuaToolsBuild(builds);
    var rows = [];
    var select = function (target) {
      rows.forEach(function (r) { r.classList.toggle("sel", r === target); });
    };

    var latest = verRow({
      label: GU.latest, selected: !game.locked,
      onClick: function () {
        call("ClearGamePin", { json: JSON.stringify({ appid: game.appid }) })
          .then(function () { select(latest); setLocked(false); if (isGameInstalled(game)) showValidatePrompt(game.appid); })
          .catch(function (e) { log("ClearGamePin", e); });
      },
    });
    rows.push(latest);
    vers.appendChild(latest);

    var extra = [];
    builds.forEach(function (b, idx) {
      var badges = [];
      if (b.installed) badges.push({ cls: "cur", text: GU.current });
      if (b.fromLua) badges.push({ cls: "lt", text: GU.fromLua });
      var row = verRow({
        label: fmtDate(b.date), selected: game.locked && b.pinned, badges: badges,
        onClick: function () {
          // Write the pin (and lock/move the selection) ONLY if the user follows
          // through the modal; "Not now"/"Later"/dismiss cancels it and the
          // previous selection stands (no half-applied pin).
          var applyPin = function () {
            return call("SetGamePin", { json: JSON.stringify({ appid: game.appid, date: b.date }) })
              .then(function () { select(row); setLocked(true); })
              .catch(function (e) { log("SetGamePin", e); });
          };
          if (isGameInstalled(game)) {
            if (b.installed) applyPin();                       // already on this build
            else showUninstallPrompt(game.appid, applyPin);    // confirm uninstall first
          } else {
            showPinRestartPrompt(applyPin);                    // confirm restart first
          }
        },
      });
      rows.push(row);
      if (idx >= DEFAULT_SHOWN) { row.style.display = "none"; extra.push(row); }
      vers.appendChild(row);
    });
    if (extra.length > 0) {
      var more = document.createElement("div");
      more.className = "lumen-more";
      var open = false;
      var setMore = function () {
        more.textContent = open ? (GU.showLess + " \u25B4")
                                 : (GU.showMore + " (" + extra.length + ") \u25BE");
      };
      setMore();
      more.addEventListener("click", function (e) {
        e.stopPropagation();
        open = !open;
        extra.forEach(function (r) { r.style.display = open ? "flex" : "none"; });
        setMore();
      });
      vers.appendChild(more);
    }

    wrap.__versRef = vers;
    return wrap;
  }

  // Re-fetch + re-render the whole Game Updates list into `body`.
  function reloadGameUpdates(body) { renderGameUpdates(body); }

  // Read an uploaded lua.tools .lua and import the game it describes, WITHOUT
  // requiring it to have been added via LuaTools first. To make a game's DLCs
  // installable we need their per-depot decryption keys; a "Manifest"-style .lua
  // is often base-only (just the base depot key). Per-depot keys are build-
  // independent, so we prefer the plugin's SOURCES (which ship the complete .lua
  // with every depot key) and then re-apply the uploaded .lua's pin on top:
  //   InspectLua (appid + installed?) ->
  //     installed  -> reinstall-confirm modal -> runImport
  //     not added  -> runImport
  //   runImport: CheckApisForApp -> StartAddViaLuaToolsSmart (races sources,
  //     picks the most COMPLETE -> every depot key) -> ImportLuaPin (apply the
  //     uploaded .lua's pin); fall back to ImportLuaFull (the uploaded, possibly
  //     base-only .lua) when no source has the app.
  function importLuaFromFile(file, body) {
    var GU = I18N.en.gu;
    var reader = new FileReader();
    reader.onload = function () {
      var text = String(reader.result);
      call("InspectLua", { json: JSON.stringify({ lua: text }) })
        .then(function (res) {
          var r = JSON.parse(res);
          if (!r || !r.success) {
            var e2 = (r && r.error) || "";
            var msg = /determine app id|app id from/.test(e2) ? GU.importNoApp
                    : /is for app/.test(e2) ? GU.importBadApp
                    : GU.importFail + e2;
            throw new Error(msg);
          }
          if (r.alreadyOnBuild) {
            // Already installed at exactly this build: nothing to change. Offer a
            // force "apply anyway" (re-fetch + re-verify) but never auto-validate.
            showConfirm({
              title: GU.alreadyTitle, body: GU.alreadyBody,
              confirmText: GU.alreadyApply, declineText: GU.alreadyCancel,
              onConfirm: function () { runImport(r, text, body); },
            });
          } else if (r.installed) {
            showConfirm({
              title: GU.reinstallTitle, body: GU.reinstallBody,
              confirmText: GU.reinstallConfirm, declineText: GU.reinstallCancel,
              onConfirm: function () { runImport(r, text, body); },
            });
          } else {
            runImport(r, text, body);
          }
        })
        .catch(function (e) { log("InspectLua", e); alert((e && e.message) || GU.importFail); });
    };
    reader.onerror = function () { alert(I18N.en.gu.importFail); };
    reader.readAsText(file);
  }

  // Poll the plugin's add status until terminal. Resolves "done" | "failed".
  // The source package (a .lua + manifests) is small, so this settles quickly;
  // a cap keeps a stuck backend from polling forever.
  function pollAddStatus(appid, prog) {
    var GU = I18N.en.gu;
    return new Promise(function (resolve) {
      var ticks = 0;
      var tick = function () {
        if (++ticks > 300) { resolve("failed"); return; }
        call("GetAddViaLuaToolsStatus", { appid: appid })
          .then(function (res) {
            var p = JSON.parse(res);
            var st = (p && p.state) || {};
            var s = st.status;
            if (s === "done") { resolve(st.success ? "done" : "failed"); return; }
            if (s === "failed" || s === "cancelled") { resolve("failed"); return; }
            if (prog) prog.update(
              s === "downloading" ? GU.loadDownloading
              : s === "processing" || s === "installing" ? GU.loadProcessing
              : GU.loadChecking);
            setTimeout(tick, 600);
          })
          .catch(function () { resolve("failed"); });
      };
      tick();
    });
  }

  // Add the game from the plugin's sources (complete depot keys). Resolves true
  // if a source supplied the game, false to fall back to the uploaded .lua.
  // Uses the SMART add (StartAddViaLuaToolsSmart): it races every enabled source
  // and picks the most COMPLETE package, so a game whose first-available source
  // is missing DLC keys still gets them from a fuller one.
  function addFromSources(appid, prog) {
    var GU = I18N.en.gu;
    return call("CheckApisForApp", { appid: appid })
      .then(function (res) {
        var p = JSON.parse(res);
        var results = (p && p.results) || [];
        var available = results.some(function (r) { return r && r.available; });
        if (!available) return false;
        if (prog) prog.update(GU.loadDownloading);
        return call("StartAddViaLuaToolsSmart", { appid: appid })
          .then(function () { return pollAddStatus(appid, prog); })
          .then(function (outcome) { return outcome === "done"; });
      })
      .catch(function () { return false; });
  }

  // Add the game (preferring sources for complete keys) then apply the uploaded
  // .lua's pin. `info` is the InspectLua result.
  function runImport(info, text, body) {
    var GU = I18N.en.gu;
    var appid = info.appid;
    var hasPins = (info.pinned || 0) > 0;
    var prog = showProgress(GU.importLua);
    prog.update(GU.loadChecking);
    addFromSources(appid, prog)
      .then(function (fromSource) {
        prog.close();
        reloadGameUpdates(body);
        // applyPin writes the .lua's build pin (and, on the no-source fallback,
        // also adds the game). Same gating as a manual pin: it runs ONLY if the
        // user follows through the uninstall/restart the pin needs to take
        // effect. Declining leaves no half-applied build pin — a game added from
        // a source stays (it'll install at the latest build), nothing loops.
        var applyPin = function () {
          var p;
          if (fromSource) {
            p = hasPins
              ? call("ImportLuaPin", { json: JSON.stringify({ appid: appid, lua: text }) })
              : Promise.resolve('{"success":true}');
          } else {
            // No source had the app: ImportLuaFull writes the uploaded .lua
            // directly (adds the game + its pins). Gated, so declining adds nothing.
            p = call("ImportLuaFull", { json: JSON.stringify({ lua: text }) });
          }
          return p.then(function (ir) {
            if (typeof ir === "string") {
              var r2 = JSON.parse(ir);
              if (!r2 || !r2.success) throw new Error((r2 && r2.error) || GU.importFail);
            }
            reloadGameUpdates(body);
          });
        };
        if (info.installed) {
          // Installed at a different build: a verify won't switch it, so the pin
          // is applied and the game uninstalled (then reinstalled fresh at the
          // pin) only if the user proceeds.
          showUninstallPrompt(appid, applyPin);
        } else {
          showConfirm({
            title: GU.restartTitle,
            body: fromSource ? GU.restartBody : GU.restartBodyPartial,
            confirmText: GU.restartNow,
            declineText: GU.restartLater,
            onConfirm: function () {
              Promise.resolve(applyPin())
                .then(function () {
                  call("RestartSteam", {}).catch(function (e) { log("RestartSteam", e); });
                })
                .catch(function (e) { log("ImportLuaPin", e); alert((e && e.message) || GU.importFail); });
            },
          });
        }
      })
      .catch(function (e) {
        prog.close();
        log("runImport", e);
        alert((e && e.message) || GU.importFail);
      });
  }

  // The single top-of-page "Load .lua" button (replaces the per-card import).
  // Reads the file in-page (FileReader) and hands its text to importLuaFromFile;
  // no native file dialog or filesystem path is ever needed.
  function loadLuaButton(body) {
    var GU = I18N.en.gu;
    var wrap = document.createElement("div");
    wrap.className = "lumen-gu-actions";
    var btn = document.createElement("button");
    btn.className = "lumen-mbtn primary lumen-load-lua";
    btn.textContent = "\u2191 " + GU.importLua;
    btn.title = GU.loadTopHint;
    var fileIn = document.createElement("input");
    fileIn.type = "file";
    fileIn.accept = ".lua";
    fileIn.style.display = "none";
    btn.addEventListener("click", function () { fileIn.value = ""; fileIn.click(); });
    fileIn.addEventListener("change", function () {
      var f = fileIn.files && fileIn.files[0];
      if (f) importLuaFromFile(f, body);
    });
    wrap.appendChild(btn);
    wrap.appendChild(fileIn);
    return wrap;
  }

  function renderGameUpdates(body) {
    var GU = I18N.en.gu;
    body.textContent = "";
    var note = document.createElement("div");
    note.className = "lumen-note";
    note.textContent = GU.note;
    body.appendChild(note);

    body.appendChild(loadLuaButton(body));

    var search = document.createElement("input");
    search.type = "text";
    search.className = "lumen-gu-search";
    search.placeholder = GU.search;
    body.appendChild(search);

    var listWrap = document.createElement("div");
    body.appendChild(listWrap);
    listWrap.textContent = "Loading\u2026";

    call("GetGameUpdates", {})
      .then(function (res) {
        var data = JSON.parse(res);
        if (!data || !data.success) throw new Error((data && data.error) || "load failed");
        // Lua serializes an empty array as {} (an object), so coerce every list
        // back to an array before we filter/iterate, and drop games that ended
        // up with no archived versions (e.g. after a manifest purge).
        var arr = function (x) { return Array.isArray(x) ? x : []; };
        var games = arr(data.games).filter(function (g) {
          g.depots = arr(g.depots);
          g.dlc_appids = arr(g.dlc_appids);
          g.depots.forEach(function (d) { d.versions = arr(d.versions); });
          return g.depots.length > 0;
        });
        listWrap.textContent = "";
        if (games.length === 0) {
          var empty = document.createElement("div");
          empty.className = "lumen-empty";
          empty.textContent = GU.none;
          listWrap.appendChild(empty);
          return;
        }
        // Build all cards into a detached fragment, then attach once: identical
        // final DOM, but one reflow instead of one per card (snappier with many
        // games). Cache each card's name element so the search filter doesn't
        // re-query the DOM per keystroke (textContent is still read live, so the
        // async store-name update is reflected).
        var frag = document.createDocumentFragment();
        var cards = games.map(function (g) {
          var card = gameCard(g);
          card.__versRef.__bodyRef = body;
          card.__appid = g.appid;
          card.__nameEl = card.querySelector(".lumen-game-name");
          frag.appendChild(card);
          return card;
        });
        listWrap.appendChild(frag);
        search.addEventListener("input", function () {
          var q = search.value.trim().toLowerCase();
          cards.forEach(function (c) {
            var nameEl = c.__nameEl;
            var hay = (String(c.__appid) + " " + (nameEl ? nameEl.textContent : "")).toLowerCase();
            c.style.display = (q === "" || hay.indexOf(q) !== -1) ? "" : "none";
          });
        });
      })
      .catch(function (e) {
        listWrap.textContent = "";
        var err = document.createElement("div");
        err.className = "lumen-err";
        err.textContent = GU.loadFail + (e && e.message ? e.message : e);
        listWrap.appendChild(err);
      });
  }

