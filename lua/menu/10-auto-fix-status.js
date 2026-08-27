// LM-FRAGMENT automatic-fix menubar pill + launch-wait progress dialog
// LM-FRAGMENT source fragment of lumen_menu, assembled into the shared IIFE.

  var AUTO_FIX_OVERLAY_ID = "lumen-auto-fix-overlay";
  var _autoFixJobs = {};
  var _autoFixPillJob = null;
  var _autoFixModal = null;
  var _autoFixFocusTrap = null;
  var _moonPillMessage = null;
  var _moonPillMessageTimer = null;
  var _moonPillCopyTimer = null;
  var _moonPillBootStarted = false;
  var MOON_PILL_MESSAGE_MS = 5000;
  var MOON_PILL_COLLAPSE_MS = 280;

  function autoFixCopy() {
    if (typeof autoFixStrings === "function") return autoFixStrings();
    return {
      applying: "Applying fix",
      settings: "Lumen settings",
      updatesAvailable: "Updates available",
      title: "Recommended fix",
      body: "Lumen is applying the recommended LuaTools fix before this game opens.",
      launchQueued: "The game will open automatically when it is safe.",
      preparing: "Preparing the recommended fix",
      needsLogin: "Waiting for lua.tools login",
      downloading: "Downloading fix files",
      extracting: "Extracting to a private staging folder",
      applyingFiles: "Applying files to the game",
      finalizing: "Finishing launch settings",
      keepWaiting: "Keep waiting",
      close: "Close",
      cancelLaunch: "Cancel launch",
      launchWithoutFix: "Open without fix",
      skipFailed: "The automatic fix could not be skipped safely.",
      timeoutTitle: "Launch cancelled",
      timeoutBody: "The fix is taking longer than expected, so this launch attempt was cancelled.",
      failed: "The recommended fix could not be applied",
      failedTitle: "Fix failed",
      failedBody: "The game was not opened automatically. You can open it without the fix or try again later.",
    };
  }

  function autoFixProgress(value) {
    var number = Number(value);
    if (!isFinite(number)) return 0;
    return Math.max(0, Math.min(99, Math.floor(number)));
  }

  function autoFixStage(job, S) {
    var stage = job && job.stage;
    if (stage === "needs_login") return S.needsLogin;
    if (stage === "downloading") return S.downloading;
    if (stage === "extracting") return S.extracting;
    if (stage === "applying") return S.applyingFiles;
    if (stage === "finalizing") return S.finalizing;
    if (stage === "failed") {
      return (job && typeof job.error === "string" && job.error) || S.failed;
    }
    return S.preparing;
  }

  function pickAutoFixPillJob(jobs) {
    var keys = Object.keys(jobs || {}).sort(function (a, b) {
      return Number(a) - Number(b);
    });
    for (var i = 0; i < keys.length; i++) {
      var job = jobs[keys[i]];
      if (job && (job.phase === "applying" || job.phase === "finalizing")) return job;
    }
    return null;
  }

  function moonPillMotionMs() {
    try {
      if (window.matchMedia
          && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return 0;
    } catch (_) {}
    return MOON_PILL_COLLAPSE_MS;
  }

  function collapseMoonPill(button, copy) {
    button.classList.remove("lumen-auto-fix-active");
    if (_moonPillCopyTimer) clearTimeout(_moonPillCopyTimer);
    _moonPillCopyTimer = setTimeout(function () {
      _moonPillCopyTimer = null;
      if (!button.classList.contains("lumen-auto-fix-active")) copy.textContent = "";
    }, moonPillMotionMs());
  }

  function expandMoonPill(button, copy, label, title) {
    if (_moonPillCopyTimer) {
      clearTimeout(_moonPillCopyTimer);
      _moonPillCopyTimer = null;
    }
    copy.textContent = label;
    button.classList.add("lumen-auto-fix-active");
    button.title = title || label;
    button.setAttribute("aria-label", label);
  }

  function showMoonPillMessage(kind, label) {
    if (_moonPillMessage && _moonPillMessage.kind === "updates" && kind !== "updates") return;
    _moonPillMessage = { kind: kind, label: label };
    if (_moonPillMessageTimer) clearTimeout(_moonPillMessageTimer);
    renderAutoFixPill();
    var current = _moonPillMessage;
    _moonPillMessageTimer = setTimeout(function () {
      _moonPillMessageTimer = null;
      if (_moonPillMessage !== current) return;
      _moonPillMessage = null;
      renderAutoFixPill();
    }, MOON_PILL_MESSAGE_MS);
  }

  function checkMoonPillUpdates() {
    var polls = 0;
    function poll() {
      call("GetAboutUpdateStatus", {}).then(function (raw) {
        var result = parseAutoFixResponse(raw);
        if (!result || result.success !== true) {
          finishMoonPillBootMessage(result);
          return;
        }
        if (result.pending === true && polls++ < 40) {
          setTimeout(poll, 250);
          return;
        }
        finishMoonPillBootMessage(result);
      }).catch(function () { finishMoonPillBootMessage(null); });
    }
    poll();
  }

  function finishMoonPillBootMessage(result) {
    var S = autoFixCopy();
    if (result && result.available === true) {
      showMoonPillMessage("updates", S.updatesAvailable);
      return;
    }
    showMoonPillMessage("settings", S.settings);
  }

  function startMoonPillBootMessage() {
    if (_moonPillBootStarted) return;
    _moonPillBootStarted = true;
    setTimeout(function () {
      checkMoonPillUpdates();
    }, 80);
  }

  function renderAutoFixPill() {
    var button = document.getElementById(BTN_ID);
    if (!button) return;
    var copy = button.__autoFixCopy;
    if (!copy) return;
    var S = autoFixCopy();
    var job = _autoFixPillJob;
    if (!job) {
      if (_moonPillMessage) {
        expandMoonPill(button, copy, _moonPillMessage.label, _moonPillMessage.label);
        return;
      }
      collapseMoonPill(button, copy);
      button.title = "Lumen settings";
      button.setAttribute("aria-label", "Lumen settings");
      return;
    }
    var progress = autoFixProgress(job.progress);
    var label = S.applying + " · " + progress + "%";
    expandMoonPill(button, copy, label,
      String(job.gameName || ("App " + job.appid)) + " — "
        + autoFixStage(job, S) + " · " + progress + "%");
    button.setAttribute("aria-label", label + " — " + String(job.gameName || ""));
  }

  function decorateAutoFixButton(button) {
    if (!button || button.__autoFixDecorated) return button;
    button.__autoFixDecorated = true;
    button.textContent = "";
    var glyph = document.createElement("span");
    glyph.className = "lumen-moon-glyph";
    glyph.textContent = MOON;
    glyph.setAttribute("aria-hidden", "true");
    var copy = document.createElement("span");
    copy.className = "lumen-auto-fix-pill-copy";
    copy.setAttribute("aria-live", "polite");
    button.__autoFixCopy = copy;
    button.appendChild(glyph);
    button.appendChild(copy);
    button.setAttribute("role", "button");
    button.setAttribute("tabindex", "0");
    // A pointer click must not leave focus behind. Chromium does not paint the
    // ring for the click itself, but it re-evaluates :focus-visible on the still
    // focused element when a key event follows — so closing the window with
    // Escape lit an accent ring around the (round) button, out of nowhere.
    // Preventing the mousedown default keeps focus off it while leaving Tab
    // focus and the Enter/Space handler below untouched.
    button.addEventListener("mousedown", function (event) {
      if (typeof event.preventDefault === "function") event.preventDefault();
    });
    button.addEventListener("keydown", function (event) {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      handleMoonButtonClick(event);
    });
    renderAutoFixPill();
    return button;
  }

  function closeAutoFixModal() {
    if (_autoFixFocusTrap) {
      _autoFixFocusTrap();
      _autoFixFocusTrap = null;
    }
    var overlay = document.getElementById(AUTO_FIX_OVERLAY_ID);
    if (overlay) overlay.remove();
    _autoFixModal = null;
    try {
      if (window.GamepadNav) window.GamepadNav.setBackHandler(null);
    } catch (_) {}
  }

  function makeAutoFixAction(label, action, primary, handler) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "lumen-auto-fix-action focusable" + (primary ? " primary" : "");
    button.dataset.action = action;
    button.textContent = label;
    button.addEventListener("click", handler);
    return button;
  }

  function parseAutoFixResponse(raw) {
    if (raw && typeof raw === "object") return raw;
    try { return JSON.parse(raw); } catch (_) { return null; }
  }

  function renderAutoFixActions(job) {
    if (!_autoFixModal) return;
    var S = autoFixCopy();
    var actions = _autoFixModal.actions;
    actions.textContent = "";
    var appid = Number(_autoFixModal.appid);
    var pending = _autoFixModal.launchPending === true;

    if (pending) {
      actions.appendChild(makeAutoFixAction(S.cancelLaunch, "cancel-launch", false, function () {
        call("__lumenCancelAutoFixLaunch", { appid: appid })
          .catch(function () {}).then(closeAutoFixModal);
      }));
    }
    // The skip is offered whenever the queued work has not started writing game
    // files: while a launch is pending, and also after the guard cancelled one.
    // A cancelled launch used to leave Close as the only action, which is a dead
    // end when the job cannot finish on its own.
    if (pending || _autoFixModal.timedOut === true) {
      if (job && job.canSkip === true) {
        actions.appendChild(makeAutoFixAction(S.launchWithoutFix,
          "launch-without-fix", false, function () {
            if (!_autoFixModal || _autoFixModal.skipPending) return;
            _autoFixModal.skipPending = true;
            call("CancelLuaToolsAutoFix", { appid: appid })
              .then(function (raw) {
                var result = parseAutoFixResponse(raw);
                if (!result || result.success !== true) {
                  throw new Error((result && result.error) || S.skipFailed);
                }
                return call("__lumenReleaseAutoFixLaunch", { appid: appid });
              })
              .then(closeAutoFixModal)
              .catch(function (error) {
                if (!_autoFixModal) return;
                _autoFixModal.skipPending = false;
                _autoFixModal.error.textContent = error && error.message
                  ? error.message : S.skipFailed;
              });
          }));
      }
    }

    actions.appendChild(makeAutoFixAction(
      pending ? S.keepWaiting : S.close,
      "wait", true, closeAutoFixModal));
    if (window.GamepadNav) {
      try { window.GamepadNav.scanElements(); } catch (_) {}
    }
  }

  function updateAutoFixModal(job) {
    if (!_autoFixModal || !job) return;
    var S = autoFixCopy();
    var progress = autoFixProgress(job.progress);
    _autoFixModal.game.textContent = String(job.gameName || ("App " + job.appid));
    _autoFixModal.stage.textContent = autoFixStage(job, S);
    // A failed job has no meaningful progress. Showing 0% next to an empty bar
    // is what made a dead job look like a frozen download, so the bar is hidden
    // and the reason carries the message instead.
    var failed = job.phase === "failed";
    _autoFixModal.percent.textContent = failed ? "" : progress + "%";
    _autoFixModal.track.style.display = failed ? "none" : "";
    _autoFixModal.fill.style.width = failed ? "0%" : progress + "%";
    _autoFixModal.track.setAttribute("aria-valuenow", String(failed ? 0 : progress));
    if (!_autoFixModal.timedOut) {
      _autoFixModal.note.textContent = _autoFixModal.launchPending ? S.launchQueued : S.body;
    }
    if (_autoFixModal.canSkip !== (job.canSkip === true)) {
      _autoFixModal.canSkip = job.canSkip === true;
      renderAutoFixActions(job);
    }
  }

  function showAutoFixModal(appid, launchPending) {
    appid = Number(appid);
    var job = _autoFixJobs[String(appid)] || {
      appid: appid, gameName: "App " + appid, phase: "waiting_install",
      stage: "preparing", progress: 0, canSkip: true,
    };
    closeAutoFixModal();
    injectStyles();
    var S = autoFixCopy();

    var overlay = document.createElement("div");
    overlay.id = AUTO_FIX_OVERLAY_ID;
    overlay.className = "lumen-auto-fix-overlay";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-labelledby", "lumen-auto-fix-title");

    var modal = document.createElement("section");
    modal.className = "lumen-auto-fix-modal";
    var eyebrow = document.createElement("div");
    eyebrow.className = "lumen-auto-fix-eyebrow";
    eyebrow.textContent = S.title;
    var game = document.createElement("h2");
    game.id = "lumen-auto-fix-title";
    game.className = "lumen-auto-fix-game";
    var note = document.createElement("p");
    note.className = "lumen-auto-fix-note";
    var statusRow = document.createElement("div");
    statusRow.className = "lumen-auto-fix-status-row";
    var stage = document.createElement("span");
    var percent = document.createElement("strong");
    percent.className = "lumen-auto-fix-percent";
    statusRow.appendChild(stage); statusRow.appendChild(percent);
    var track = document.createElement("div");
    track.className = "lumen-auto-fix-track";
    track.setAttribute("role", "progressbar");
    track.setAttribute("aria-valuemin", "0");
    track.setAttribute("aria-valuemax", "100");
    var fill = document.createElement("div");
    fill.className = "lumen-auto-fix-fill";
    track.appendChild(fill);
    var error = document.createElement("div");
    error.className = "lumen-auto-fix-error";
    error.setAttribute("aria-live", "polite");
    var actions = document.createElement("div");
    actions.className = "lumen-auto-fix-actions";

    modal.appendChild(eyebrow); modal.appendChild(game); modal.appendChild(note);
    modal.appendChild(statusRow); modal.appendChild(track); modal.appendChild(error);
    modal.appendChild(actions); overlay.appendChild(modal);
    (document.body || document.documentElement).appendChild(overlay);

    _autoFixModal = {
      overlay: overlay, appid: appid, launchPending: launchPending === true,
      game: game, note: note, stage: stage, percent: percent, track: track,
      fill: fill, error: error, actions: actions, canSkip: job.canSkip === true,
      skipPending: false, timedOut: false,
    };
    updateAutoFixModal(job);
    renderAutoFixActions(job);
    overlay.addEventListener("click", function (event) {
      if (event.target === overlay) closeAutoFixModal();
    });
    _autoFixFocusTrap = trapModalFocus(
      overlay, closeAutoFixModal, "wait");
    if (window.GamepadNav) {
      try { window.GamepadNav.setBackHandler(closeAutoFixModal); } catch (_) {}
    }
  }

  function showAutoFixTimeout(appid) {
    showAutoFixModal(appid, false);
    if (!_autoFixModal) return;
    var S = autoFixCopy();
    _autoFixModal.timedOut = true;
    var eyebrow = _autoFixModal.overlay.children[0].children[0];
    if (eyebrow) eyebrow.textContent = S.timeoutTitle;
    _autoFixModal.note.textContent = S.timeoutBody;
    renderAutoFixActions(_autoFixJobs[String(appid)] || null);
  }

  // The guard dropped a saved launch because the queued work failed. Reuse the
  // cancelled-launch presentation: the job's own reason is already rendered by
  // updateAutoFixModal, and the skip stays available because the job reports
  // canSkip for a terminal failure.
  function showAutoFixFailed(appid) {
    showAutoFixModal(appid, false);
    if (!_autoFixModal) return;
    var S = autoFixCopy();
    _autoFixModal.timedOut = true;
    var eyebrow = _autoFixModal.overlay.children[0].children[0];
    if (eyebrow) eyebrow.textContent = S.failedTitle;
    _autoFixModal.note.textContent = S.failedBody;
    var job = _autoFixJobs[String(appid)] || null;
    if (job) updateAutoFixModal(job);
    renderAutoFixActions(job);
  }

  function handleMoonButtonClick(event) {
    if (event) {
      if (typeof event.preventDefault === "function") event.preventDefault();
      if (typeof event.stopPropagation === "function") event.stopPropagation();
    }
    if (_autoFixPillJob) {
      showAutoFixModal(_autoFixPillJob.appid, false);
      return;
    }
    requestOpen();
  }

  window.__lumenUpdateAutoFixUI = function (payload) {
    _autoFixJobs = payload && payload.jobs && typeof payload.jobs === "object"
      ? payload.jobs : {};
    _autoFixPillJob = pickAutoFixPillJob(_autoFixJobs);
    renderAutoFixPill();
    if (_autoFixModal) {
      var job = _autoFixJobs[String(_autoFixModal.appid)];
      if (job) updateAutoFixModal(job);
      else closeAutoFixModal();
    }
  };
  window.__lumenShowAutoFixModal = showAutoFixModal;
  window.__lumenShowAutoFixTimeout = showAutoFixTimeout;
  window.__lumenShowAutoFixFailed = showAutoFixFailed;
