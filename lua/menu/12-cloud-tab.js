// LM-FRAGMENT Cloud Saves tab (renderCloud) — CloudRedirect setup in-menu
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.
//
// Sets up CloudRedirect cloud saves without the flatpak: pick a provider, sign
// in (OAuth in the backend, browser-driven), toggle the two stats switches. All
// state lives in the hook's ~/.config/CloudRedirect file contract; this tab
// only drives the LumenCloud* backend RPCs. No folder picker (the local path is
// fixed) and no schema toggle (it's a technical prerequisite, kept on).

  // Poll handle for an in-flight sign-in, so switching tabs / re-rendering
  // cancels it instead of leaking a timer.
  var _cloudAuthTimer = null;
  function cloudStopAuthPoll() {
    if (_cloudAuthTimer) { clearTimeout(_cloudAuthTimer); _cloudAuthTimer = null; }
  }

  function cloudToggleRow(labelText, descText, checked, onChange) {
    var row = document.createElement("div");
    row.className = "lumen-row";
    var wrap = document.createElement("div");
    wrap.className = "lumen-lblwrap";
    var lbl = document.createElement("div");
    lbl.className = "lbl";
    lbl.textContent = labelText;
    wrap.appendChild(lbl);
    if (descText) {
      var d = document.createElement("div");
      d.className = "lumen-desc";
      d.textContent = descText;
      wrap.appendChild(d);
    }
    row.appendChild(wrap);
    var ctrl = document.createElement("span");
    ctrl.className = "lumen-ctrl";
    var sw = document.createElement("label");
    sw.className = "lumen-sw";
    var cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = !!checked;
    var sl = document.createElement("span");
    sl.className = "sl";
    cb.addEventListener("change", function () { onChange(cb.checked); });
    sw.appendChild(cb); sw.appendChild(sl); ctrl.appendChild(sw);
    row.appendChild(ctrl);
    return row;
  }

  // Persist a stats toggle. The write is UNCONDITIONAL for both on and off, so
  // turning it back off in the same session truly writes false (never a stuck
  // "on" state) — the modal is purely informational and doesn't gate the write.
  // On enable we tell the user it only applies after a Steam restart (the hook
  // reads these flags once at startup).
  function cloudStatsToggle(S, key, on) {
    call("LumenCloudSetToggle", { json: JSON.stringify({ key: key, value: on }) })
      .catch(function () {});
    if (on) aboutModal(S.syncRestartTitle, S.syncRestartBody, S.syncRestartOk);
  }

  // Draw the tab from a status object {provider, authenticated, sync_*}.
  function cloudRender(body, S, status) {
    cloudStopAuthPoll();
    body.textContent = "";

    var note = document.createElement("div");
    note.className = "lumen-note";
    note.textContent = S.intro;
    body.appendChild(note);

    var provider = status.provider || "local";
    var signedIn = !!status.authenticated;

    // ── provider select ──────────────────────────────────────────────────
    var prow = document.createElement("div");
    prow.className = "lumen-row";
    var pwrap = document.createElement("div");
    pwrap.className = "lumen-lblwrap";
    var plbl = document.createElement("div");
    plbl.className = "lbl";
    plbl.textContent = S.provider;
    pwrap.appendChild(plbl);
    prow.appendChild(pwrap);
    var pctrl = document.createElement("span");
    pctrl.className = "lumen-ctrl";
    var sel = document.createElement("select");
    [["local", S.providerNone], ["gdrive", S.providerGdrive], ["onedrive", S.providerOnedrive]]
      .forEach(function (opt) {
        var o = document.createElement("option");
        o.value = opt[0];
        o.textContent = opt[1];
        if (opt[0] === provider) o.selected = true;
        sel.appendChild(o);
      });
    sel.addEventListener("change", function () {
      var np = sel.value;
      call("LumenCloudSetProvider", { json: JSON.stringify({ provider: np }) })
        .then(function (res) {
          var r; try { r = JSON.parse(res); } catch (e) {}
          if (!r || !r.success) throw new Error((r && r.error) || "save failed");
          cloudReload(body); // re-fetch status so the sign-in section updates
        })
        .catch(function (e) { cloudShowError(body, S.saveFail + (e && e.message ? e.message : e)); });
    });
    pctrl.appendChild(sel);
    prow.appendChild(pctrl);
    body.appendChild(prow);

    // ── sign-in section (only for cloud providers) ───────────────────────
    if (provider === "local") {
      var ln = document.createElement("div");
      ln.className = "lumen-desc";
      ln.style.marginTop = "8px";
      ln.textContent = S.localNote;
      body.appendChild(ln);
    } else {

    var srow = document.createElement("div");
    srow.className = "lumen-row";
    var swrap = document.createElement("div");
    swrap.className = "lumen-lblwrap";
    var stat = document.createElement("div");
    stat.className = "lbl";
    stat.id = "lumen-cloud-status";
    stat.textContent = signedIn ? S.statusSignedIn : S.statusNotSignedIn;
    swrap.appendChild(stat);
    srow.appendChild(swrap);
    var sctrl = document.createElement("span");
    sctrl.className = "lumen-ctrl";
    var btn = document.createElement("div");
    btn.className = signedIn ? "lumen-cloud-btn secondary" : "lumen-cloud-btn";
    btn.textContent = signedIn ? S.signOut : S.signIn;
    btn.addEventListener("click", function () {
      if (signedIn) {
        call("LumenCloudSignOut", { json: JSON.stringify({ provider: provider }) })
          .then(function () { cloudReload(body); })
          .catch(function (e) { cloudShowError(body, S.saveFail + (e && e.message ? e.message : e)); });
      } else {
        cloudStartSignIn(body, S, provider, stat);
      }
    });
    sctrl.appendChild(btn);
    srow.appendChild(sctrl);
    body.appendChild(srow);

    // ── stats toggles (only meaningful once signed in, but shown regardless) ─
    var st = document.createElement("div");
    st.className = "lumen-sub-title";
    st.style.marginTop = "24px";
    st.textContent = S.statsTitle;
    body.appendChild(st);
    body.appendChild(cloudToggleRow(S.syncAchievements, S.syncAchievementsDesc,
      status.sync_achievements, function (on) { cloudStatsToggle(S, "sync_achievements", on); }));
    body.appendChild(cloudToggleRow(S.syncPlaytime, S.syncPlaytimeDesc,
      status.sync_playtime, function (on) { cloudStatsToggle(S, "sync_playtime", on); }));
    }

    // ── games list (one card per game with cloud-save data) ──────────────
    cloudRenderAppsSection(body, S);
  }

  function cloudFormatSize(bytes) {
    bytes = Number(bytes) || 0;
    if (bytes < 1024) return bytes + " B";
    var u = ["KB", "MB", "GB", "TB"], i = -1, v = bytes;
    do { v /= 1024; i++; } while (v >= 1024 && i < u.length - 1);
    return (v >= 10 ? Math.round(v) : Math.round(v * 10) / 10) + " " + u[i];
  }

  // Location/sync badge for a game card. While the remote listing for the
  // account is still being fetched (`resolved` false), show a spinner instead
  // of a premature "On this PC" — the card only settles to local/cloud/synced
  // once we actually know the remote state.
  function cloudBadge(S, app, resolved) {
    var b = document.createElement("span");
    b.className = "lumen-capsule-badge";
    if (!resolved) {
      b.classList.add("b-checking");
      var sp = document.createElement("span"); sp.className = "lumen-spin";
      var ct = document.createElement("span"); ct.textContent = S.badgeChecking;
      b.appendChild(sp); b.appendChild(ct);
      return b;
    }
    var dot = document.createElement("span"); dot.className = "d";
    var txt = document.createElement("span");
    var loc = app.local && app.remote ? "synced" : (app.remote ? "cloud" : "local");
    if (loc === "synced") { b.classList.add("b-synced"); txt.textContent = S.badgeSynced; }
    else if (loc === "cloud") { b.classList.add("b-cloud"); txt.textContent = S.badgeCloud; }
    else { b.classList.add("b-local"); txt.textContent = S.badgeLocal; }
    b.appendChild(dot); b.appendChild(txt);
    return b;
  }

  function cloudAppCard(S, app, resolved) {
    var card = document.createElement("div");
    card.className = "lumen-game";
    var head = document.createElement("div");
    head.className = "lumen-game-head";
    head.style.cursor = "default";

    var cap = document.createElement("img");
    cap.className = "lumen-cap";
    cap.loading = "lazy"; cap.decoding = "async";
    if (typeof loadCapsule === "function") loadCapsule(app.appid, cap);

    var meta = document.createElement("div");
    meta.className = "lumen-game-meta";
    var nm = document.createElement("div");
    nm.className = "lumen-game-name";
    nm.textContent = "App " + app.appid; // replaced by the store name below
    var sub = document.createElement("div");
    sub.className = "lumen-game-sub";
    sub.textContent = "ID: " + app.appid + " \u2022 " + (app.files || 0) + " " +
      S.appsFiles + " \u2022 " + cloudFormatSize(app.size);
    meta.appendChild(nm); meta.appendChild(sub);

    head.appendChild(cap); head.appendChild(meta);
    head.appendChild(cloudBadge(S, app, resolved));
    card.appendChild(head);

    // Resolve the real name (store API), like the Game Updates tab.
    if (typeof fetchAppName === "function") {
      fetchAppName(app.appid).then(function (n) { if (n) nm.textContent = n; }).catch(function () {});
    }
    return card;
  }

  // Merge local scanner records with structured provider records for one Steam
  // account. Local figures remain authoritative for synced games; only a game
  // that has no local record uses the remote logical file count and byte size.
  function cloudMergeApps(allApps, remoteSet, account) {
    var localList = allApps.filter(function (a) {
      return account == null || a.account === account;
    });
    var localIds = {};
    var out = localList.map(function (a) {
      localIds[a.appid] = true;
      return {
        appid: a.appid,
        account: a.account,
        files: a.files,
        size: a.size,
        local: true,
        remote: !!(remoteSet && remoteSet[a.appid]),
      };
    });
    if (remoteSet) {
      Object.keys(remoteSet).forEach(function (idStr) {
        var id = Number(idStr);
        if (!localIds[id]) {
          var remote = remoteSet[idStr] || {};
          out.push({
            appid: id,
            account: account,
            files: Number(remote.files) || 0,
            size: Number(remote.size) || 0,
            local: false,
            remote: true,
          });
        }
      });
    }
    return out;
  }

  // Render the games list into its own section under the settings. Fetches the
  // unified app list (LumenCloudApps), with a search box that filters by name or
  // app id. Kept in a dedicated container so a re-render doesn't touch the rest.
  function cloudRenderAppsSection(body, S) {
    var title = document.createElement("div");
    title.className = "lumen-sub-title";
    title.style.marginTop = "24px";
    title.textContent = S.appsTitle;
    body.appendChild(title);

    var search = document.createElement("input");
    search.type = "text";
    search.className = "lumen-cloud-search";
    search.placeholder = S.appsSearch;
    body.appendChild(search);

    // Account filter — a small, discrete filter chip (person icon + compact
    // dropdown), shown ONLY when saves exist under 2+ Steam accounts. Sits
    // below the search. Populated after the fetch; defaults to the account with
    // the most save data.
    var acctRow = document.createElement("div");
    acctRow.className = "lumen-cloud-acct";
    acctRow.style.display = "none";
    var acctIco = document.createElement("span");
    acctIco.className = "fico";
    acctIco.innerHTML = '<svg viewBox="0 0 16 16" width="13" height="13">' +
      '<path fill="currentColor" d="M8 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6zm0 1.5' +
      'c-2.9 0-5.2 1.5-5.2 3.3V14h10.4v-1.2c0-1.8-2.3-3.3-5.2-3.3z"/></svg>';
    var acctSel = document.createElement("select");
    acctSel.className = "lumen-cloud-acctsel";
    acctRow.appendChild(acctIco);
    acctRow.appendChild(acctSel);
    body.appendChild(acctRow);

    var list = document.createElement("div");
    list.textContent = S.appsLoading;
    body.appendChild(list);

    var allApps = [];          // local apps (per Steam account)
    var nameCache = {};
    var remoteSets = {};       // account id -> { appid: {appid,files,size} }
    var currentAccount = null; // selected account id (null = show all)

    // Build the merged view for the current account: local apps annotated with
    // whether they also exist remotely, plus remote-only games as extra cards.
    function mergedApps() {
      var acct = currentAccount;
      var rset = (acct != null && remoteSets[acct]) || null;
      return cloudMergeApps(allApps, rset, acct);
    }

    function draw() {
      var q = (search.value || "").trim().toLowerCase();
      // Remote state for the selected account is "resolved" once its fetch has
      // completed (remoteSets[account] set, even to an empty set). Until then the
      // cards show a spinner instead of a premature location badge.
      var resolved = currentAccount != null && remoteSets[currentAccount] !== undefined;
      list.textContent = "";
      var shown = mergedApps().filter(function (a) {
        // Hide empty local-only entries (an app folder CloudRedirect created but
        // with no actual save data). Anything with saves, or present in the
        // cloud, is kept.
        if ((a.files || 0) <= 0 && !a.remote) return false;
        if (!q) return true;
        var n = (nameCache[a.appid] || "").toLowerCase();
        return String(a.appid).indexOf(q) !== -1 || n.indexOf(q) !== -1;
      });
      shown.sort(function (a, b) { return a.appid - b.appid; });
      if (shown.length === 0) {
        var empty = document.createElement("div");
        empty.className = "lumen-empty";
        // A search that matched nothing shows a dash; an account with no saves
        // at all shows the friendly "nothing here yet" message.
        empty.textContent = q ? "\u2014" : S.appsNone;
        list.appendChild(empty);
        return;
      }
      shown.forEach(function (a) { list.appendChild(cloudAppCard(S, a, resolved)); });
    }

    // Fetch remote appids for an account once (cached), then redraw. Failures
    // (not signed in / offline) are non-fatal: the list just stays local-only.
    function ensureRemote(account) {
      if (account == null || remoteSets[account]) { draw(); return; }
      var localAppids = allApps
        .filter(function (a) { return a.account === account; })
        .map(function (a) { return a.appid; });
      call("LumenCloudRemoteApps", {
        json: JSON.stringify({ account: account, local_appids: localAppids }),
      })
        .then(function (res) {
          var r; try { r = JSON.parse(res); } catch (e) {}
          var set = {};
          var records = [];
          if (r && r.success && Array.isArray(r.apps)) {
            records = r.apps;
          } else if (r && r.success && Array.isArray(r.appids)) {
            records = r.appids.map(function (id) { return { appid: id, files: 0, size: 0 }; });
          }
          records.forEach(function (app) {
            var id = Number(app.appid);
            if (id) set[id] = { appid: id, files: app.files || 0, size: app.size || 0 };
          });
          remoteSets[account] = set;
          if (r && r.success && typeof fetchAppName === "function") {
            records.forEach(function (app) {
              var id = Number(app.appid);
              fetchAppName(id).then(function (n) { if (n) nameCache[id] = n; }).catch(function () {});
            });
          }
          draw();
        })
        .catch(function () { remoteSets[account] = {}; draw(); });
    }

    search.addEventListener("input", draw);
    acctSel.addEventListener("change", function () {
      currentAccount = Number(acctSel.value);
      draw();
      ensureRemote(currentAccount);
    });

    call("LumenCloudApps", {})
      .then(function (res) {
        var r; try { r = JSON.parse(res); } catch (e) {}
        if (!r || !r.success) throw new Error((r && r.error) || "load failed");
        allApps = r.apps || [];
        var accounts = r.accounts || [];
        if (accounts.length >= 1) currentAccount = accounts[0].id; // default account
        if (accounts.length >= 2) {
          accounts.forEach(function (ac) {
            var o = document.createElement("option");
            o.value = String(ac.id);
            o.textContent = ac.name && ac.name.length ? ac.name : ("Account #" + ac.id);
            acctSel.appendChild(o);
          });
          acctSel.value = String(currentAccount);
          acctRow.style.display = "";
        }
        draw();                 // local first (instant)
        ensureRemote(currentAccount); // then annotate/add remote (async)
        if (typeof fetchAppName === "function") {
          allApps.forEach(function (a) {
            fetchAppName(a.appid).then(function (n) { if (n) nameCache[a.appid] = n; }).catch(function () {});
          });
        }
      })
      .catch(function (e) {
        list.textContent = "";
        var err = document.createElement("div");
        err.className = "lumen-err";
        err.textContent = S.appsLoadFail + (e && e.message ? e.message : e);
        list.appendChild(err);
      });
  }

  function cloudShowError(body, msg) {
    body.textContent = "";
    var err = document.createElement("div");
    err.className = "lumen-err";
    err.textContent = msg;
    body.appendChild(err);
  }

  // Open the OAuth page in the default browser so it comes to the FOREGROUND.
  // Route through Steam's own handler (__lumenOpenExternalUrl relay -> SteamClient
  // in SharedJSContext): Steam is the focused app, so it raises the browser. A
  // bare backend xdg-open from the sidecar can't (no focus-activation token under
  // Wayland). Fall back to the backend opener only if the relay can't run.
  function cloudOpenAuthUrl(url) {
    if (!url) return;
    call("__lumenOpenExternalUrl", { url: url })
      .then(function (res) {
        var ok = false;
        try { ok = JSON.parse(res).ok; } catch (e) {}
        if (!ok) call("LumenCloudOpenUrl", { json: JSON.stringify({ url: url }) }).catch(function () {});
      })
      .catch(function () {
        call("LumenCloudOpenUrl", { json: JSON.stringify({ url: url }) }).catch(function () {});
      });
  }

  // Kick off the OAuth flow: authorize, open the browser (focused), then poll
  // until done/timeout/error.
  function cloudStartSignIn(body, S, provider, statusEl) {
    statusEl.textContent = S.signingIn;
    call("LumenCloudAuthorize", { json: JSON.stringify({ provider: provider }) })
      .then(function (res) {
        var r; try { r = JSON.parse(res); } catch (e) {}
        if (!r || r.status === "error") throw new Error((r && r.error) || "authorize failed");
        cloudOpenAuthUrl(r.auth_url);
        cloudPollAuth(body, S, statusEl);
      })
      .catch(function (e) { statusEl.textContent = S.signInFail + (e && e.message ? e.message : e); });
  }

  function cloudPollAuth(body, S, statusEl) {
    cloudStopAuthPoll();
    _cloudAuthTimer = setTimeout(function () {
      call("LumenCloudAuthPoll", {})
        .then(function (res) {
          var r; try { r = JSON.parse(res); } catch (e) {}
          if (!r) throw new Error("poll failed");
          if (r.status === "waiting") { cloudPollAuth(body, S, statusEl); return; }
          cloudStopAuthPoll();
          if (r.status === "done") { statusEl.textContent = S.signInDone; cloudReload(body); }
          else if (r.status === "timeout") { statusEl.textContent = S.signInTimeout; }
          else { statusEl.textContent = S.signInFail + (r.error || r.status); }
        })
        .catch(function (e) {
          cloudStopAuthPoll();
          statusEl.textContent = S.signInFail + (e && e.message ? e.message : e);
        });
    }, 1000);
  }

  // Fetch status and (re)draw. The public entry point the overlay calls.
  function cloudReload(body) {
    var S = cloudStrings();
    cloudStopAuthPoll();
    call("LumenCloudStatus", {})
      .then(function (res) {
        var status; try { status = JSON.parse(res); } catch (e) {}
        if (!status || !status.success) throw new Error((status && status.error) || "load failed");
        cloudRender(body, S, status);
      })
      .catch(function (e) { cloudShowError(body, S.loadFail + (e && e.message ? e.message : e)); });
  }

  function renderCloud(body) {
    body.textContent = "Loading\u2026";
    cloudReload(body);
  }
