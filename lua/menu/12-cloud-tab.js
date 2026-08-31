// LM-FRAGMENT Cloud Saves tab (renderCloud) — CloudRedirect setup in-menu
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.
//
// Cloud settings use a draft: provider, credentials and activity sync are
// committed together only by "Save and restart". The running hook therefore
// never disagrees with a half-applied settings screen.

  // Poll handle for an in-flight sign-in, so switching tabs / re-rendering
  // cancels it instead of leaking a timer.
  var _cloudAuthTimer = null;
  var _cloudApplied = null;
  var _cloudDraft = null;
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

  function cloudClone(value) {
    return JSON.parse(JSON.stringify(value == null ? {} : value));
  }

  function cloudMakeDraft(status) {
    var providers = status.providers || {};
    var authenticated = {};
    var settings = {};
    ["local", "folder", "gdrive", "onedrive", "r2", "s3"].forEach(function (name) {
      authenticated[name] = !!(providers[name] && providers[name].authenticated);
      settings[name] = cloudClone(providers[name] && providers[name].settings || {});
    });
    return {
      provider: status.provider || "local",
      sync_activity: status.sync_activity === true,
      authenticated: authenticated,
      settings: settings,
      sign_out_provider: null,
    };
  }

  function cloudComparableDraft(draft) {
    var provider = draft.provider;
    return {
      provider: provider,
      sync_activity: !!draft.sync_activity,
      sign_out_provider: draft.sign_out_provider || null,
      settings: (provider === "folder" || provider === "r2" || provider === "s3")
        ? draft.settings[provider] || {} : {},
      authenticated: {
        gdrive: !!draft.authenticated.gdrive,
        onedrive: !!draft.authenticated.onedrive,
      },
    };
  }

  function cloudDraftDirty() {
    if (!_cloudDraft || !_cloudApplied) return false;
    return JSON.stringify(cloudComparableDraft(_cloudDraft)) !==
      JSON.stringify(cloudComparableDraft(cloudMakeDraft(_cloudApplied)));
  }

  function cloudDraftRequest() {
    var provider = _cloudDraft.provider;
    var request = {
      provider: provider,
      sync_activity: !!_cloudDraft.sync_activity,
    };
    if (_cloudDraft.sign_out_provider) request.sign_out_provider = _cloudDraft.sign_out_provider;
    if (provider === "folder") {
      request.sync_folder_path = (_cloudDraft.settings.folder || {}).sync_folder_path || "";
    } else if (provider === "r2" || provider === "s3") {
      request.credentials = cloudClone(_cloudDraft.settings[provider] || {});
      delete request.credentials.has_secret;
    }
    return request;
  }

  function cloudTextRow(labelText, value, placeholder, secret, onInput) {
    var row = document.createElement("div"); row.className = "lumen-row";
    var wrap = document.createElement("div"); wrap.className = "lumen-lblwrap";
    var label = document.createElement("div"); label.className = "lbl"; label.textContent = labelText;
    wrap.appendChild(label); row.appendChild(wrap);
    var ctrl = document.createElement("span"); ctrl.className = "lumen-ctrl";
    var input = document.createElement("input"); input.type = secret ? "password" : "text";
    input.value = value || ""; input.placeholder = placeholder || "";
    input.addEventListener("input", function () { onInput(input.value); cloudRefreshDraftActions(); });
    ctrl.appendChild(input); row.appendChild(ctrl); return row;
  }

  var _cloudActions = null;
  function cloudRefreshDraftActions() {
    if (!_cloudActions) return;
    _cloudActions.style.display = cloudDraftDirty() ? "flex" : "none";
  }

  function cloudPendingApps(body, S) {
    var title = document.createElement("div"); title.className = "lumen-sub-title";
    title.style.marginTop = "24px"; title.textContent = S.appsTitle; body.appendChild(title);
    var note = document.createElement("div"); note.className = "lumen-cloud-pending";
    var strong = document.createElement("div"); strong.className = "lbl"; strong.textContent = S.pendingTitle;
    var desc = document.createElement("div"); desc.className = "lumen-desc"; desc.textContent = S.pendingBody;
    note.appendChild(strong); note.appendChild(desc); body.appendChild(note);
  }

  function cloudRenderActions(body, S) {
    var actions = document.createElement("div"); actions.className = "lumen-cloud-actions";
    var label = document.createElement("span"); label.textContent = S.pendingTitle;
    var buttons = document.createElement("span"); buttons.className = "lumen-cloud-action-buttons";
    var cancel = document.createElement("div"); cancel.className = "lumen-cloud-btn secondary";
    cancel.textContent = S.cancelChanges;
    cancel.addEventListener("click", function () {
      call("LumenCloudDiscardPending", {}).catch(function () {}).then(function () {
        _cloudDraft = null; return cloudReload(body);
      });
    });
    var save = document.createElement("div"); save.className = "lumen-cloud-btn";
    save.textContent = S.saveRestart;
    save.addEventListener("click", function () {
      if (save.classList.contains("busy")) return;
      var source = _cloudApplied && _cloudApplied.provider || "local";
      if (source !== "local" && _cloudDraft.provider !== "local" &&
          source !== _cloudDraft.provider) {
        cloudConfirmMigration(body, S, save, source, _cloudDraft.provider);
      } else {
        cloudApplyDraft(body, S, save, false);
      }
    });
    buttons.appendChild(cancel); buttons.appendChild(save);
    actions.appendChild(label); actions.appendChild(buttons); body.appendChild(actions);
    _cloudActions = actions; cloudRefreshDraftActions();
  }

  function cloudProviderLabel(S, provider) {
    return {
      local: S.providerNone, folder: S.providerFolder, gdrive: S.providerGdrive,
      onedrive: S.providerOnedrive, r2: S.providerR2, s3: S.providerS3,
    }[provider] || provider;
  }

  function cloudApplyDraft(body, S, save, migrate) {
    save.classList.add("busy"); save.textContent = migrate ? S.migrating : S.applyBusy;
    var progress = migrate ? showProgress(S.migrationTitle) : null;
    if (progress) progress.update(S.migrating);
    var request = cloudDraftRequest();
    request.migrate = migrate === true;
    return call("LumenCloudApplyAndRestart", { json: JSON.stringify(request) })
      .then(function (raw) {
        var result; try { result = JSON.parse(raw); } catch (e) {}
        if (!result || !result.success) throw new Error(result && result.error || "apply failed");
      })
      .catch(function (e) {
        if (progress) progress.close();
        save.classList.remove("busy"); save.textContent = S.saveRestart;
        aboutModal(S.pendingTitle, S.saveFail + (e && e.message ? e.message : e), S.syncRestartOk);
      });
  }

  function cloudConfirmMigration(body, S, save, source, destination) {
    injectStyles();
    var back = document.createElement("div"); back.className = "lumen-modal-back";
    var card = document.createElement("div"); card.className = "lumen-modal";
    var title = document.createElement("div"); title.className = "mt";
    title.textContent = S.migrationTitle;
    var copy = document.createElement("div"); copy.className = "mb";
    copy.textContent = S.migrationBody
      .replace("{source}", cloudProviderLabel(S, source))
      .replace("{destination}", cloudProviderLabel(S, destination));
    var row = document.createElement("div"); row.className = "mrow";
    var close = function () { if (back.parentNode) back.remove(); };
    var cancel = document.createElement("button"); cancel.className = "lumen-mbtn";
    cancel.textContent = S.cancelChanges; cancel.addEventListener("click", close);
    var skip = document.createElement("button"); skip.className = "lumen-mbtn";
    skip.textContent = S.switchWithoutMigration;
    skip.addEventListener("click", function () { close(); cloudApplyDraft(body, S, save, false); });
    var move = document.createElement("button"); move.className = "lumen-mbtn primary";
    move.textContent = S.migrateAndContinue;
    move.addEventListener("click", function () { close(); cloudApplyDraft(body, S, save, true); });
    row.appendChild(cancel); row.appendChild(skip); row.appendChild(move);
    card.appendChild(title); card.appendChild(copy); card.appendChild(row); back.appendChild(card);
    (document.body || document.documentElement).appendChild(back);
  }

  function cloudRenderProviderSettings(body, S, provider) {
    var current = _cloudDraft.settings[provider] || (_cloudDraft.settings[provider] = {});
    if (provider === "folder") {
      body.appendChild(cloudTextRow(S.folderPath, current.sync_folder_path,
        "/mnt/cloud-saves", false, function (value) { current.sync_folder_path = value; }));
      var hint = document.createElement("div"); hint.className = "lumen-desc";
      hint.textContent = S.folderPathHint; body.appendChild(hint); return;
    }
    if (provider !== "r2" && provider !== "s3") return;
    if (provider === "r2") {
      body.appendChild(cloudTextRow(S.accountId, current.account_id, "", false,
        function (value) { current.account_id = value; }));
    }
    if (provider === "s3") {
      body.appendChild(cloudTextRow(S.endpoint, current.endpoint, "s3.example.com", false,
        function (value) { current.endpoint = value; }));
      body.appendChild(cloudTextRow(S.region, current.region, "us-east-1", false,
        function (value) { current.region = value; }));
    }
    body.appendChild(cloudTextRow(S.accessKey, current.access_key_id, "", false,
      function (value) { current.access_key_id = value; }));
    body.appendChild(cloudTextRow(S.secretKey, "", current.has_secret ? S.secretStored : "", true,
      function (value) { current.secret_access_key = value; }));
    body.appendChild(cloudTextRow(S.bucket, current.bucket, "", false,
      function (value) { current.bucket = value; }));
    body.appendChild(cloudTextRow(S.keyPrefix, current.key_prefix, "cloudredirect/", false,
      function (value) { current.key_prefix = value; }));
    if (provider === "r2") {
      body.appendChild(cloudTextRow(S.r2Endpoint, current.endpoint,
        "<account>.r2.cloudflarestorage.com", false,
        function (value) { current.endpoint = value; }));
      return;
    }
    var advanced = document.createElement("div"); advanced.className = "lumen-sub-title";
    advanced.style.marginTop = "20px"; advanced.textContent = S.advancedSettings;
    body.appendChild(advanced);
    body.appendChild(cloudToggleRow(S.s3SignPayload, S.s3SignPayloadDesc,
      current.sign_payload === true, function (on) {
        current.sign_payload = on; cloudRefreshDraftActions();
      }));
    body.appendChild(cloudToggleRow(S.s3AllowInsecureHttp, S.s3AllowInsecureHttpDesc,
      current.allow_insecure_http === true, function (on) {
        current.allow_insecure_http = on; cloudRefreshDraftActions();
      }));
    body.appendChild(cloudToggleRow(S.s3AllowInsecureTls, S.s3AllowInsecureTlsDesc,
      current.allow_insecure_tls === true, function (on) {
        current.allow_insecure_tls = on; cloudRefreshDraftActions();
      }));
    body.appendChild(cloudTextRow(S.s3CaCertPath, current.ca_cert_path,
      "/path/to/ca.pem", false, function (value) { current.ca_cert_path = value; }));
  }

  // Draw the tab from the applied status plus the in-memory draft.
  function cloudRender(body, S, status) {
    cloudStopAuthPoll();
    body.textContent = "";
    _cloudApplied = status;
    if (!_cloudDraft) _cloudDraft = cloudMakeDraft(status);

    var note = document.createElement("div");
    note.className = "lumen-note";
    note.textContent = S.intro;
    body.appendChild(note);

    var provider = _cloudDraft.provider;
    var signedIn = !!_cloudDraft.authenticated[provider];

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
    [["local", S.providerNone], ["folder", S.providerFolder],
     ["gdrive", S.providerGdrive], ["onedrive", S.providerOnedrive],
     ["r2", S.providerR2], ["s3", S.providerS3]]
      .forEach(function (opt) {
        var o = document.createElement("option");
        o.value = opt[0];
        o.textContent = opt[1];
        if (opt[0] === provider) o.selected = true;
        sel.appendChild(o);
      });
    sel.addEventListener("change", function () {
      if (_cloudDraft.sign_out_provider) {
        var signedOut = _cloudDraft.sign_out_provider;
        var appliedProvider = _cloudApplied.providers && _cloudApplied.providers[signedOut];
        _cloudDraft.authenticated[signedOut] = !!(appliedProvider && appliedProvider.authenticated);
      }
      _cloudDraft.provider = sel.value;
      _cloudDraft.sign_out_provider = null;
      cloudRender(body, S, status);
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
    } else if (provider === "gdrive" || provider === "onedrive") {

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
        _cloudDraft.sign_out_provider = provider;
        _cloudDraft.authenticated[provider] = false;
        _cloudDraft.provider = "local";
        cloudRender(body, S, status);
      } else {
        cloudStartSignIn(body, S, provider, stat, status);
      }
    });
    sctrl.appendChild(btn);
    srow.appendChild(sctrl);
    body.appendChild(srow);

    } else {
      cloudRenderProviderSettings(body, S, provider);
    }

    if (provider !== "local") {
    var st = document.createElement("div");
    st.className = "lumen-sub-title";
    st.style.marginTop = "24px";
    st.textContent = S.statsTitle;
    body.appendChild(st);
    body.appendChild(cloudToggleRow(S.syncActivity, S.syncActivityDesc,
      _cloudDraft.sync_activity, function (on) {
        _cloudDraft.sync_activity = on; cloudRefreshDraftActions();
      }));
    }

    cloudRenderActions(body, S);
    if (cloudDraftDirty()) { cloudPendingApps(body, S); return Promise.resolve(); }
    return cloudRenderAppsSection(body, S, status);
  }

  function cloudFormatSize(bytes) {
    bytes = Number(bytes) || 0;
    if (bytes < 1024) return bytes + " B";
    var u = ["KB", "MB", "GB", "TB"], i = -1, v = bytes;
    do { v /= 1024; i++; } while (v >= 1024 && i < u.length - 1);
    return (v >= 10 ? Math.round(v) : Math.round(v * 10) / 10) + " " + u[i];
  }

  function cloudBadgeKind(app, resolved) {
    if (!resolved) return "checking";
    if (app.local && app.remote) return "both";
    return app.remote ? "cloud" : "local";
  }

  // Presence in both places is deliberately neutral: it does not prove equal
  // CNs/manifests and must never be presented as "Synced".
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
    var loc = cloudBadgeKind(app, resolved);
    if (loc === "both") { b.classList.add("b-both"); txt.textContent = S.badgeBoth; }
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
    sub.textContent = "ID: " + app.appid;
    if (app.statsKnown !== false) {
      sub.textContent += " \u2022 " + (app.files || 0) + " " + S.appsFiles
        + " \u2022 " + cloudFormatSize(app.size);
    }
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
        statsKnown: true,
        local: true,
        remote: !!(remoteSet && remoteSet[a.appid]),
      };
    });
    if (remoteSet) {
      Object.keys(remoteSet).forEach(function (idStr) {
        var id = Number(idStr);
        if (!localIds[id]) {
          var remote = remoteSet[idStr] || {};
          var statsKnown = remote.statsKnown === true
            || remote.files != null || remote.size != null;
          out.push({
            appid: id,
            account: account,
            files: statsKnown ? (Number(remote.files) || 0) : null,
            size: statsKnown ? (Number(remote.size) || 0) : null,
            statsKnown: statsKnown,
            local: false,
            remote: true,
          });
        }
      });
    }
    return out;
  }

  function cloudAppsResolved(account, remoteSets) {
    return account == null || remoteSets[account] !== undefined;
  }

  function cloudRemoteSet(records) {
    var set = {};
    (Array.isArray(records) ? records : []).forEach(function (record) {
      var item = typeof record === "object" && record !== null ? record : { appid: record };
      var id = Number(item.appid);
      if (!id) return;
      var statsKnown = item.files != null || item.size != null;
      set[id] = {
        appid: id,
        files: statsKnown ? (Number(item.files) || 0) : null,
        size: statsKnown ? (Number(item.size) || 0) : null,
        statsKnown: statsKnown,
      };
    });
    return set;
  }

  // Render the games list into its own section under the settings. Fetches the
  // unified app list (LumenCloudApps), with a search box that filters by name or
  // app id. Kept in a dedicated container so a re-render doesn't touch the rest.
  function cloudRenderAppsSection(body, S, status) {
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
    var remoteErrors = {};
    var remotePending = {};
    var currentAccount = null; // selected account id (null = show all)
    var provider = status && status.provider || "local";
    var remoteEnabled = provider !== "local" && status && status.authenticated === true;

    // Build the merged view for the current account: local apps annotated with
    // whether they also exist remotely, plus remote-only games as extra cards.
    function mergedApps() {
      var acct = currentAccount;
      var rset = (acct != null && remoteSets[acct]) || null;
      return cloudMergeApps(allApps, rset, acct);
    }

    function draw() {
      var q = (search.value || "").trim().toLowerCase();
      if (currentAccount != null && remoteErrors[currentAccount]) {
        list.textContent = "";
        var remoteErr = document.createElement("div"); remoteErr.className = "lumen-err";
        remoteErr.textContent = S.appsRemoteFail + remoteErrors[currentAccount];
        list.appendChild(remoteErr); return;
      }
      // Remote state for the selected account is "resolved" once its fetch has
      // completed (remoteSets[account] set, even to an empty set). Keep the
      // section's loading state until then so the user sees one complete,
      // stable list instead of one local card followed by a remote-list jump.
      if (!cloudAppsResolved(currentAccount, remoteSets)) {
        list.textContent = S.appsLoading;
        return;
      }
      var resolved = true;
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
    function ensureRemote(account, refresh) {
      if (account == null) { draw(); return Promise.resolve(); }
      if (!remoteEnabled) {
        if (provider === "local") remoteSets[account] = {};
        else remoteErrors[account] = S.statusNotSignedIn;
        draw();
        return Promise.resolve(remoteSets[account] || null);
      }
      if (remotePending[account]) return remotePending[account];
      if (remoteSets[account] && !refresh) { draw(); return Promise.resolve(remoteSets[account]); }
      var localAppids = allApps
        .filter(function (a) { return a.account === account; })
        .map(function (a) { return a.appid; });
      remotePending[account] = call("LumenCloudRemoteApps", {
        json: JSON.stringify({ account: account, local_appids: localAppids }),
      })
        .then(function (res) {
          var r; try { r = JSON.parse(res); } catch (e) {}
          if (!r || !r.success) throw new Error((r && r.error) || "remote list failed");
          var records = [];
          if (Array.isArray(r.apps)) {
            records = r.apps;
          } else if (Array.isArray(r.appids)) {
            records = r.appids;
          }
          var set = cloudRemoteSet(records);
          delete remoteErrors[account];
          remoteSets[account] = set;
          if (typeof fetchAppName === "function") {
            Object.keys(set).forEach(function (rawId) {
              var id = Number(rawId);
              fetchAppName(id).then(function (n) { if (n) nameCache[id] = n; }).catch(function () {});
            });
          }
          draw();
          return set;
        })
        .catch(function (error) {
          delete remoteSets[account];
          remoteErrors[account] = error && error.message ? error.message : String(error);
          draw();
          return null;
        })
        .then(function (set) { remotePending[account] = null; return set; });
      return remotePending[account];
    }

    search.addEventListener("input", draw);
    acctSel.addEventListener("change", function () {
      currentAccount = Number(acctSel.value);
      draw();
      ensureRemote(currentAccount, true);
    });

    return call("LumenCloudApps", {})
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
        draw();
        if (typeof fetchAppName === "function") {
          allApps.forEach(function (a) {
            fetchAppName(a.appid).then(function (n) { if (n) nameCache[a.appid] = n; }).catch(function () {});
          });
        }
        return ensureRemote(currentAccount, true);
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
  function cloudStartSignIn(body, S, provider, statusEl, appliedStatus) {
    statusEl.textContent = S.signingIn;
    call("LumenCloudAuthorize", { json: JSON.stringify({ provider: provider }) })
      .then(function (res) {
        var r; try { r = JSON.parse(res); } catch (e) {}
        if (!r || r.status === "error") throw new Error((r && r.error) || "authorize failed");
        cloudOpenAuthUrl(r.auth_url);
        cloudPollAuth(body, S, provider, statusEl, appliedStatus);
      })
      .catch(function (e) { statusEl.textContent = S.signInFail + (e && e.message ? e.message : e); });
  }

  function cloudPollAuth(body, S, provider, statusEl, appliedStatus) {
    cloudStopAuthPoll();
    _cloudAuthTimer = setTimeout(function () {
      call("LumenCloudAuthPoll", {})
        .then(function (res) {
          var r; try { r = JSON.parse(res); } catch (e) {}
          if (!r) throw new Error("poll failed");
          if (r.status === "waiting") {
            cloudPollAuth(body, S, provider, statusEl, appliedStatus); return;
          }
          cloudStopAuthPoll();
          if (r.status === "done") {
            _cloudDraft.authenticated[provider] = true;
            _cloudDraft.sign_out_provider = null;
            cloudRender(body, S, appliedStatus);
          }
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
    return call("LumenCloudStatus", {})
      .then(function (res) {
        var status; try { status = JSON.parse(res); } catch (e) {}
        if (!status || !status.success) throw new Error((status && status.error) || "load failed");
        return cloudRender(body, S, status);
      })
      .catch(function (e) { cloudShowError(body, S.loadFail + (e && e.message ? e.message : e)); });
  }

  function renderCloud(body) {
    body.textContent = "Loading\u2026";
    return cloudReload(body);
  }
