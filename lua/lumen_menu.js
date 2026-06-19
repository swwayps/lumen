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

  // ── i18n ───────────────────────────────────────────────────────────────────
  // Display strings follow the user's Steam language. EN is the base/fallback;
  // PT-BR is provided. To add a language, copy the "en" block and translate —
  // pickLang() maps navigator.language (Steam's UI locale) onto these keys.
  var I18N = {
    en: {
      note: "Changes save instantly. slsteam-moon reloads its config live; a few options only take effect after you restart Steam.",
      warnAdvanced: "Advanced — leave it as is unless you understand what it does.",
      warnDanger: "Don't change this unless you know exactly what you're doing. It can break slsteam-moon.",
      reset: "Reset to defaults",
      resetConfirm: "Click again to confirm",
      resetFail: "Reset failed: ",
      gu: {
        tab: "Game Updates",
        title: "Game Updates",
        note: "Lock a game to a build you've archived, or override a single component's version. Only versions you have on disk can be selected.",
        search: "Search games\u2026",
        current: "current version",
        fromLua: "from LuaTools",
        latest: "Latest (auto-update)",
        locked: "Locked",
        dlcs: "DLCs",
        back: "Back",
        dlcTitle: "Components & DLC",
        emptyDlc: "You don't have this game's manifests, or it has no DLCs.",
        none: "No LuaTools games with archived versions yet.",
        loadFail: "Failed to load game versions: ",
        saveFail: "Could not save: ",
        depot: "Depot",
      },
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
      reset: "Restaurar padrões",
      resetConfirm: "Clique de novo pra confirmar",
      resetFail: "Falha ao restaurar: ",
      gu: {
        tab: "Atualiza\u00e7\u00f5es",
        title: "Atualiza\u00e7\u00f5es de jogos",
        note: "Trave um jogo numa vers\u00e3o que voc\u00ea arquivou, ou sobrescreva a vers\u00e3o de um componente. S\u00f3 d\u00e1 pra escolher vers\u00f5es que voc\u00ea tem no disco.",
        search: "Buscar jogos\u2026",
        current: "vers\u00e3o atual",
        fromLua: "do LuaTools",
        latest: "Mais recente (atualizar)",
        locked: "Travado",
        dlcs: "DLCs",
        back: "Voltar",
        dlcTitle: "Componentes e DLC",
        emptyDlc: "Voc\u00ea n\u00e3o tem os manifests desse jogo, ou ele n\u00e3o tem DLCs.",
        none: "Nenhum jogo do LuaTools com vers\u00f5es arquivadas ainda.",
        loadFail: "Falha ao carregar vers\u00f5es: ",
        saveFail: "N\u00e3o foi poss\u00edvel salvar: ",
        depot: "Depot",
      },
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
      "padding-top:8px;overflow-y:auto;overscroll-behavior:contain;}",
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
      ".lumen-ctop .reset{cursor:pointer;color:#b8bcbf;font-size:12px;font-weight:600;" +
        "margin-right:10px;padding:5px 12px;border-radius:4px;white-space:nowrap;" +
        "border:1px solid rgba(255,255,255,.14);transition:.12s;}",
      ".lumen-ctop .reset:hover{color:#fff;background:rgba(255,255,255,.08);}",
      ".lumen-ctop .reset.confirm{color:#ffb84d;border-color:#ffb84d;}",
      ".lumen-body{padding:0 24px 22px;overflow-y:auto;overflow-x:hidden;overscroll-behavior:contain;}",
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
      // Game Updates tab
      ".lumen-gu-search{width:100%;box-sizing:border-box;background:#1a1d23;color:#dcdedf;",
      "border:1px solid #3d4450;border-radius:3px;padding:8px 10px;font-size:13px;",
      "font-family:inherit;margin:0 0 12px;}",
      ".lumen-gu-search:focus{outline:none;border-color:#1a9fff;}",
      ".lumen-game{border-bottom:1px solid rgba(255,255,255,.06);}",
      ".lumen-game-head{display:flex;align-items:center;gap:12px;padding:10px 2px;cursor:pointer;}",
      ".lumen-game-head:hover{background:rgba(255,255,255,.03);}",
      ".lumen-cap{flex:0 0 auto;width:92px;height:43px;border-radius:3px;object-fit:cover;",
      "background:#1a1d23;}",
      ".lumen-game-meta{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px;}",
      ".lumen-game-name{color:#dcdedf;font-size:14px;white-space:nowrap;overflow:hidden;",
      "text-overflow:ellipsis;}",
      ".lumen-game-sub{color:#8f98a0;font-size:11px;}",
      ".lumen-badge{display:inline-block;font-size:10px;font-weight:700;text-transform:uppercase;",
      "padding:2px 6px;border-radius:3px;margin-left:6px;vertical-align:middle;}",
      ".lumen-badge.lock{background:#3a2f1a;color:#ffb84d;}",
      ".lumen-badge.cur{background:#1a3a24;color:#6fd08c;}",
      ".lumen-badge.lt{background:#1a2c3a;color:#66c0f4;}",
      ".lumen-dlcs-btn{flex:0 0 auto;color:#b8bcbf;font-size:13px;padding:4px 10px;border-radius:3px;",
      "border:1px solid rgba(255,255,255,.14);cursor:pointer;white-space:nowrap;}",
      ".lumen-dlcs-btn:hover{color:#fff;background:rgba(255,255,255,.08);}",
      ".lumen-vers{padding:4px 2px 10px 104px;display:flex;flex-direction:column;gap:2px;}",
      ".lumen-ver{display:flex;align-items:center;gap:10px;padding:6px 8px;border-radius:3px;",
      "cursor:pointer;font-size:13px;color:#cdd1d4;}",
      ".lumen-ver:hover{background:rgba(255,255,255,.05);}",
      ".lumen-ver.sel{background:#2b3340;}",
      ".lumen-ver .dot{flex:0 0 auto;width:12px;height:12px;border-radius:50%;border:2px solid #6b7280;}",
      ".lumen-ver.sel .dot{border-color:#1a9fff;background:#1a9fff;}",
      ".lumen-ver .vgid{color:#8f98a0;font-size:11px;font-family:monospace;}",
      ".lumen-back{display:inline-flex;align-items:center;gap:6px;cursor:pointer;color:#b8bcbf;",
      "font-size:13px;}",
      ".lumen-back:hover{color:#fff;}",
      ".lumen-empty{color:#8f98a0;font-size:13px;padding:20px 4px;text-align:center;}",
    ].join("");
    (document.head || document.documentElement).appendChild(s);
  }

  // ── settings overlay (lazy) ────────────────────────────────────────────────
  // Local close — just removes this context's overlay. Exposed as
  // window.__lumenCloseOverlay so the sidecar can close it across all contexts.
  function closeOverlay() {
    var o = document.getElementById(OVERLAY_ID);
    if (o) o.remove();
    if (_escHandler) {
      document.removeEventListener("keydown", _escHandler, true);
      _escHandler = null;
    }
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
  // Download/version icon for the Game Updates tab.
  var GU_SVG = '<svg viewBox="0 0 16 16" width="16" height="16"><path fill="currentColor" d="M8 1a1 1 0 0 1 1 1v6.6l2-2 1.4 1.4L8 12.4 3.6 8 5 6.6l2 2V2a1 1 0 0 1 1-1zM3 13h10v2H3z"/></svg>';

  // ── Game Updates helpers ────────────────────────────────────────────────
  var _nameCache = {};
  function capsuleUrl(appid) {
    return "https://cdn.cloudflare.steamstatic.com/steam/apps/" + appid + "/header.jpg";
  }
  // Resolve an app name via the same Steam store API luatools.js uses. Cached;
  // resolves to null on any failure (caller falls back to the appid).
  function fetchAppName(appid) {
    if (_nameCache[appid]) return Promise.resolve(_nameCache[appid]);
    try {
      return fetch("https://store.steampowered.com/api/appdetails?appids=" + appid + "&filters=basic")
        .then(function (r) { return r.json(); })
        .then(function (j) {
          var d = j && j[appid] && j[appid].success && j[appid].data;
          var name = d && d.name ? d.name : null;
          if (name) _nameCache[appid] = name;
          return name;
        })
        .catch(function () { return null; });
    } catch (e) { return Promise.resolve(null); }
  }
  // Unix seconds -> dd/mm/yyyy (UTC). 0/missing -> em dash.
  function fmtDate(unix) {
    if (!unix) return "\u2014";
    var d = new Date(unix * 1000);
    var p = function (n) { return (n < 10 ? "0" : "") + n; };
    return p(d.getUTCDate()) + "/" + p(d.getUTCMonth() + 1) + "/" + d.getUTCFullYear();
  }

  // Collapse a game's per-depot versions into a single build timeline keyed by
  // date (a "whole-game lock" pins every depot as-of a date, so the user picks a
  // date, not a per-depot gid). Newest first. Each build: {date, fromLua,
  // installed, pinned}.
  function gameBuilds(game) {
    var byDate = {};
    (game.depots || []).forEach(function (d) {
      (d.versions || []).forEach(function (v) {
        var e = byDate[v.date] || { date: v.date, fromLua: false, installed: false, pinned: false };
        if (v.fromLuaTools) e.fromLua = true;
        if (v.installed) e.installed = true;
        if (v.pinned) e.pinned = true;
        byDate[v.date] = e;
      });
    });
    var arr = [];
    Object.keys(byDate).forEach(function (k) { arr.push(byDate[k]); });
    arr.sort(function (a, b) { return b.date - a.date; });
    return arr;
  }

  // A small selectable version row (radio dot + label + optional badges).
  function verRow(opts) {
    var row = document.createElement("div");
    row.className = "lumen-ver" + (opts.selected ? " sel" : "");
    var dot = document.createElement("span");
    dot.className = "dot";
    row.appendChild(dot);
    var lbl = document.createElement("span");
    lbl.textContent = opts.label;
    row.appendChild(lbl);
    if (opts.gid) {
      var g = document.createElement("span");
      g.className = "vgid";
      g.textContent = opts.gid;
      row.appendChild(g);
    }
    (opts.badges || []).forEach(function (b) {
      var s = document.createElement("span");
      s.className = "lumen-badge " + b.cls;
      s.textContent = b.text;
      row.appendChild(s);
    });
    row.addEventListener("click", opts.onClick);
    return row;
  }

  // DLC / per-component sub-page: each of the game's depots is independently
  // pinnable (SetDlcPin / ClearDlcPin). We can't map depot->DLC appid purely
  // from on-disk data, so depots are labelled by id (a best-effort name lookup
  // could be added later). master-detail: a back arrow returns to the list.
  function renderDlcSubpage(body, game, S, onBack) {
    var GU = S.gu;
    body.textContent = "";
    var back = document.createElement("div");
    back.className = "lumen-back";
    back.innerHTML = "\u2190 ";
    var bt = document.createElement("span");
    bt.textContent = GU.back;
    back.appendChild(bt);
    back.addEventListener("click", onBack);
    body.appendChild(back);

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
      name.textContent = GU.depot + " " + d.depot;
      meta.appendChild(name);
      head.appendChild(meta);
      body.appendChild(head);

      var vers = document.createElement("div");
      vers.className = "lumen-vers";
      var anyPinned = d.versions.some(function (v) { return v.pinned; });

      vers.appendChild(verRow({
        label: GU.latest, selected: !anyPinned,
        onClick: function () {
          call("ClearDlcPin", { json: JSON.stringify({ appid: game.appid, depot: d.depot }) })
            .then(function () { reloadGameUpdates(body, S); })
            .catch(function (e) { log("ClearDlcPin", e); });
        },
      }));

      d.versions.forEach(function (v) {
        var badges = [];
        if (v.installed) badges.push({ cls: "cur", text: GU.current });
        if (v.fromLuaTools) badges.push({ cls: "lt", text: GU.fromLua });
        vers.appendChild(verRow({
          label: fmtDate(v.date), gid: v.gid, selected: v.pinned, badges: badges,
          onClick: function () {
            call("SetDlcPin", { json: JSON.stringify({ appid: game.appid, depot: d.depot, gid: v.gid }) })
              .then(function () { reloadGameUpdates(body, S); })
              .catch(function (e) { log("SetDlcPin", e); });
          },
        }));
      });
      body.appendChild(vers);
    });
  }

  // One game card: capsule + name + appid + a "DLCs" button; clicking the body
  // toggles an inline build timeline. Selecting a build calls SetGamePin (by
  // date); "Latest" calls ClearGamePin.
  function gameCard(game, S) {
    var GU = S.gu;
    var wrap = document.createElement("div");
    wrap.className = "lumen-game";

    var head = document.createElement("div");
    head.className = "lumen-game-head";
    var cap = document.createElement("img");
    cap.className = "lumen-cap";
    cap.src = capsuleUrl(game.appid);
    cap.addEventListener("error", function () { cap.style.visibility = "hidden"; });
    head.appendChild(cap);

    var meta = document.createElement("div");
    meta.className = "lumen-game-meta";
    var name = document.createElement("div");
    name.className = "lumen-game-name";
    var nm = document.createElement("span");
    nm.textContent = "App " + game.appid;
    name.appendChild(nm);
    fetchAppName(game.appid).then(function (n) { if (n) nm.textContent = n; });
    if (game.locked) {
      var lb = document.createElement("span");
      lb.className = "lumen-badge lock";
      lb.textContent = GU.locked;
      name.appendChild(lb);
    }
    var sub = document.createElement("div");
    sub.className = "lumen-game-sub";
    sub.textContent = "" + game.appid;
    meta.appendChild(name); meta.appendChild(sub);
    head.appendChild(meta);

    var dlcBtn = document.createElement("div");
    dlcBtn.className = "lumen-dlcs-btn";
    dlcBtn.textContent = GU.dlcs + " \u203a";
    head.appendChild(dlcBtn);
    wrap.appendChild(head);

    var vers = document.createElement("div");
    vers.className = "lumen-vers";
    vers.style.display = "none";
    var built = false;

    function buildVers() {
      if (built) return; built = true;
      var builds = gameBuilds(game);
      vers.appendChild(verRow({
        label: GU.latest, selected: !game.locked,
        onClick: function () {
          call("ClearGamePin", { json: JSON.stringify({ appid: game.appid }) })
            .then(function () { reloadGameUpdates(vers.__bodyRef, S); })
            .catch(function (e) { log("ClearGamePin", e); });
        },
      }));
      builds.forEach(function (b) {
        var badges = [];
        if (b.installed) badges.push({ cls: "cur", text: GU.current });
        if (b.fromLua) badges.push({ cls: "lt", text: GU.fromLua });
        vers.appendChild(verRow({
          label: fmtDate(b.date), selected: game.locked && b.pinned, badges: badges,
          onClick: function () {
            call("SetGamePin", { json: JSON.stringify({ appid: game.appid, date: b.date }) })
              .then(function () { reloadGameUpdates(vers.__bodyRef, S); })
              .catch(function (e) { log("SetGamePin", e); });
          },
        }));
      });
    }

    head.addEventListener("click", function (e) {
      if (e.target === dlcBtn) {
        renderDlcSubpage(vers.__bodyRef, game, S, function () { reloadGameUpdates(vers.__bodyRef, S); });
        return;
      }
      buildVers();
      vers.style.display = (vers.style.display === "none") ? "flex" : "none";
    });
    wrap.appendChild(vers);
    wrap.__versRef = vers;
    return wrap;
  }

  // Re-fetch + re-render the whole Game Updates list into `body`.
  function reloadGameUpdates(body, S) { renderGameUpdates(body, S); }

  function renderGameUpdates(body, S) {
    var GU = S.gu;
    body.textContent = "";
    var note = document.createElement("div");
    note.className = "lumen-note";
    note.textContent = GU.note;
    body.appendChild(note);

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
        var games = data.games || [];
        listWrap.textContent = "";
        if (games.length === 0) {
          var empty = document.createElement("div");
          empty.className = "lumen-empty";
          empty.textContent = GU.none;
          listWrap.appendChild(empty);
          return;
        }
        var cards = games.map(function (g) {
          var card = gameCard(g, S);
          card.__versRef.__bodyRef = body;
          card.__appid = g.appid;
          listWrap.appendChild(card);
          return card;
        });
        search.addEventListener("input", function () {
          var q = search.value.trim().toLowerCase();
          cards.forEach(function (c) {
            var nameEl = c.querySelector(".lumen-game-name");
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

  function openOverlay() {
    if (document.getElementById(OVERLAY_ID)) return;
    injectStyles();
    var S0 = I18N[pickLang()] || I18N.en;

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

    function mkTab(label, svg) {
      var t = document.createElement("div");
      t.className = "lumen-tab";
      var i = document.createElement("span");
      i.className = "ico";
      i.innerHTML = svg;
      var l = document.createElement("span");
      l.textContent = label;
      t.appendChild(i); t.appendChild(l);
      side.appendChild(t);
      return t;
    }
    var tabSls = mkTab("slsteam-moon", MOON_SVG);
    var tabGu = mkTab(S0.gu.tab, GU_SVG);

    // content
    var content = document.createElement("div");
    content.className = "lumen-content";
    var ctop = document.createElement("div");
    ctop.className = "lumen-ctop";
    var h = document.createElement("div");
    h.className = "h";
    var x = document.createElement("div");
    x.className = "x";
    x.textContent = "\u2715";
    x.addEventListener("click", requestClose);

    // Reset-to-defaults button: header-right (slsteam-moon tab only). Two-click
    // confirm so it can't fire by accident; on success the backend returns fresh
    // {schema,values} and we re-render the tab in place.
    var resetBtn = document.createElement("div");
    resetBtn.className = "reset";
    resetBtn.textContent = S0.reset || "Reset to defaults";
    var armed = false, armTimer = null;
    var disarm = function () {
      armed = false;
      if (armTimer) { clearTimeout(armTimer); armTimer = null; }
      resetBtn.classList.remove("confirm");
      resetBtn.textContent = S0.reset || "Reset to defaults";
    };
    resetBtn.addEventListener("click", function () {
      if (!armed) {
        armed = true;
        resetBtn.classList.add("confirm");
        resetBtn.textContent = S0.resetConfirm || "Click again to confirm";
        armTimer = setTimeout(disarm, 3000);
        return;
      }
      disarm();
      call("ResetSlsConfig", {})
        .then(function (res) {
          var cfg = JSON.parse(res);
          if (!cfg || !cfg.success) throw new Error((cfg && cfg.error) || "reset failed");
          renderConfig(body, cfg);
        })
        .catch(function (e) {
          body.textContent = "";
          var err = document.createElement("div");
          err.className = "lumen-err";
          err.textContent = (S0.resetFail || "Reset failed: ") + (e && e.message ? e.message : e);
          body.appendChild(err);
        });
    });

    ctop.appendChild(h); ctop.appendChild(resetBtn); ctop.appendChild(x);

    var body = document.createElement("div");
    body.className = "lumen-body";

    content.appendChild(ctop);
    content.appendChild(body);
    win.appendChild(side);
    win.appendChild(content);
    overlay.appendChild(win);
    (document.body || document.documentElement).appendChild(overlay);

    function loadSlsConfig() {
      body.textContent = "Loading\u2026";
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
    }

    // Tab switching: update active state, header title, reset-button visibility,
    // then render the tab's body.
    function selectTab(which) {
      disarm();
      tabSls.classList.toggle("active", which === "sls");
      tabGu.classList.toggle("active", which === "gu");
      if (which === "gu") {
        h.textContent = S0.gu.title;
        resetBtn.style.display = "none";
        renderGameUpdates(body, S0);
      } else {
        h.textContent = "slsteam-moon";
        resetBtn.style.display = "";
        loadSlsConfig();
      }
    }
    tabSls.addEventListener("click", function () { selectTab("sls"); });
    tabGu.addEventListener("click", function () { selectTab("gu"); });
    selectTab("sls");

    var onKey = function (e) {
      if (e.key === "Escape") { requestClose(); }
    };
    _escHandler = onKey;
    document.addEventListener("keydown", onKey, true);
  }

  // Exposed so the sidecar (injector State:broadcast_overlay) can open/close the
  // overlay. The injector decides WHICH context renders it: the active store/
  // community web view if one is on top, otherwise the shell window (where the
  // library/home content itself lives). So this just opens locally on request;
  // the shell is told to open only when no web view is covering its content.
  window.__lumenOpenOverlay = openOverlay;
  window.__lumenCloseOverlay = closeOverlay;

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
      // Broadcast so the overlay opens in whichever view is on top (store /
      // community web views composite above this menubar window).
      requestOpen();
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

  // Only anchor the menubar button in the main client shell. This script is
  // ALSO injected into the store/community web views (so the overlay can render
  // on top of them), but those have no Steam menubar — and their own page nav
  // can contain text matching our labels, which made findMenubar() inject a
  // stray moon button into the page header (the "gap" bug). In a web view we
  // only need the overlay globals, already exposed above; skip the button.
  var __lumenHost = (typeof location !== "undefined" && location.hostname) || "";
  if (__lumenHost === "store.steampowered.com" || __lumenHost === "steamcommunity.com") {
    log("web view (" + __lumenHost + "): overlay-only, no menubar button");
  } else {
    tryAnchor();
  }
  log("loaded");
})();
