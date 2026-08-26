// LM-FRAGMENT install-readiness modal + recovery notification
// LM-FRAGMENT source fragment of lumen_menu, assembled into the shared IIFE.

  var INSTALL_READINESS_OVERLAY_ID = "lumen-install-readiness-overlay";
  var INSTALL_READINESS_TOAST_ID = "lumen-install-readiness-toast";
  var _installReadinessEsc = null;

  function closeInstallReadinessModal() {
    var overlay = document.getElementById(INSTALL_READINESS_OVERLAY_ID);
    if (overlay) overlay.remove();
    if (_installReadinessEsc) {
      document.removeEventListener("keydown", _installReadinessEsc, true);
      _installReadinessEsc = null;
    }
    try {
      if (window.GamepadNav) window.GamepadNav.setBackHandler(null);
    } catch (_) {}
  }

  function installReadinessButton(label, action, primary, handler) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "lumen-install-readiness-action focusable"
      + (primary ? " primary" : "");
    button.dataset.action = action;
    button.textContent = label;
    button.addEventListener("click", function (event) {
      event.preventDefault();
      event.stopPropagation();
      handler();
    });
    return button;
  }

  function showInstallReadinessBlocked(appid) {
    appid = Number(appid);
    if (!Number.isFinite(appid) || appid <= 0 || Math.floor(appid) !== appid) return;
    injectStyles();
    closeInstallReadinessModal();
    var S = installReadinessStrings();

    var overlay = document.createElement("div");
    overlay.id = INSTALL_READINESS_OVERLAY_ID;
    overlay.className = "lumen-install-readiness-overlay";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-labelledby", "lumen-install-readiness-title");

    var modal = document.createElement("div");
    modal.className = "lumen-install-readiness-modal";
    var eyebrow = document.createElement("div");
    eyebrow.className = "lumen-install-readiness-eyebrow";
    eyebrow.textContent = S.eyebrow;
    var title = document.createElement("div");
    title.id = "lumen-install-readiness-title";
    title.className = "lumen-install-readiness-title";
    title.textContent = S.title;
    var body = document.createElement("p");
    body.className = "lumen-install-readiness-body";
    body.textContent = S.body;
    var risk = document.createElement("p");
    risk.className = "lumen-install-readiness-risk";
    risk.textContent = S.risk;
    var actions = document.createElement("div");
    actions.className = "lumen-install-readiness-actions";

    var close = installReadinessButton(S.close, "close", true,
      closeInstallReadinessModal);
    var installAnyway = installReadinessButton(
      S.installAnyway, "install-anyway", false, function () {
        closeInstallReadinessModal();
        call("__lumenInstallAnyway", { appid: appid }).catch(function (error) {
          log("install-anyway", error);
        });
      });
    actions.appendChild(installAnyway);
    actions.appendChild(close);
    modal.appendChild(eyebrow);
    modal.appendChild(title);
    modal.appendChild(body);
    modal.appendChild(risk);
    modal.appendChild(actions);
    overlay.appendChild(modal);
    (document.body || document.documentElement).appendChild(overlay);

    overlay.addEventListener("click", function (event) {
      if (event.target === overlay) closeInstallReadinessModal();
    });
    _installReadinessEsc = function (event) {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      closeInstallReadinessModal();
    };
    document.addEventListener("keydown", _installReadinessEsc, true);
    try {
      if (window.GamepadNav) {
        window.GamepadNav.setBackHandler(closeInstallReadinessModal);
        window.GamepadNav.scanElements();
      }
    } catch (_) {}
    setTimeout(function () { close.focus(); }, 0);
  }

  function showInstallReadinessReady() {
    injectStyles();
    var old = document.getElementById(INSTALL_READINESS_TOAST_ID);
    if (old) old.remove();
    var toast = document.createElement("div");
    toast.id = INSTALL_READINESS_TOAST_ID;
    toast.className = "lumen-install-readiness-toast";
    toast.setAttribute("role", "status");
    toast.textContent = installReadinessStrings().ready;
    (document.body || document.documentElement).appendChild(toast);
    setTimeout(function () { if (toast.parentElement) toast.remove(); }, 6000);
  }

  window.__lumenShowInstallReadinessBlocked = showInstallReadinessBlocked;
  window.__lumenShowInstallReadinessReady = showInstallReadinessReady;
