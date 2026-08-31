// LM-FRAGMENT automatic-fix menubar pill
// LM-FRAGMENT source fragment of lumen_menu, assembled into the shared IIFE.

  var _autoFixJobs = {};
  var _autoFixPillJob = null;
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
      preparing: "Preparing the recommended fix",
      needsLogin: "Waiting for lua.tools login",
      downloading: "Downloading fix files",
      extracting: "Extracting to a private staging folder",
      applyingFiles: "Applying files to the game",
      finalizing: "Finishing launch settings",
      cancelling: "Cancelling fix",
      failed: "The recommended fix could not be applied",
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
    if (stage === "cancelling" || (job && job.phase === "cancelling")) return S.cancelling;
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
      if (job && (job.phase === "applying" || job.phase === "finalizing"
          || job.phase === "cancelling")) return job;
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

  function parseAutoFixResponse(raw) {
    if (raw && typeof raw === "object") return raw;
    try { return JSON.parse(raw); } catch (_) { return null; }
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
    var label = (job.phase === "cancelling" ? S.cancelling : S.applying)
      + " · " + progress + "%";
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

  function handleMoonButtonClick(event) {
    if (event) {
      if (typeof event.preventDefault === "function") event.preventDefault();
      if (typeof event.stopPropagation === "function") event.stopPropagation();
    }
    requestOpen();
  }

  window.__lumenUpdateAutoFixUI = function (payload) {
    _autoFixJobs = payload && payload.jobs && typeof payload.jobs === "object"
      ? payload.jobs : {};
    _autoFixPillJob = pickAutoFixPillJob(_autoFixJobs);
    renderAutoFixPill();
  };
