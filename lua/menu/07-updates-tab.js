// LM-FRAGMENT Game Updates tab (renderDlcSubpage, gameCard, renderGameUpdates)
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

  // Reference to the header "Clear stored versions" button (created in the
  // overlay fragment, 09). The advanced/Depots subpage hides it and shows its
  // own per-game "Delete all" instead; returning to the list restores it.
  var _guClearBtnRef = null;
  var _guClearBtnWanted = true;
  var _guTabActive = false;
  var _providersOffline = false;
  function guShowClearBtn(show) {
    _guClearBtnWanted = !!show;
    if (_guClearBtnRef) {
      _guClearBtnRef.style.display = (_guTabActive && _guClearBtnWanted) ? "" : "none";
    }
  }
  function guSetTabActive(active) {
    _guTabActive = !!active;
    guShowClearBtn(_guClearBtnWanted);
  }

  // Advanced per-component sub-page: each depot is independently pinnable
  // (SetDlcPin / ClearDlcPin). Local appinfo identifies base, DLC and shared
  // content; DLC display names are resolved through their associated AppID.
  // Master-detail: a back arrow returns to the list.
  function renderDlcSubpage(body, game, onBack) {
    var GU = guStrings();
    body.textContent = "";
    // The per-game "Delete all" lives here; hide the header's global clear
    // button while in this subpage so the two don't compete.
    guShowClearBtn(false);
    guOwnList(null);
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
      name.textContent = depotLabel(d, game);
      if (d.dlcAppid) {
        fetchAppName(d.dlcAppid).then(function (dlcName) {
          if (dlcName) name.textContent = dlcName;
        });
      }
      var depotId = document.createElement("div");
      depotId.className = "lumen-depot-id";
      depotId.textContent = "DepotID " + d.depot;
      meta.appendChild(name);
      meta.appendChild(depotId);
      head.appendChild(meta);
      body.appendChild(head);

      var vers = document.createElement("div");
      vers.className = "lumen-vers";
      var anyPinned = d.versions.some(function (v) { return v.pinned; });
      var hasInstalled = d.versions.some(function (v) { return v.installed; });
      var rows = [];
      var select = function (target) {
        rows.forEach(function (r) { r.classList.toggle("sel", r === target); });
      };

      var latest = verRow({
        label: GU.latest, selected: !anyPinned && !_providersOffline && !game.synthetic,
        disabled: _providersOffline || game.synthetic,
        synthetic: game.synthetic,
        onClick: function () {
          call("ClearDlcPin", { json: JSON.stringify({ appid: game.appid, depot: d.depot }) })
            .then(function () {
              invalidateGameUpdatesCache();
              select(latest);
              if (isGameInstalled(game)) showValidatePrompt(game.appid);
            })
            .catch(function (e) { log("ClearDlcPin", e); });
        },
      });
      rows.push(latest);
      vers.appendChild(latest);

      d.versions.forEach(function (v) {
        var badges = [];
        if (v.pinned) badges.push({ cls: "lock", text: GU.pinned });
        if (v.installed) badges.push({ cls: "cur", text: GU.current });
        if (v.fromLuaTools) badges.push({ cls: "lt", text: game.fromLuaFile ? GU.fromLuaFile : GU.fromLua });
        var isSelected = v.pinned || ((_providersOffline || game.synthetic) && !anyPinned && (v.installed || (!hasInstalled && v.fromLuaTools)));
        var row = verRow({
          label: fmtDate(v.date), gid: v.gid, selected: isSelected, badges: badges,
          onClick: function () {
            var applyPin = function () {
              return call("SetDlcPin", { json: JSON.stringify({ appid: game.appid, depot: d.depot, gid: v.gid }) })
                .then(function () { invalidateGameUpdatesCache(); select(row); });
            };
            if (isGameInstalled(game)) {
              applyPinForInstalledGame(game.appid, applyPin, !v.installed);
            } else {
              showPinRestartPrompt(applyPin);
            }
          },
        });
        rows.push(row);
        vers.appendChild(row);
        // Trash: drop this archived version's manifest (frees space). Not offered
        // for installed/pinned versions, nor the LuaTools build (removed only via
        // the LuaTools menu) — those are still needed on disk.
        if (!v.installed && !v.pinned && !(v.fromLuaTools && !game.fromLuaFile)) {
          var del = document.createElement("span");
          del.className = "lumen-del";
          del.textContent = "\uD83D\uDDD1";
          del.title = GU.delTitle;
          del.addEventListener("click", function (e) {
            e.stopPropagation();
            call("DeleteManifest", { json: JSON.stringify({
              appid: game.appid, depot: d.depot, gid: v.gid,
            }) })
              .then(function () {
                invalidateGameUpdatesCache();
                if (row.parentNode) row.remove();
              })
              .catch(function (er) { log("DeleteManifest", er); });
          });
          row.appendChild(del);
        }
      });
      body.appendChild(vers);
    });

    // Per-game "Delete all", at the bottom of the subpage. Load-.lua game ->
    // full removal (game disappears); LuaTools game -> delete extra stored
    // versions, keep the LuaTools build and warn that full removal happens from
    // the LuaTools menu.
    var actions = document.createElement("div");
    actions.className = "lumen-gu-actions lumen-del-all-row";
    var delAll = document.createElement("button");
    delAll.className = "lumen-mbtn lumen-del-all";
    delAll.textContent = GU.deleteAll;
    delAll.title = GU.deleteAllHint;
    delAll.addEventListener("click", function () {
      var isLua = !!game.fromLuaFile;
      showConfirm({
        title: isLua ? GU.delAllLuaTitle : GU.delAllLtTitle,
        body: isLua ? GU.delAllLuaBody : GU.delAllLtBody,
        confirmText: GU.deleteConfirm, declineText: GU.deleteCancel,
        onConfirm: function () {
          call("DeleteAll", { json: JSON.stringify({ appid: game.appid }) })
            .then(function (res) {
              var r = JSON.parse(res);
              if (!r || !r.success) throw new Error((r && r.error) || GU.delFail);
              invalidateGameUpdatesCache();
              onBack();  // back to the list (the game may be gone now)
            })
            .catch(function (e) { log("DeleteAll", e); alert((e && e.message) || GU.delFail); });
        },
      });
    });
    actions.appendChild(delAll);
    body.appendChild(actions);
  }

  // One game card: capsule + name + a subtle "Advanced" link. The build
  // timeline shows inline by default (collapsed to a few rows + Show more), so
  // picking a version is the obvious action and "Advanced" (per-depot
  // overrides) stays low-key.
  function gameCard(game) {
    var GU = guStrings();
    var wrap = document.createElement("div");
    wrap.className = "lumen-game";

    var head = document.createElement("div");
    head.className = "lumen-game-head";
    head.style.cursor = "pointer";
    // Clicking the card (capsule / name) opens the game's library page. The
    // "Advanced" link stops propagation, and the version rows live outside head,
    // so they keep their own behaviour.
    head.addEventListener("click", function () {
      call("__lumenOpenLibraryApp", { appid: game.appid }).catch(function (e) { log("openLibrary", e); });
    });
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
    nm.textContent = game.name || ("App " + game.appid);
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
      renderDlcSubpage(vers.__bodyRef, game, function () { renderGameUpdates(vers.__bodyRef); });
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
    var hasInstalledBuild = builds.some(function (b) { return b.installed; });
    var rows = [];
    var select = function (target) {
      rows.forEach(function (r) { r.classList.toggle("sel", r === target); });
    };

    var latest = verRow({
      label: GU.latest, selected: !game.locked && !_providersOffline && !game.offline && !game.synthetic,
      disabled: _providersOffline || game.offline || game.synthetic,
      synthetic: game.synthetic,
      onClick: function () {
        call("ClearGamePin", { json: JSON.stringify({ appid: game.appid }) })
          .then(function () {
            invalidateGameUpdatesCache();
            select(latest); setLocked(false);
            if (isGameInstalled(game)) showValidatePrompt(game.appid);
          })
          .catch(function (e) { log("ClearGamePin", e); });
      },
    });
    rows.push(latest);
    vers.appendChild(latest);

    var extra = [];
    builds.forEach(function (b, idx) {
      var badges = [];
      if (b.installed) badges.push({ cls: "cur", text: GU.current });
      if (b.fromLua) badges.push({ cls: "lt", text: game.fromLuaFile ? GU.fromLuaFile : GU.fromLua });
      var isSelected = (game.locked && b.pinned) || ((_providersOffline || game.offline || game.synthetic) && !game.locked && (b.installed || (!hasInstalledBuild && b.fromLua)));
      var row = verRow({
        label: fmtDate(b.date), selected: isSelected, badges: badges,
        onClick: function () {
          var applyPin = function () {
            return call("SetGamePin", { json: JSON.stringify({ appid: game.appid, date: b.date }) })
              .then(function () { invalidateGameUpdatesCache(); select(row); setLocked(true); });
          };
          if (isGameInstalled(game)) {
            applyPinForInstalledGame(game.appid, applyPin, !b.installed);
          } else {
            showPinRestartPrompt(applyPin);
          }
        },
      });
      rows.push(row);
      if (idx >= DEFAULT_SHOWN) { row.style.display = "none"; extra.push(row); }
      vers.appendChild(row);
      // Per-build trash (hover, far right): delete this build's stored manifests
      // across every depot of that day. Hidden for installed/pinned builds and
      // the LuaTools build (those are kept / removed via the LuaTools menu).
      if (!b.installed && !b.pinned && !(b.fromLua && !game.fromLuaFile)) {
        var bdel = document.createElement("span");
        bdel.className = "lumen-del";
        bdel.textContent = "\uD83D\uDDD1";
        bdel.title = GU.delBuildTitle;
        bdel.addEventListener("click", function (e) {
          e.stopPropagation();
          call("DeleteBuild", { json: JSON.stringify({ appid: game.appid, date: b.date }) })
            .then(function () { reloadGameUpdates(vers.__bodyRef); })
            .catch(function (er) { log("DeleteBuild", er); });
        });
        row.appendChild(bdel);
      }
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

  var _gameUpdatesCache = null;
  var _gameUpdatesPending = null;
  var _gameUpdatesGeneration = 0;
  // Signature of the payload the list DOM was last built from, so a background
  // revalidation only repaints when the data really changed.
  var _gameUpdatesRendered = null;
  // Panel currently showing the game list, and its painter. Subpages (Advanced,
  // the creator, the import review) take the panel over and release it, so a
  // revalidation that lands late can tell whether repainting the list would wipe
  // out the view the user is actually looking at.
  var _guListBody = null;
  function guOwnList(body) { _guListBody = body || null; }

  function invalidateGameUpdatesCache() {
    _gameUpdatesGeneration += 1;
    _gameUpdatesCache = null;
    _gameUpdatesPending = null;
  }

  // Always asks the backend and refreshes the snapshot. Concurrent callers share
  // the in-flight request; a result whose generation was invalidated meanwhile
  // (an explicit mutation) drops itself instead of restoring stale data.
  function fetchGameUpdates() {
    if (_gameUpdatesPending) return _gameUpdatesPending;
    var generation = _gameUpdatesGeneration;
    var pending = call("GetGameUpdates", {}).then(function (res) {
      var data = JSON.parse(res);
      if (!data || !data.success) throw new Error((data && data.error) || "load failed");
      if (generation === _gameUpdatesGeneration) {
        _gameUpdatesCache = data;
        if (_gameUpdatesPending === pending) _gameUpdatesPending = null;
      }
      return data;
    }).catch(function (error) {
      if (generation === _gameUpdatesGeneration && _gameUpdatesPending === pending) {
        _gameUpdatesPending = null;
      }
      throw error;
    });
    _gameUpdatesPending = pending;
    return pending;
  }

  function preloadGameUpdates() {
    if (_gameUpdatesCache) return Promise.resolve(_gameUpdatesCache);
    return fetchGameUpdates();
  }

  // Canonicalize the backend payload before fingerprinting it. The list renderer
  // consumes fields at both game/depot/version levels (including metadata used
  // by gameBuilds), so a hand-picked signature can silently miss a visible
  // change such as fromLuaFile, installation state, or a version date. Sorting
  // object keys keeps the fingerprint stable without relying on JSON key order.
  function stableGameUpdatesValue(value) {
    if (Array.isArray(value)) return value.map(stableGameUpdatesValue);
    if (value && typeof value === "object") {
      var sorted = {};
      Object.keys(value).sort().forEach(function (key) {
        sorted[key] = stableGameUpdatesValue(value[key]);
      });
      return sorted;
    }
    return value;
  }
  function gameUpdatesSignature(data) {
    var games = data && Array.isArray(data.games) ? data.games : [];
    return JSON.stringify(stableGameUpdatesValue({
      providers_offline: !!(data && data.providers_offline),
      games: games,
    }));
  }
  // Keep cache comparison and DOM rendering on the same representation. The
  // backend's cjson output may encode an empty Lua array as {}, while the list
  // renderer treats that value as an empty array.
  function normalizeGameUpdatesData(data) {
    var arr = function (x) { return Array.isArray(x) ? x : []; };
    var games = arr(data && data.games).filter(function (g) {
      g.depots = arr(g.depots);
      g.dlc_appids = arr(g.dlc_appids);
      g.depots.forEach(function (d) { d.versions = arr(d.versions); });
      return g.depots.length > 0;
    });
    return { providers_offline: !!(data && data.providers_offline), games: games };
  }

  // Games can be added from outside this panel — the LuaTools store page, the
  // library Fixes menu, or the same script running in another Steam view, each
  // with its own snapshot. The overlay DOM is rebuilt on every open while the
  // snapshot lives as long as the injected script, so reusing it unconditionally
  // can show a library that is minutes old. Whenever the list is (re)shown it is
  // therefore painted from the snapshot for an instant view and confirmed
  // against disk right after, replacing the list only if something changed.
  function revalidateGameUpdates() {
    if (!_guListBody) return Promise.resolve();
    var generation = _gameUpdatesGeneration;
    return fetchGameUpdates().then(function (data) {
      // A mutation invalidated the snapshot while this was in flight, and has
      // already repainted with authoritative data. This answer predates it.
      if (generation !== _gameUpdatesGeneration) return;
      if (gameUpdatesSignature(normalizeGameUpdatesData(data)) === _gameUpdatesRendered) return;
      var body = _guListBody;
      if (body && typeof body.__guPaint === "function") body.__guPaint(data);
    }).catch(function (e) { log("revalidate Game Updates", e); });
  }

  // Mutations re-fetch once; ordinary tab switches reuse the preloaded result.
  function reloadGameUpdates(body) {
    invalidateGameUpdatesCache();
    renderGameUpdates(body);
  }

  // ── Source drafts + robust file import ──────────────────────────────────
  function parseRpc(raw) {
    var value = typeof raw === "string" ? JSON.parse(raw) : raw;
    if (!value || value.success === false) throw new Error((value && value.error) || "Request failed");
    return value;
  }

  function cancelGameDraft(appid, session) {
    if (!appid || !session) return Promise.resolve();
    return call("CancelGameDraft", { appid: appid, session: session }).catch(function () {});
  }

  function pollGameDraft(appid, session, onState) {
    return new Promise(function (resolve, reject) {
      var ticks = 0;
      var tick = function () {
        if (++ticks > 600) { reject(new Error(guStrings().sourceTimeout)); return; }
        call("GetGameDraftStatus", { appid: appid, session: session })
          .then(parseRpc)
          .then(function (result) {
            var state = result.state || {};
            if (onState) onState(state);
            if (state.status === "ready") { resolve(state.draft); return; }
            if (state.status === "failed" || state.status === "cancelled") {
              var sourceError = new Error(state.error || guStrings().sourceFail);
              sourceError.code = state.errorCode;
              reject(sourceError); return;
            }
            setTimeout(tick, 500);
          })
          .catch(reject);
      };
      tick();
    });
  }

  function startSourceDraft(appid, onState) {
    if (window.__lumenNoPlugin) return Promise.reject(new Error(guStrings().sourcesUnavailable));
    return call("StartGameDraft", { appid: appid })
      .then(parseRpc)
      .then(function (start) {
        return pollGameDraft(appid, start.session, onState)
          .then(function (draft) {
            return { appid: appid, session: start.session, draft: draft };
          })
          .catch(function (error) {
            return cancelGameDraft(appid, start.session).then(function () { throw error; });
          });
      });
  }

  function formatSourceBytes(value) {
    value = Math.max(0, Number(value) || 0);
    if (value < 1024) return Math.floor(value) + " B";
    if (value < 1024 * 1024) return (value / 1024).toFixed(value < 10240 ? 1 : 0) + " KB";
    return (value / (1024 * 1024)).toFixed(value < 10 * 1024 * 1024 ? 1 : 0) + " MB";
  }

  function sourceProgressMessage(state) {
    var GU = guStrings();
    if (!state || state.status !== "downloading") return GU.loadProcessing;
    var received = Number(state.bytesRead) || 0;
    var total = Number(state.totalBytes) || 0;
    if (total > 0) {
      var percent = Math.min(99, Math.floor(received * 100 / total));
      return GU.loadDownloading + " " + percent + "%  ·  "
        + formatSourceBytes(received) + " / " + formatSourceBytes(total);
    }
    if (received > 0) return GU.loadDownloading + " " + formatSourceBytes(received);
    return GU.loadDownloading;
  }

  function bytesToBase64(bytes) {
    var binary = "";
    for (var offset = 0; offset < bytes.length; offset += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(offset, offset + 0x8000));
    }
    return btoa(binary);
  }

  function uploadImportFile(session, file, fileIndex, progress) {
    var chunkSize = 192 * 1024;
    var offset = 0, chunk = 0;
    var next = function () {
      if (file.size === 0 && chunk === 0) {
        return call("UploadGameImportChunk", { json: JSON.stringify({
          session: session, file: fileIndex, chunk: 0, data: "", final: true,
        }) }).then(parseRpc);
      }
      if (offset >= file.size) return Promise.resolve();
      var end = Math.min(offset + chunkSize, file.size);
      return file.slice(offset, end).arrayBuffer().then(function (buffer) {
        return call("UploadGameImportChunk", { json: JSON.stringify({
          session: session, file: fileIndex, chunk: chunk,
          data: bytesToBase64(new Uint8Array(buffer)), final: end === file.size,
        }) });
      }).then(parseRpc).then(function () {
        offset = end; chunk += 1;
        if (progress) progress(file.name, offset, file.size);
        return next();
      });
    };
    return next();
  }

  function enrichImportApps(session, apps, status) {
    if (window.__lumenNoPlugin || !apps.length) return Promise.resolve([]);
    var warnings = [];
    return apps.reduce(function (chain, app) {
      return chain.then(function () {
        status(guStrings().sourceForApp.replace("{appid}", app.appid));
        return startSourceDraft(app.appid, function (state) {
          status(sourceProgressMessage(state));
        }).then(function (source) {
          return call("EnrichGameImportFromDraft", {
            appid: app.appid, importSession: session, draftSession: source.session,
          }).then(parseRpc).then(function () {
            return cancelGameDraft(app.appid, source.session);
          }).catch(function (error) {
            return cancelGameDraft(app.appid, source.session).then(function () { throw error; });
          });
        }).catch(function (error) {
          warnings.push(guStrings().sourceSkipped.replace("{appid}", app.appid)
            + " " + ((error && error.message) || error));
        });
      });
    }, Promise.resolve()).then(function () { return warnings; });
  }

  function importedIdentityMetadataError(appid) {
    return "identity_metadata_unavailable: " + guStrings().identityMetadataUnavailable
      .replace("{appid}", appid);
  }

  // Store metadata is the identity authority for imported apps. Do not infer a
  // missing type from the Lua shape: a DLC can otherwise be published as a
  // base game, and a self-referential fullgame field is not a usable relation.
  // Return a blocking message, or null when the identity is structurally valid.
  function validateImportedIdentityDetails(appid, details) {
    if (!details || details.metadataAvailable !== true) {
      return importedIdentityMetadataError(appid);
    }
    var rawType = typeof details.type === "string" ? details.type.trim() : "";
    var type = rawType.toLowerCase();
    if (!type) return importedIdentityMetadataError(appid);
    if (type !== "dlc") return null;

    var rawFullgame = details.fullgameAppid == null
      ? "" : String(details.fullgameAppid).trim();
    var fullgame = Number(rawFullgame);
    if (!/^\d+$/.test(rawFullgame) || !isFinite(fullgame) || fullgame <= 0
        || fullgame === Number(appid)) {
      return "identity_dlc_metadata: " + guStrings().identityDlcMetadata
        .replace("{appid}", appid);
    }
    return "identity_dlc: " + guStrings().identityDlc
      .replace("{appid}", appid)
      .replace("{fullgame}", fullgame);
  }

  function validateImportedIdentities(prepared) {
    prepared = prepared || {};
    var errors = Array.isArray(prepared.importErrors) ? prepared.importErrors.slice() : [];
    var seen = {};
    errors.forEach(function (message) { seen[message] = true; });
    var apps = Array.isArray(prepared.apps) ? prepared.apps : [];
    return Promise.all(apps.map(function (app) {
      return fetchAppDetails(app.appid).then(function (details) {
        var identityError = validateImportedIdentityDetails(app.appid, details);
        if (!identityError || seen[identityError]) return;
        seen[identityError] = true;
        errors.push(identityError);
      }).catch(function (error) {
        log("validate imported identity", error);
        var unavailable = importedIdentityMetadataError(app.appid);
        if (!seen[unavailable]) { seen[unavailable] = true; errors.push(unavailable); }
      });
    })).then(function () {
      prepared.importErrors = errors;
      return prepared;
    });
  }

  function renderImportSummary(body, session, prepared, extraWarnings) {
    var GU = guStrings();
    body.textContent = "";
    guShowClearBtn(false);
    guOwnList(null);
    var back = document.createElement("div");
    back.className = "lumen-back";
    back.textContent = "\u2190 " + GU.back;
    back.addEventListener("click", function () {
      call("CancelGameImport", { json: JSON.stringify({ session: session }) }).catch(function () {});
      renderGameUpdates(body);
    });
    body.appendChild(back);

    var title = document.createElement("div");
    title.className = "lumen-sub-title";
    title.textContent = GU.importReview;
    body.appendChild(title);
    var intro = document.createElement("div");
    intro.className = "lumen-note";
    intro.textContent = GU.importReviewDesc;
    body.appendChild(intro);

    var summary = document.createElement("div");
    summary.className = "lumen-import-summary";
    var apps = Array.isArray(prepared.apps) ? prepared.apps : [];
    var manifests = Array.isArray(prepared.manifests) ? prepared.manifests : [];
    [
      [GU.importGames, String(apps.length)],
      [GU.importManifests, String(manifests.length)],
      [GU.importKeys, String(apps.reduce(function (n, app) { return n + (app.keys || 0); }, 0))],
    ].forEach(function (item) {
      var stat = document.createElement("div");
      stat.className = "lumen-import-stat";
      stat.innerHTML = "<span></span><strong></strong>";
      stat.firstChild.textContent = item[0];
      stat.lastChild.textContent = item[1];
      summary.appendChild(stat);
    });
    body.appendChild(summary);

    if (apps.length) {
      var appList = document.createElement("div");
      appList.className = "lumen-import-list";
      apps.forEach(function (app) {
        var row = document.createElement("div");
        row.className = "lumen-import-item";
        var label = document.createElement("span");
        label.textContent = "App " + app.appid;
        fetchAppName(app.appid).then(function (name) { if (name) label.textContent = name + "  ·  " + app.appid; });
        var detail = document.createElement("small");
        var identity = app.identity || {};
        var identitySource = app.identitySource || identity.source || "";
        var identityConfidence = app.identityConfidence || identity.confidence || "";
        detail.textContent = (app.keys || 0) + " " + GU.keysLabel + "  ·  "
          + (app.pins || 0) + " " + GU.manifestsLabel
          + (identitySource ? "  ·  " + GU.identitySource + ": " + identitySource
            + (identityConfidence ? " (" + identityConfidence + ")" : "") : "")
          + (app.installed ? "  ·  " + GU.current : "");
        row.appendChild(label); row.appendChild(detail); appList.appendChild(row);
      });
      body.appendChild(appList);
    }

    var warnings = (Array.isArray(prepared.warnings) ? prepared.warnings : []).concat(extraWarnings || []);
    warnings.forEach(function (warning) { addLine(body, warning, "advanced", "!"); });
    var importErrors = Array.isArray(prepared.importErrors) ? prepared.importErrors : [];
    importErrors.forEach(function (message) { addLine(body, message, "danger", "!"); });
    if (!apps.length && manifests.length) addLine(body, GU.manifestOnlyNote, "info", "i");

    var error = document.createElement("div");
    error.className = "lumen-err";
    body.appendChild(error);
    var actions = document.createElement("div");
    actions.className = "lumen-builder-actions";
    var cancel = document.createElement("button");
    cancel.className = "lumen-mbtn";
    cancel.textContent = GU.cancel;
    cancel.addEventListener("click", function () { back.click(); });
    var commit = document.createElement("button");
    commit.className = "lumen-mbtn primary";
    commit.textContent = GU.importConfirm;
    if (importErrors.length) {
      commit.disabled = true; // importErrors block publication until resolved.
      error.textContent = importErrors.join(" ");
    }
    commit.addEventListener("click", function () {
      if (importErrors.length) return;
      commit.disabled = true; error.textContent = ""; commit.textContent = GU.importing;
      call("CommitGameImport", { json: JSON.stringify({ session: session }) })
        .then(parseRpc)
        .then(function () {
          showConfirm({
            title: GU.restartTitle, body: GU.importDone,
            declineText: GU.restartLater, confirmText: GU.restartNow,
            onConfirm: function () { call("RestartSteam", {}).catch(function (e) { log("RestartSteam", e); }); },
          });
          reloadGameUpdates(body);
        })
        .catch(function (e) {
          commit.disabled = false; commit.textContent = GU.importConfirm;
          error.textContent = GU.importFail + ((e && e.message) || e);
        });
    });
    actions.appendChild(cancel); actions.appendChild(commit); body.appendChild(actions);
  }

  function importSelectedFiles(files, body) {
    var GU = guStrings();
    files = Array.prototype.slice.call(files || []);
    if (!files.length) return;
    var prog = showProgress(GU.importFiles);
    prog.update(GU.importPreparing);
    var session;
    call("BeginGameImport", { json: JSON.stringify({ files: files.map(function (file) {
      return { name: file.name, size: file.size };
    }) }) }).then(parseRpc).then(function (start) {
      session = start.session;
      return files.reduce(function (chain, file, index) {
        return chain.then(function () {
          return uploadImportFile(session, file, index + 1, function (name, received, total) {
            var pct = total ? Math.floor(received * 100 / total) : 100;
            prog.update(GU.importUploading.replace("{file}", name).replace("{percent}", pct));
          });
        });
      }, Promise.resolve());
    }).then(function () {
      prog.update(GU.importInspecting);
      return call("PrepareGameImport", { json: JSON.stringify({ session: session }) }).then(parseRpc);
    }).then(function (first) {
      return enrichImportApps(session, Array.isArray(first.apps) ? first.apps : [], function (message) {
        prog.update(message);
      }).then(function (warnings) {
        return call("PrepareGameImport", { json: JSON.stringify({ session: session }) })
          .then(parseRpc).then(function (finalPrep) { return { prepared: finalPrep, warnings: warnings }; });
      });
    }).then(function (result) {
      return validateImportedIdentities(result.prepared).then(function (prepared) {
        prog.close();
        renderImportSummary(body, session, prepared, result.warnings);
      });
    }).catch(function (e) {
      prog.close();
      if (session) call("CancelGameImport", { json: JSON.stringify({ session: session }) }).catch(function () {});
      alert(GU.importFail + ((e && e.message) || e));
    });
  }

  function gameUpdateActions(body) {
    var GU = guStrings();
    var wrap = document.createElement("div");
    wrap.className = "lumen-gu-actions";
    var add = document.createElement("button");
    add.className = "lumen-mbtn primary";
    add.textContent = "+ " + GU.addGame;
    add.addEventListener("click", function () { renderGameCreator(body); });
    var btn = document.createElement("button");
    btn.className = "lumen-mbtn primary lumen-load-lua";
    btn.textContent = "\u2191 " + GU.importFiles;
    btn.title = GU.importFilesHint;
    var fileIn = document.createElement("input");
    fileIn.type = "file";
    fileIn.multiple = true;
    fileIn.accept = ".lua,.manifest,.zip";
    fileIn.style.display = "none";
    btn.addEventListener("click", function () { fileIn.value = ""; fileIn.click(); });
    fileIn.addEventListener("change", function () { importSelectedFiles(fileIn.files, body); });
    wrap.appendChild(add); wrap.appendChild(btn); wrap.appendChild(fileIn);
    return wrap;
  }

  var APP_DETAILS_TTL = 7 * 24 * 60 * 60 * 1000;
  function fetchAppDetails(appid) {
    var key = "lumen-game-details-v1:" + appid;
    try {
      var cached = JSON.parse(localStorage.getItem(key) || "null");
      if (cached && cached.savedAt && Date.now() - cached.savedAt < APP_DETAILS_TTL) {
        return Promise.resolve(cached.value);
      }
    } catch (e) {}
    var fallback = {
      name: "App " + appid, image: capsuleUrl(appid), dlc: [],
      type: null, fullgameAppid: null, metadataAvailable: false,
    };
    var request;
    try {
      request = fetch("https://store.steampowered.com/api/appdetails?appids=" + appid)
        .then(function (response) { return response.json(); })
        .then(function (json) {
          var data = json && json[appid] && json[appid].success && json[appid].data;
          if (!data) return fallback;
          var fullgame = data.fullgame && data.fullgame.appid;
          var fullgameAppid = /^\d+$/.test(String(fullgame || "")) ? Number(fullgame) : null;
          var value = {
            name: data.name || fallback.name,
            image: data.header_image || data.capsule_image || fallback.image,
            type: typeof data.type === "string" ? data.type : null,
            fullgameAppid: fullgameAppid,
            metadataAvailable: true,
            dlc: Array.isArray(data.dlc) ? data.dlc.filter(function (id) { return /^\d+$/.test(String(id)); }) : [],
          };
          try { localStorage.setItem(key, JSON.stringify({ savedAt: Date.now(), value: value })); } catch (e) {}
          return value;
        })
        .catch(function () { return fallback; });
    } catch (e) { request = Promise.resolve(fallback); }
    return request;
  }

  function searchStoreGames(query) {
    var language = "english";
    try { language = pickLang() === "pt-BR" ? "brazilian" : "english"; } catch (e) {}
    return call("SearchSteamGames", { query: query, language: language })
      .then(parseRpc)
      .then(function (data) {
        return (Array.isArray(data && data.items) ? data.items : []).filter(function (item) {
          return item && item.type === "app" && /^\d+$/.test(String(item.id));
        }).slice(0, 8);
      });
  }

  function renderStoreResults(container, items, onSelect, activeIndex) {
    var GU = guStrings();
    container.textContent = "";
    container.className = "lumen-builder-results open";
    if (!items.length) {
      var empty = document.createElement("div");
      empty.className = "lumen-builder-results-empty";
      empty.textContent = GU.noGameResults;
      container.appendChild(empty);
      return;
    }
    items.forEach(function (item, index) {
      var row = document.createElement("button");
      row.type = "button"; row.className = "lumen-builder-result";
      if (index === activeIndex) row.className += " selected";
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", index === activeIndex ? "true" : "false");
      row.id = container.id + "-option-" + index;
      row.title = GU.selectGame + ": " + item.name;
      var image = document.createElement("img");
      image.src = item.tiny_image || capsuleUrl(item.id); image.alt = "";
      image.addEventListener("error", function () { image.style.visibility = "hidden"; });
      var text = document.createElement("span");
      var meta = document.createElement("strong"); meta.textContent = "AppID " + item.id;
      var name = document.createElement("small"); name.textContent = item.name || ("App " + item.id);
      text.appendChild(meta); text.appendChild(name);
      row.appendChild(image); row.appendChild(text);
      row.addEventListener("mousedown", function (event) { event.preventDefault(); });
      row.addEventListener("click", function () { onSelect(Number(item.id)); });
      container.appendChild(row);
    });
  }

  function builderField(labelText, input) {
    var field = document.createElement("label");
    field.className = "lumen-builder-field";
    var label = document.createElement("span");
    label.textContent = labelText;
    field.appendChild(label); field.appendChild(input);
    return field;
  }

  function buildDraftLuaRequest(appid, dlcList, depotList) {
    return {
      appid: appid,
      dlc_appids: dlcList.map(function (input) { return input.value.trim(); }).filter(Boolean),
      depots: depotList.map(function (row) {
        return { depot: row.depot.value.trim(), key: row.key.value.trim(), gid: row.gid.value.trim() };
      }),
    };
  }

  function renderGameCreatorEditor(body, source, details) {
    var GU = guStrings();
    var draft = source.draft || {};
    details = details || {};
    var importErrors = [];
    var identityError = validateImportedIdentityDetails(source.appid, details);
    if (identityError) importErrors.push(identityError);
    var dlcInputs = [], depotRows = [];
    var baseDepots = {};
    (Array.isArray(draft.baseDepots) ? draft.baseDepots : []).forEach(function (id) {
      baseDepots[String(id)] = true;
    });
    body.textContent = "";
    guShowClearBtn(false);
    guOwnList(null);

    var back = document.createElement("div");
    back.className = "lumen-back";
    back.textContent = "\u2190 " + GU.back;
    back.addEventListener("click", function () {
      call("CancelGameDraft", { appid: source.appid, session: source.session }).catch(function () {});
      renderGameUpdates(body);
    });
    body.appendChild(back);

    var builder = document.createElement("div");
    builder.className = "lumen-game-builder";
    var identity = document.createElement("div");
    identity.className = "lumen-builder-identity";
    var image = document.createElement("img");
    image.src = details.image || capsuleUrl(source.appid);
    image.alt = "";
    image.addEventListener("error", function () { image.style.visibility = "hidden"; });
    var identityText = document.createElement("div");
    var gameName = document.createElement("div");
    gameName.className = "lumen-builder-game-name";
    gameName.textContent = details.name || ("App " + source.appid);
    var gameMeta = document.createElement("div");
    gameMeta.className = "lumen-builder-game-meta";
    var contributors = Array.isArray(draft.contributors) ? draft.contributors : [];
    gameMeta.textContent = "AppID " + source.appid
      + (contributors.length ? "  ·  " + GU.sourcesLabel + ": " + contributors.join(", ") : "");
    identityText.appendChild(gameName); identityText.appendChild(gameMeta);
    identity.appendChild(image); identity.appendChild(identityText); builder.appendChild(identity);

    var sectionTitle = function (text, description) {
      var wrap = document.createElement("div");
      wrap.className = "lumen-builder-section-head";
      var title = document.createElement("div");
      title.textContent = text;
      var desc = document.createElement("small");
      desc.textContent = description;
      wrap.appendChild(title); wrap.appendChild(desc); builder.appendChild(wrap);
    };

    sectionTitle(GU.dlcApps, GU.dlcAppsDesc);
    var dlcList = document.createElement("div");
    dlcList.className = "lumen-builder-dlcs";
    builder.appendChild(dlcList);
    var addDlcRow = function (value, suggested) {
      var row = document.createElement("div");
      row.className = "lumen-builder-dlc";
      var input = document.createElement("input");
      input.type = "text"; input.inputMode = "numeric"; input.value = value || "";
      input.placeholder = GU.dlcAppid;
      var origin = document.createElement("small");
      origin.textContent = suggested ? GU.storeSuggestion : GU.sourceValue;
      var remove = document.createElement("button");
      remove.type = "button"; remove.className = "lumen-icon-btn"; remove.textContent = "\u00d7";
      remove.title = GU.remove;
      remove.addEventListener("click", function () {
        var index = dlcInputs.indexOf(input);
        if (index !== -1) dlcInputs.splice(index, 1);
        row.remove();
      });
      dlcInputs.push(input);
      row.appendChild(input); row.appendChild(origin); row.appendChild(remove); dlcList.appendChild(row);
    };
    var sourceDlcs = Array.isArray(draft.dlc_appids) ? draft.dlc_appids.map(String) : [];
    sourceDlcs.forEach(function (id) { addDlcRow(id, false); });
    (details.dlc || []).map(String).filter(function (id) { return sourceDlcs.indexOf(id) === -1; })
      .forEach(function (id) { addDlcRow(id, true); });
    if (!dlcInputs.length) addDlcRow("", false);
    var addDlc = document.createElement("button");
    addDlc.type = "button"; addDlc.className = "lumen-builder-add";
    addDlc.textContent = "+ " + GU.addDlc;
    addDlc.addEventListener("click", function () { addDlcRow("", false); });
    builder.appendChild(addDlc);

    sectionTitle(GU.depotsAndVersions, GU.depotsAndVersionsDesc);
    var depotList = document.createElement("div");
    depotList.className = "lumen-builder-depots";
    builder.appendChild(depotList);
    var addDepotRow = function (data) {
      data = data || {};
      var isVirtual = data.virtualDepot === true;
      var row = document.createElement("div");
      row.className = "lumen-builder-depot" + (isVirtual ? " virtual" : "");
      var top = document.createElement("div");
      top.className = "lumen-builder-depot-top";
      var depot = document.createElement("input");
      depot.type = "text"; depot.inputMode = "numeric"; depot.value = data.depot || "";
      depot.placeholder = GU.depotId;
      var steamdb = document.createElement("a");
      steamdb.target = "_blank"; steamdb.rel = "noopener noreferrer";
      steamdb.textContent = GU.chooseVersion;
      steamdb.addEventListener("click", function (event) {
        var id = depot.value.trim();
        if (!/^\d+$/.test(id)) { event.preventDefault(); return; }
        event.preventDefault();
        call("OpenExternalUrl", {
          contentScriptQuery: "", url: "https://steamdb.info/depot/" + id + "/manifests/",
        }).catch(function (e) { log("OpenExternalUrl", e); });
      });
      var syncLink = function () {
        var id = depot.value.trim();
        steamdb.href = /^\d+$/.test(id) ? "https://steamdb.info/depot/" + id + "/manifests/" : "#";
        steamdb.classList.toggle("disabled", !/^\d+$/.test(id));
      };
      depot.addEventListener("input", syncLink); syncLink();
      var packageBadge = document.createElement("span");
      packageBadge.className = "lumen-builder-package";
      packageBadge.textContent = isVirtual ? GU.virtualDlc
        : (data.hasManifest ? GU.inPackage : GU.serverVersion);
      var remove = document.createElement("button");
      remove.type = "button"; remove.className = "lumen-icon-btn"; remove.textContent = "\u00d7";
      remove.title = GU.remove;
      top.appendChild(builderField(GU.depot, depot)); top.appendChild(packageBadge);
      if (!isVirtual) top.appendChild(steamdb);
      top.appendChild(remove);

      var key = document.createElement("input");
      key.type = "password"; key.value = data.key || ""; key.autocomplete = "off";
      key.spellcheck = false; key.placeholder = GU.keyPlaceholder;
      var keyWrap = document.createElement("div");
      keyWrap.className = "lumen-builder-secret";
      keyWrap.appendChild(key);
      var reveal = document.createElement("button");
      reveal.type = "button"; reveal.className = "lumen-secret-toggle"; reveal.textContent = GU.show;
      reveal.addEventListener("click", function () {
        var hidden = key.type === "password";
        key.type = hidden ? "text" : "password";
        reveal.textContent = hidden ? GU.hide : GU.show;
      });
      keyWrap.appendChild(reveal);
      var gid = document.createElement("input");
      gid.type = "text"; gid.inputMode = "numeric"; gid.value = data.gid || "";
      gid.placeholder = GU.latestShort;
      var fields = document.createElement("div");
      fields.className = "lumen-builder-depot-fields";
      if (isVirtual) {
        key.type = "hidden"; gid.type = "hidden";
        var virtualKey = document.createElement("div");
        virtualKey.className = "lumen-virtual-key";
        virtualKey.textContent = GU.virtualDlcNoKey;
        fields.appendChild(virtualKey);
      } else {
        fields.appendChild(builderField(GU.depotKey, keyWrap));
        fields.appendChild(builderField(GU.manifestGid, gid));
        var initialGid = String(data.gid || "");
        var syncManifestHint = function () {
          var value = gid.value.trim();
          var hint = !value ? GU.manifestLatestHint
            : (data.manifestSource && value === initialGid
              ? GU.manifestSourceHint.replace("{source}", data.manifestSource)
              : GU.manifestManualHint);
          steamdb.title = hint;
          steamdb.setAttribute("aria-label", GU.chooseVersion + ". " + hint);
        };
        gid.addEventListener("input", syncManifestHint); syncManifestHint();
      }
      row.appendChild(top); row.appendChild(fields); depotList.appendChild(row);
      var model = { root: row, depot: depot, key: key, gid: gid };
      depotRows.push(model);
      remove.addEventListener("click", function () {
        var index = depotRows.indexOf(model);
        if (index !== -1) depotRows.splice(index, 1);
        row.remove();
      });
    };
    (Array.isArray(draft.depots) ? draft.depots : []).forEach(addDepotRow);
    if (!depotRows.length) addDepotRow({});
    var addDepot = document.createElement("button");
    addDepot.type = "button"; addDepot.className = "lumen-builder-add";
    addDepot.textContent = "+ " + GU.addDepot;
    addDepot.addEventListener("click", function () { addDepotRow({}); });
    builder.appendChild(addDepot);

    var latestNote = document.createElement("div");
    latestNote.className = "lumen-builder-latest-note";
    latestNote.textContent = GU.latestExplainer;
    builder.appendChild(latestNote);
    var error = document.createElement("div");
    error.className = "lumen-err";
    if (importErrors.length) error.textContent = importErrors.join(" ");
    builder.appendChild(error);
    var actions = document.createElement("div");
    actions.className = "lumen-builder-actions";
    var cancel = document.createElement("button");
    cancel.className = "lumen-mbtn"; cancel.textContent = GU.cancel;
    cancel.addEventListener("click", function () { back.click(); });
    var committedResult = null;
    var commit = document.createElement("button");
    commit.className = "lumen-mbtn primary"; commit.textContent = GU.addGame;
    if (importErrors.length) commit.disabled = true; // importErrors block this identity.
    commit.addEventListener("click", function () {
      if (importErrors.length) return;
      error.textContent = "";
      var request = buildDraftLuaRequest(source.appid, dlcInputs, depotRows);
      var invalidDlc = request.dlc_appids.some(function (id) { return !/^\d+$/.test(id); });
      var invalidDepot = request.depots.some(function (row) {
        return !/^\d+$/.test(row.depot) || (row.key && !/^[0-9a-fA-F]{64}$/.test(row.key))
          || (row.gid && !/^\d+$/.test(row.gid));
      });
      var hasUsableBaseKey = request.depots.some(function (row) {
        var validKey = /^[0-9a-fA-F]{64}$/.test(row.key);
        return validKey && (!Object.keys(baseDepots).length || baseDepots[row.depot]);
      });
      if (invalidDlc || invalidDepot || !request.depots.length || !hasUsableBaseKey) {
        error.textContent = GU.invalidDraft; return;
      }
      commit.disabled = true; commit.textContent = GU.addingGame;
      var publish = committedResult ? Promise.resolve(committedResult) : call("CommitGameDraft", {
        appid: source.appid, session: source.session,
        editsJson: JSON.stringify({ dlc_appids: request.dlc_appids, depots: request.depots }),
      }).then(parseRpc).then(function (result) { committedResult = result; return result; });
      publish.then(function (result) {
        if (result.pinsSynced) return result;
        return call("SyncGamePins", { json: JSON.stringify({ appid: source.appid, lua: result.lua }) })
          .then(parseRpc)
          .then(function () {
            return call("MarkLuaImport", { json: JSON.stringify({ appid: source.appid }) })
              .then(parseRpc).then(function () { return result; });
          });
      }).then(function () {
        cancelGameDraft(source.appid, source.session);
        showConfirm({
          title: GU.restartTitle, body: GU.addGameDone,
          declineText: GU.restartLater, confirmText: GU.restartNow,
          onConfirm: function () { call("RestartSteam", {}).catch(function (e) { log("RestartSteam", e); }); },
        });
        reloadGameUpdates(body);
      }).catch(function (e) {
        commit.disabled = false; commit.textContent = GU.addGame;
        error.textContent = GU.addGameFail + ((e && e.message) || e);
      });
    });
    actions.appendChild(cancel); actions.appendChild(commit); builder.appendChild(actions);
    body.appendChild(builder);
  }

  function renderGameCreator(body) {
    var GU = guStrings();
    body.textContent = "";
    guShowClearBtn(false);
    guOwnList(null);
    var cancelled = false, active = null;
    var back = document.createElement("div");
    back.className = "lumen-back"; back.textContent = "\u2190 " + GU.back;
    back.addEventListener("click", function () {
      cancelled = true;
      if (active) cancelGameDraft(active.appid, active.session);
      renderGameUpdates(body);
    });
    body.appendChild(back);
    var title = document.createElement("div");
    title.className = "lumen-sub-title"; title.textContent = GU.addGame;
    body.appendChild(title);
    var intro = document.createElement("div");
    intro.className = "lumen-note"; intro.textContent = GU.addGameIntro;
    body.appendChild(intro);
    var lookup = document.createElement("div");
    lookup.className = "lumen-builder-lookup";
    var searchbox = document.createElement("div");
    searchbox.className = "lumen-builder-searchbox";
    var appid = document.createElement("input");
    appid.type = "search"; appid.inputMode = "search"; appid.placeholder = GU.appidPlaceholder;
    appid.setAttribute("role", "combobox");
    appid.setAttribute("aria-autocomplete", "list");
    appid.setAttribute("aria-expanded", "false");
    appid.setAttribute("aria-controls", "lumen-game-suggestions");
    var search = document.createElement("button");
    search.className = "lumen-mbtn primary"; search.textContent = GU.searchSources;
    var status = document.createElement("div");
    status.className = "lumen-builder-status";
    var error = document.createElement("div");
    error.className = "lumen-err";
    var results = document.createElement("div");
    results.className = "lumen-builder-results";
    results.id = "lumen-game-suggestions";
    results.setAttribute("role", "listbox");
    searchbox.appendChild(appid); searchbox.appendChild(results);
    lookup.appendChild(searchbox); lookup.appendChild(search); body.appendChild(lookup);
    body.appendChild(status); body.appendChild(error);
    appid.focus();
    var searchTimer = null, searchGeneration = 0, suggestions = [], activeIndex = -1;
    var closeStoreResults = function () {
      results.className = "lumen-builder-results";
      results.textContent = "";
      suggestions = []; activeIndex = -1;
      appid.setAttribute("aria-expanded", "false");
      appid.removeAttribute("aria-activedescendant");
    };
    var selectSuggestion = function (id) {
      closeStoreResults(); appid.value = String(id); openApp(id);
    };
    var showStoreMessage = function (message, className) {
      results.textContent = "";
      results.className = "lumen-builder-results open";
      var row = document.createElement("div");
      row.className = className || "lumen-builder-results-empty";
      row.textContent = message; results.appendChild(row);
      appid.setAttribute("aria-expanded", "true");
    };
    var paintSuggestions = function () {
      renderStoreResults(results, suggestions, selectSuggestion, activeIndex);
      appid.setAttribute("aria-expanded", "true");
      if (activeIndex >= 0) {
        appid.setAttribute("aria-activedescendant", results.id + "-option-" + activeIndex);
      } else appid.removeAttribute("aria-activedescendant");
    };
    var requestGameSearch = function (query) {
      var generation = ++searchGeneration;
      showStoreMessage(GU.searchingGames, "lumen-builder-results-empty loading");
      return searchStoreGames(query).then(function (items) {
        if (generation !== searchGeneration || appid.value.trim() !== query) return;
        suggestions = items; activeIndex = -1; paintSuggestions();
      }).catch(function () {
        if (generation !== searchGeneration) return;
        suggestions = []; activeIndex = -1;
        showStoreMessage(GU.gameSearchFail, "lumen-builder-results-empty error");
      });
    };
    var runScheduledGameSearch = function () {
      searchTimer = null;
      var query = appid.value.trim();
      if (query.length >= 2 && !/^\d+$/.test(query)) requestGameSearch(query);
    };
    var scheduleGameSearch = function () {
      if (searchTimer) clearTimeout(searchTimer);
      searchGeneration += 1;
      var query = appid.value.trim();
      if (query.length < 2 || /^\d+$/.test(query)) { closeStoreResults(); return; }
      searchTimer = setTimeout(runScheduledGameSearch, 280);
    };
    var openApp = function (id) {
      if (searchTimer) clearTimeout(searchTimer);
      closeStoreResults(); error.textContent = "";
      search.disabled = true; appid.disabled = true;
      status.className = "lumen-builder-status loading";
      status.innerHTML = '<span class="lumen-spin"></span><span></span>';
      status.lastChild.textContent = GU.loadChecking;
      call("StartGameDraft", { appid: id }).then(parseRpc).then(function (start) {
        active = { appid: id, session: start.session };
        if (cancelled) {
          call("CancelGameDraft", { appid: id, session: start.session }).catch(function () {});
          return Promise.reject(new Error("cancelled"));
        }
        return pollGameDraft(id, start.session, function (state) {
          if (!status.lastChild) return;
          status.lastChild.textContent = sourceProgressMessage(state);
        }).then(function (draft) { return { draft: draft, session: start.session }; });
      }).then(function (source) {
        if (cancelled) return;
        active = { appid: id, session: source.session, draft: source.draft };
        status.lastChild.textContent = GU.loadingDetails;
        return fetchAppDetails(id).then(function (details) {
          if (!cancelled) renderGameCreatorEditor(body, active, details);
        });
      }).catch(function (e) {
        if (cancelled) return;
        if (active) cancelGameDraft(active.appid, active.session);
        search.disabled = false; appid.disabled = false;
        status.textContent = ""; status.className = "lumen-builder-status";
        error.textContent = e && e.code === "not_found"
          ? GU.sourceNotFound : GU.sourceFail + " " + ((e && e.message) || e);
      });
    };
    var run = function () {
      var query = appid.value.trim();
      if (!query) { error.textContent = GU.invalidAppid; return; }
      if (/^\d+$/.test(query) && query !== "0") { openApp(Number(query)); return; }
      error.textContent = "";
      if (searchTimer) clearTimeout(searchTimer);
      requestGameSearch(query);
    };
    search.addEventListener("click", run);
    appid.addEventListener("input", scheduleGameSearch);
    appid.addEventListener("blur", function () { setTimeout(closeStoreResults, 120); });
    appid.addEventListener("keydown", function (event) {
      if ((event.key === "ArrowDown" || event.key === "ArrowUp") && suggestions.length) {
        event.preventDefault();
        activeIndex += event.key === "ArrowDown" ? 1 : -1;
        if (activeIndex < 0) activeIndex = suggestions.length - 1;
        if (activeIndex >= suggestions.length) activeIndex = 0;
        paintSuggestions(); return;
      }
      if (event.key === "Escape") { closeStoreResults(); return; }
      if (event.key === "Enter") {
        event.preventDefault();
        if (activeIndex >= 0 && suggestions[activeIndex]) {
          selectSuggestion(Number(suggestions[activeIndex].id));
        } else run();
      }
    });
  }

  function renderGameUpdates(body) {
    var GU = guStrings();
    // Returning to the list (or first render): the global clear button applies.
    guShowClearBtn(true);
    guOwnList(body);
    body.textContent = "";
    var note = document.createElement("div");
    note.className = "lumen-note";
    note.textContent = GU.note;
    body.appendChild(note);

    body.appendChild(gameUpdateActions(body));

    var search = document.createElement("input");
    search.type = "text";
    search.className = "lumen-gu-search";
    search.placeholder = GU.search;
    body.appendChild(search);

    var listWrap = document.createElement("div");
    body.appendChild(listWrap);

    // The chrome above (note, actions, search box) survives a repaint, so the
    // query the user typed keeps applying to whatever the list holds.
    var cards = [];
    var applyFilter = function () {
      var q = search.value.trim().toLowerCase();
      cards.forEach(function (c) {
        var nameEl = c.__nameEl;
        var hay = (String(c.__appid) + " " + (nameEl ? nameEl.textContent : "")).toLowerCase();
        c.style.display = (q === "" || hay.indexOf(q) !== -1) ? "" : "none";
      });
    };
    search.addEventListener("input", applyFilter);

    var paint = function (data) {
      var normalized = normalizeGameUpdatesData(data);
      _providersOffline = normalized.providers_offline;
      // Fingerprint the same normalized data that the renderer consumes. This
      // prevents cjson's empty-table representation ({}) from looking different
      // from the normalized empty array ([]) on the next revalidation.
      _gameUpdatesRendered = gameUpdatesSignature(normalized);
      var games = normalized.games;
      listWrap.textContent = "";
      cards = [];
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
      cards = games.map(function (g) {
        var card = gameCard(g);
        card.__versRef.__bodyRef = body;
        card.__appid = g.appid;
        card.__nameEl = card.querySelector(".lumen-game-name");
        frag.appendChild(card);
        return card;
      });
      listWrap.appendChild(frag);
      applyFilter();
    };
    // Reachable from revalidateGameUpdates once this panel owns the list.
    body.__guPaint = paint;

    if (_gameUpdatesCache) {
      // Instant on re-entry, then confirmed against disk in the background so a
      // game added elsewhere shows up without a manual reload.
      paint(_gameUpdatesCache);
      revalidateGameUpdates();
      return Promise.resolve(_gameUpdatesCache);
    }

    var renderGeneration = _gameUpdatesGeneration;
    listWrap.textContent = "Loading\u2026";
    return preloadGameUpdates()
      .then(function (data) {
        if (renderGeneration !== _gameUpdatesGeneration) return;
        paint(data);
      })
      .catch(function (e) {
        if (renderGeneration !== _gameUpdatesGeneration) return;
        listWrap.textContent = "";
        var err = document.createElement("div");
        err.className = "lumen-err";
        err.textContent = GU.loadFail + (e && e.message ? e.message : e);
        listWrap.appendChild(err);
      });
  }
