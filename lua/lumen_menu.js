/*
 * lumen_menu.js — the Lumen settings menu, injected into the main Steam client
 * shell (SharedJSContext) ONLY. Deliberately minimal and shell-safe: it does
 * NOT monkey-patch history, does NOT observe document.body, and runs no periodic
 * DOM scans (those behaviours in luatools.js are why that script must never run
 * in the shell). It adds a single full-moon button next to the native menubar
 * (Steam/View/Friends/Games/Help) that opens a settings window. v1 has one tab,
 * "slsteam-moon", rendered from the schema GetSlsConfig returns.
 *
 * Backend transport: the same Millennium.callServerMethod polyfill the injector
 * installs (CDP Runtime.addBinding), so this needs zero new ports/tokens.
 */
(function () {
  if (window.__lumenMenuInjected) return;
  window.__lumenMenuInjected = true;

  var MOON = "\uD83C\uDF15"; // 🌕 full moon
  var BTN_ID = "lumen-moon-btn";
  var OVERLAY_ID = "lumen-settings-overlay";
  var STYLE_ID = "lumen-menu-styles";

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

  // ── i18n ───────────────────────────────────────────────────────────────────
  // Display strings follow the user's Steam language. EN is the base/fallback;
  // PT-BR is provided. To add a language, copy the "en" block and translate —
  // pickLang() maps navigator.language (Steam's UI locale) onto these keys.
  var I18N = {
    en: {
      note: "Changes save instantly. slsteam-moon reloads its config live; a few options only take effect after you restart Steam.",
      warnAdvanced: "Advanced — leave it as is unless you understand what it does.",
      warnDanger: "Don't change this unless you know exactly what you're doing. It can break slsteam-moon.",
      keys: {
        PlayNotOwnedGames: { label: "Play not-owned games", desc: "Lets Steam launch games that aren't in your account.", info: "You don't need to turn this on. Games you add through LuaTools are injected and install either way — this switch doesn't change that." },
        DisableFamilyShareLock: { label: "Disable Family Sharing lock", desc: "Stops Family Sharing from locking your games when someone else is playing on a shared library." },
        AutoFilterList: { label: "Auto-filter app list", desc: "Automatically limits ownership checks to games and applications. Best left on." },
        UseWhitelist: { label: "Use a whitelist", desc: "Treats the AppIds list as a whitelist (only those) instead of a blacklist (all but those)." },
        SafeMode: { label: "Safe mode", desc: "Automatically turns slsteam-moon off if Steam's client file doesn't match a known-good version. Useful on Steam Deck game mode." },
        Notifications: { label: "Notifications", desc: "Show desktop notifications from slsteam-moon (uses notify-send)." },
        NotifyInit: { label: "Notify when ready", desc: "Show a notification once slsteam-moon has finished loading." },
        WarnHashMissmatch: { label: "Warn on client change", desc: "Notify when Steam's client file differs from the known-good version. Mostly for development." },
        API: { label: "Control socket (API)", desc: "Lets external tools send commands to slsteam-moon through a local socket." },
        DisableCloud: { label: "Disable Steam Cloud", desc: "Keep this OFF if you use CloudRedirect for cloud saves. Turn it ON only if you don't sync saves at all." },
        ExtendedLogging: { label: "Verbose logging", desc: "Logs every Steam call. For debugging only — it makes the log file very large." },
        FakeEmail: { label: "Fake e-mail", desc: "Shows a made-up e-mail in the Steam client only (cosmetic). Leave blank to disable." },
        FakeWalletBalance: { label: "Fake wallet balance", desc: "Shows a made-up wallet balance in the client only (cosmetic). 0 disables it." },
        LogLevel: { label: "Log level", desc: "How much detail slsteam-moon writes to its log file. Default is 2 (Info)." },
      },
    },
    "pt-BR": {
      note: "As mudanças são salvas na hora. O slsteam-moon recarrega a config ao vivo; algumas opções só valem depois de reiniciar a Steam.",
      warnAdvanced: "Avançado — deixe como está, a menos que entenda o que faz.",
      warnDanger: "Não mexa se você não souber exatamente o que está fazendo. Esta opção pode quebrar o funcionamento do slsteam-moon.",
      keys: {
        PlayNotOwnedGames: { label: "Jogar jogos não adquiridos", desc: "Permite que a Steam abra jogos que não estão na sua conta.", info: "Você não precisa ativar isso. Os jogos que você adiciona pelo LuaTools são injetados e instalam de qualquer jeito — esta opção não muda isso." },
        DisableFamilyShareLock: { label: "Desativar trava do Family Share", desc: "Impede que o Compartilhamento Familiar trave seus jogos quando outra pessoa está jogando numa biblioteca compartilhada." },
        AutoFilterList: { label: "Filtrar lista de apps automaticamente", desc: "Limita as verificações de propriedade a jogos e aplicativos automaticamente. Melhor deixar ligado." },
        UseWhitelist: { label: "Usar lista de permissões", desc: "Trata a lista de AppIds como permissões (só esses) em vez de bloqueio (todos menos esses)." },
        SafeMode: { label: "Modo seguro", desc: "Desliga o slsteam-moon automaticamente se o arquivo do cliente Steam não bater com uma versão conhecida. Útil no modo jogo do Steam Deck." },
        Notifications: { label: "Notificações", desc: "Mostra notificações da área de trabalho do slsteam-moon (usa notify-send)." },
        NotifyInit: { label: "Avisar quando pronto", desc: "Mostra uma notificação quando o slsteam-moon termina de carregar." },
        WarnHashMissmatch: { label: "Avisar se o cliente mudar", desc: "Notifica quando o arquivo do cliente Steam muda em relação à versão conhecida. Útil principalmente para desenvolvimento." },
        API: { label: "Soquete de controle (API)", desc: "Permite que ferramentas externas enviem comandos ao slsteam-moon por um soquete local." },
        DisableCloud: { label: "Desativar Steam Cloud", desc: "Deixe DESLIGADO se você usa o CloudRedirect para saves na nuvem. Ligue só se você não sincroniza saves." },
        ExtendedLogging: { label: "Log detalhado", desc: "Registra toda chamada à Steam. Só para depuração — deixa o arquivo de log enorme." },
        FakeEmail: { label: "E-mail falso", desc: "Mostra um e-mail inventado só no cliente Steam (cosmético). Deixe em branco para desativar." },
        FakeWalletBalance: { label: "Saldo falso da carteira", desc: "Mostra um saldo inventado só no cliente (cosmético). 0 desativa." },
        LogLevel: { label: "Nível de log", desc: "Quanto detalhe o slsteam-moon escreve no arquivo de log. O padrão é 2 (Info)." },
      },
    },
  };

  // pickLang() -> a key of I18N, following Steam's UI locale (navigator.language).
  function pickLang() {
    try {
      var raw = navigator.language || "en";
      if (I18N[raw]) return raw;
      var p = raw.toLowerCase().split("-")[0];
      if (p === "pt") return "pt-BR";
      if (I18N[p]) return p;
    } catch (e) {}
    return "en";
  }

  // ── styles (match the native Steam Settings window exactly) ────────────────
  function injectStyles() {
    if (document.getElementById(STYLE_ID)) return;
    var s = document.createElement("style");
    s.id = STYLE_ID;
    s.textContent = [
      "#" + BTN_ID + "{display:inline-flex;align-items:center;justify-content:center;",
      "cursor:pointer;font-size:13px;line-height:1;padding:2px 8px;margin:0 2px;",
      "opacity:.8;-webkit-app-region:no-drag;user-select:none;border-radius:3px;}",
      "#" + BTN_ID + ":hover{opacity:1;background:rgba(255,255,255,.08);}",
      "#" + OVERLAY_ID + "{position:fixed;inset:0;z-index:99999;display:flex;",
      "align-items:center;justify-content:center;background:rgba(0,0,0,.55);",
      "font-family:'Motiva Sans',Arial,Helvetica,sans-serif;}",
      // window
      ".lumen-win{display:flex;width:900px;max-width:94vw;height:620px;max-height:88vh;",
      "border-radius:4px;overflow:hidden;box-shadow:0 20px 60px rgba(0,0,0,.6);",
      "border:1px solid rgba(0,0,0,.5);}",
      // sidebar
      ".lumen-side{flex:0 0 200px;background:#2a2d34;display:flex;flex-direction:column;",
      "padding-top:8px;overflow-y:auto;}",
      ".lumen-side-title{color:#1a9fff;font-size:17px;font-weight:700;text-transform:uppercase;",
      "padding:14px 24px 16px;}",
      ".lumen-tab{display:flex;align-items:center;gap:12px;padding:10px 8px 10px 24px;",
      "height:20px;color:#b8bcbf;font-size:14px;cursor:pointer;}",
      ".lumen-tab:hover{background:rgba(255,255,255,.04);}",
      ".lumen-tab.active{background:#3d4450;color:#fff;}",
      ".lumen-tab .ico{display:inline-flex;width:16px;height:16px;flex:0 0 16px;}",
      // content
      ".lumen-content{flex:1;background:#25282e;background-image:radial-gradient(circle at left top,",
      "rgba(74,81,92,.4) 0%,rgba(75,81,92,0) 60%);display:flex;flex-direction:column;overflow:hidden;}",
      ".lumen-ctop{display:flex;align-items:center;padding:24px 24px 14px;}",
      ".lumen-ctop .h{flex:1;color:#fff;font-size:22px;font-weight:700;}",
      ".lumen-ctop .x{cursor:pointer;color:#b8bcbf;font-size:18px;padding:2px 8px;border-radius:3px;}",
      ".lumen-ctop .x:hover{color:#fff;background:rgba(255,255,255,.08);}",
      ".lumen-body{padding:0 24px 22px;overflow-y:auto;overflow-x:hidden;}",
      ".lumen-note{color:#8f98a0;font-size:12px;padding:0 0 10px;line-height:1.4;}",
      ".lumen-row{display:flex;align-items:flex-start;gap:14px;padding:12px 2px;",
      "border-bottom:1px solid rgba(255,255,255,.06);}",
      ".lumen-lblwrap{flex:1;display:flex;flex-direction:column;gap:4px;min-width:0;}",
      ".lumen-row .lbl{color:#dcdedf;font-size:14px;}",
      ".lumen-desc{color:#8f98a0;font-size:12px;line-height:1.45;}",
      ".lumen-line{font-size:12px;line-height:1.45;display:flex;gap:6px;align-items:flex-start;}",
      ".lumen-line .i{flex:0 0 auto;}",
      ".lumen-line.info{color:#66c0f4;}",
      ".lumen-line.advanced{color:#e0b341;}",
      ".lumen-line.danger{color:#ec5c5c;}",
      ".lumen-ctrl{flex:0 0 auto;margin-top:1px;display:inline-flex;align-items:center;}",
      ".lumen-row input[type=text],.lumen-row input[type=number],.lumen-row select{",
      "background:#1a1d23;color:#dcdedf;border:1px solid #3d4450;border-radius:3px;",
      "padding:6px 8px;min-width:130px;font-size:13px;font-family:inherit;}",
      ".lumen-row select:hover,.lumen-row input:hover{border-color:#4a5663;}",
      ".lumen-sw{position:relative;display:inline-block;width:38px;height:20px;flex:0 0 auto;}",
      ".lumen-sw input{opacity:0;width:0;height:0;position:absolute;}",
      ".lumen-sw .sl{position:absolute;inset:0;background:#3d4450;border-radius:20px;transition:.15s;cursor:pointer;}",
      ".lumen-sw .sl:before{content:'';position:absolute;width:14px;height:14px;left:3px;top:3px;",
      "background:#fff;border-radius:50%;transition:.15s;}",
      ".lumen-sw input:checked + .sl{background:#1a9fff;}",
      ".lumen-sw input:checked + .sl:before{transform:translateX(18px);}",
      ".lumen-err{color:#ec5c5c;font-size:13px;padding:12px 0;}",
    ].join("");
    (document.head || document.documentElement).appendChild(s);
  }

  // ── settings overlay (lazy) ────────────────────────────────────────────────
  // Local close — just removes this context's overlay. Exposed as
  // window.__lumenCloseOverlay so the sidecar can close it across all contexts.
  function closeOverlay() {
    var o = document.getElementById(OVERLAY_ID);
    if (o) o.remove();
  }
  // Ask the sidecar to close the overlay in EVERY context (the visible one and
  // the hidden duplicates in the other views).
  function requestClose() {
    call("__lumenClose").catch(function () {});
  }
  // Ask the sidecar to open the overlay in every context, so whichever view is
  // currently on top shows it (the menubar button lives in the main window, but
  // the active view may be a store/community web view composited above it).
  function requestOpen() {
    call("__lumenOpen").catch(function () {});
  }

  // Append an info/warning line (icon + text) with the given severity class.
  function addLine(wrap, text, cls, icon) {
    var w = document.createElement("div");
    w.className = "lumen-line " + cls;
    var ic = document.createElement("span");
    ic.className = "i";
    ic.textContent = icon;
    var tx = document.createElement("span");
    tx.textContent = text;
    w.appendChild(ic); w.appendChild(tx);
    wrap.appendChild(w);
  }

  function makeRow(entry, value, S, onChange) {
    var row = document.createElement("div");
    row.className = "lumen-row";

    var wrap = document.createElement("div");
    wrap.className = "lumen-lblwrap";
    var ks = (S.keys && S.keys[entry.key]) || {};
    var lbl = document.createElement("div");
    lbl.className = "lbl";
    lbl.textContent = ks.label || entry.label || entry.key;
    wrap.appendChild(lbl);
    if (ks.desc) {
      var d = document.createElement("div");
      d.className = "lumen-desc";
      d.textContent = ks.desc;
      wrap.appendChild(d);
    }
    // Per-level guidance line.
    if (entry.level === "info" && ks.info) {
      addLine(wrap, ks.info, "info", "\u2139");          // ℹ
    } else if (entry.level === "advanced") {
      addLine(wrap, S.warnAdvanced, "advanced", "\u26A0"); // ⚠
    } else if (entry.level === "danger") {
      addLine(wrap, S.warnDanger, "danger", "\u26A0");
    }
    row.appendChild(wrap);

    var ctrl = document.createElement("span");
    ctrl.className = "lumen-ctrl";
    if (entry.type === "bool") {
      var sw = document.createElement("label");
      sw.className = "lumen-sw";
      var cb = document.createElement("input");
      cb.type = "checkbox";
      cb.checked = !!value;
      var sl = document.createElement("span");
      sl.className = "sl";
      cb.addEventListener("change", function () { onChange(cb.checked); });
      sw.appendChild(cb); sw.appendChild(sl);
      ctrl.appendChild(sw);
    } else if (entry.type === "enum") {
      var sel = document.createElement("select");
      (entry.options || []).forEach(function (opt, i) {
        var o = document.createElement("option");
        o.value = String(opt);
        o.textContent = (entry.option_labels && entry.option_labels[i]) || String(opt);
        if (String(opt) === String(value)) o.selected = true;
        sel.appendChild(o);
      });
      sel.addEventListener("change", function () { onChange(Number(sel.value)); });
      ctrl.appendChild(sel);
    } else if (entry.type === "int") {
      var ni = document.createElement("input");
      ni.type = "number";
      ni.value = String(value != null ? value : 0);
      ni.addEventListener("change", function () { onChange(Number(ni.value) || 0); });
      ctrl.appendChild(ni);
    } else {
      var ti = document.createElement("input");
      ti.type = "text";
      ti.value = value != null ? String(value) : "";
      ti.addEventListener("change", function () { onChange(ti.value); });
      ctrl.appendChild(ti);
    }
    row.appendChild(ctrl);
    return row;
  }

  function renderConfig(body, config) {
    var S = I18N[pickLang()] || I18N.en;
    body.textContent = "";
    var note = document.createElement("div");
    note.className = "lumen-note";
    note.textContent = S.note;
    body.appendChild(note);

    (config.schema || []).forEach(function (entry) {
      var current = (config.values || {})[entry.key];
      if (current === undefined) current = entry.default;
      var row = makeRow(entry, current, S, function (newVal) {
        call("SetSlsConfig", { json: JSON.stringify({ key: entry.key, value: newVal }) })
          .then(function (res) {
            var ok = false;
            try { ok = JSON.parse(res).success; } catch (e) {}
            if (!ok) log("SetSlsConfig failed for", entry.key, res);
          })
          .catch(function (e) { log("SetSlsConfig error", entry.key, e); });
      });
      body.appendChild(row);
    });
  }

  // Moon icon (SVG, currentColor) used for the slsteam-moon tab.
  var MOON_SVG = '<svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="6" fill="currentColor"/></svg>';

  function openOverlay() {
    if (document.getElementById(OVERLAY_ID)) return;
    injectStyles();

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
    var tab = document.createElement("div");
    tab.className = "lumen-tab active";
    var ico = document.createElement("span");
    ico.className = "ico";
    ico.innerHTML = MOON_SVG;
    var tlbl = document.createElement("span");
    tlbl.textContent = "slsteam-moon";
    tab.appendChild(ico); tab.appendChild(tlbl);
    side.appendChild(tab);

    // content
    var content = document.createElement("div");
    content.className = "lumen-content";
    var ctop = document.createElement("div");
    ctop.className = "lumen-ctop";
    var h = document.createElement("div");
    h.className = "h";
    h.textContent = "slsteam-moon";
    var x = document.createElement("div");
    x.className = "x";
    x.textContent = "\u2715";
    x.addEventListener("click", requestClose);
    ctop.appendChild(h); ctop.appendChild(x);

    var body = document.createElement("div");
    body.className = "lumen-body";
    body.textContent = "Loading\u2026";

    content.appendChild(ctop);
    content.appendChild(body);
    win.appendChild(side);
    win.appendChild(content);
    overlay.appendChild(win);
    (document.body || document.documentElement).appendChild(overlay);

    call("GetSlsConfig", {})
      .then(function (res) {
        var config = JSON.parse(res);
        if (!config || !config.success) throw new Error((config && config.error) || "load failed");
        renderConfig(body, config);
      })
      .catch(function (e) {
        body.textContent = "";
        var err = document.createElement("div");
        err.className = "lumen-err";
        err.textContent = "Failed to load slsteam-moon config: " + (e && e.message ? e.message : e);
        body.appendChild(err);
      });

    var onKey = function (e) {
      if (e.key === "Escape") { requestClose(); document.removeEventListener("keydown", onKey, true); }
    };
    document.addEventListener("keydown", onKey, true);
  }

  // ── menubar button ──────────────────────────────────────────────────────────
  var MENU_LABELS = ["Steam", "View", "Friends", "Games", "Help"];

  // Find the native menubar. Each label (View/Friends/Games/Help) is a leaf div
  // wrapped in its own container, and all those wrappers share a common menubar
  // row. So: collect the label leaves, then climb from one until we hit the
  // lowest ancestor that contains >= 3 of them — that ancestor is the menubar.
  // Selector-free (class names are hashed and churn across Steam updates), tuned
  // against the live DOM on the test VM. Returns { bar, helpItem } or null.
  function findMenubar() {
    var nodes = document.querySelectorAll("div,span,button,a");
    var leaves = [];
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.children && el.children.length !== 0) continue; // leaf only
      var txt = (el.textContent || "").trim();
      if (MENU_LABELS.indexOf(txt) === -1) continue;
      leaves.push({ txt: txt, el: el });
    }
    if (leaves.length < 3) return null;

    function countIn(node) {
      var c = 0;
      for (var j = 0; j < leaves.length; j++) if (node.contains(leaves[j].el)) c++;
      return c;
    }
    var bar = null, n = leaves[0].el.parentElement;
    while (n) {
      if (countIn(n) >= 3) { bar = n; break; }
      n = n.parentElement;
    }
    if (!bar) return null;

    var helpItem = null;
    for (var k = 0; k < leaves.length; k++) if (leaves[k].txt === "Help") helpItem = leaves[k].el;
    return { bar: bar, helpItem: helpItem };
  }

  function makeButton() {
    var b = document.createElement("div");
    b.id = BTN_ID;
    b.textContent = MOON;
    b.title = "Lumen settings";
    b.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      openOverlay();
    });
    return b;
  }

  // Insert the button into the menubar, after the wrapper that holds "Help"
  // (so it sits at the end of the menu row), else appended. Idempotent.
  function ensureButton(found) {
    if (document.getElementById(BTN_ID)) return true;
    injectStyles();
    var btn = makeButton();
    var bar = found.bar;
    var helpWrapper = found.helpItem;
    while (helpWrapper && helpWrapper.parentElement !== bar) helpWrapper = helpWrapper.parentElement;
    if (helpWrapper && helpWrapper.nextSibling) bar.insertBefore(btn, helpWrapper.nextSibling);
    else bar.appendChild(btn);
    return true;
  }

  var observer = null;
  function startObserver(bar) {
    if (observer) return;
    // Scoped to the menubar node ONLY (never document.body) so it's cheap and
    // re-adds the button if React reconciles the bar and drops our child.
    observer = new MutationObserver(function () {
      if (!document.getElementById(BTN_ID)) {
        var f = findMenubar();
        if (f) ensureButton(f);
      }
    });
    try { observer.observe(bar, { childList: true }); } catch (e) {}
  }

  // Anchor with a few bounded retries (the menubar may not exist at first paint);
  // no infinite polling — give up gracefully if never found.
  var attempts = 0;
  function tryAnchor() {
    window.__lumenAnchorAttempts = (window.__lumenAnchorAttempts || 0) + 1;
    if (document.getElementById(BTN_ID)) return;
    var f = findMenubar();
    window.__lumenLastFind = f ? "found" : "null";
    if (f) {
      ensureButton(f);
      startObserver(f.bar);
      log("anchored full-moon button");
      return;
    }
    attempts++;
    if (attempts <= 30) setTimeout(tryAnchor, 1000); // up to ~30s after load
    else log("menubar not found; giving up (graceful)");
  }

  tryAnchor();
  log("loaded");
})();
