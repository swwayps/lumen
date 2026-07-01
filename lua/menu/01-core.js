/*
 * lumen menu — the Lumen settings menu, injected into the main Steam client
 * shell (SharedJSContext) ONLY. Deliberately minimal and shell-safe: it does
 * NOT monkey-patch history, does NOT observe document.body, and runs no periodic
 * DOM scans (those behaviours in luatools.js are why that script must never run
 * in the shell). It adds a single full-moon button next to the native menubar
 * (Steam/View/Friends/Games/Help) that opens a settings window with two tabs:
 * "slsteam-moon" (rendered from the schema GetSlsConfig returns) and
 * "Game Updates" (manifest pinning).
 *
 * Backend transport: the same Millennium.callServerMethod polyfill the injector
 * installs (CDP Runtime.addBinding), so this needs zero new ports/tokens.
 *
 * ── FILE LAYOUT ─────────────────────────────────────────────────────────────
 * This used to be one ~1.2k-line file. It is now split into ordered fragments,
 * one concern per file, for readability and easier editing:
 *   01-core.js            this file: IIFE open, idempotency guard, shared
 *                         constants, log(), call() backend transport
 *   02-i18n.js            display strings (en, pt-BR) + pickLang()
 *   03-styles.js          injectStyles() — all menu CSS
 *   04-overlay-helpers.js open/close relays + addLine()
 *   05-config-tab.js      slsteam-moon settings tab (makeRow, renderConfig)
 *   06-updates-helpers.js Game Updates helpers (icons, build timeline, verRow,
 *                         validate prompt, depot labelling)
 *   07-updates-tab.js     Game Updates tab (renderDlcSubpage, gameCard,
 *                         renderGameUpdates)
 *   08-about-tab.js       About tab (renderAbout: versions, Reload All,
 *                         Update All, credit)
 *   09-overlay.js         the settings window (openOverlay) + window.__lumen*
 *   10-fixes-menu.js      library-page Fixes Menu (entry next to the gear)
 *   11-menubar.js         menubar button (findMenubar, anchoring) + bootstrap
 *
 * The fragments share ONE closure (the IIFE this file opens and 11-menubar
 * closes), so they are NOT standalone modules — boot.lua (read_menu_js)
 * concatenates them in order into a single string and injects that as one unit.
 * Edit a fragment to change only its concern; keep the open/close at the ends.
 */
(function () {
  if (window.__lumenMenuInjected) return;
  window.__lumenMenuInjected = true;

  var MOON = "\uD83C\uDF15"; // 🌕 full moon
  var BTN_ID = "lumen-moon-btn";
  var OVERLAY_ID = "lumen-settings-overlay";
  var STYLE_ID = "lumen-menu-styles";
  var _escHandler = null; // active Escape listener, so closeOverlay can drop it

  function log() {
    try { console.log.apply(console, ["[lumen-menu]"].concat([].slice.call(arguments))); } catch (e) {}
  }

  function call(fn, args) {
    try {
      if (!window.Millennium || !window.Millennium.callServerMethod) {
        return Promise.reject(new Error("callServerMethod unavailable"));
      }
      return window.Millennium.callServerMethod("lumen", fn, args || {});
    } catch (e) {
      return Promise.reject(e);
    }
  }

