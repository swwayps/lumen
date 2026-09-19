// LM-FRAGMENT lua.tools account view + authenticated Fixes catalogue
// Assembled into the shared settings-menu IIFE immediately before 09-overlay.js.

  // Sidebar "Fixes" glyph. The other tab icons (MOON_SVG, GU_SVG, CLOUD_SVG,
  // ABOUT_SVG) are solid shapes drawn on a 16-unit grid, so this one is too: a
  // 24-unit 2px-stroke outline icon rendered next to them at 16px came out
  // thinner, busier and read as a diagonal smudge rather than a wrench. Drawn
  // upright (jaws up, handle down) and rotated 45deg into the usual pose.
  var LUA_TOOLS_FIXES_SVG = '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'
    + '<g fill="currentColor" transform="rotate(45 8 8)">'
    + '<path d="M5 1h1.75v3.9h2.5V1H11v4.6a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1z"/>'
    + '<path d="M6.9 5.6h2.2v7.7a1.1 1.1 0 0 1-2.2 0z"/>'
    + '</g></svg>';
  var LUA_TOOLS_USER_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21a8 8 0 0 0-16 0"/><circle cx="12" cy="7" r="4"/></svg>';
  var LUA_TOOLS_DISCORD_SVG = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M19.5 5.3A16.3 16.3 0 0 0 15.4 4l-.5 1.1a15 15 0 0 0-5.8 0L8.6 4a16.4 16.4 0 0 0-4.1 1.3C1.9 9.2 1.2 13 1.5 16.8A16.5 16.5 0 0 0 6.6 19l1.2-1.7a10.4 10.4 0 0 1-1.9-.9l.5-.4c3.7 1.7 7.7 1.7 11.3 0l.5.4c-.6.4-1.2.7-1.9.9l1.2 1.7a16.4 16.4 0 0 0 5.1-2.2c.4-4.4-.8-8.2-3.1-11.5ZM8.7 14.5c-1.1 0-2-1-2-2.3s.9-2.3 2-2.3 2 1 2 2.3-.9 2.3-2 2.3Zm6.6 0c-1.1 0-2-1-2-2.3s.9-2.3 2-2.3 2 1 2 2.3-.9 2.3-2 2.3Z"/></svg>';
  var LUA_TOOLS_CODE_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m8 10-2 2 2 2m8-4 2 2-2 2m-5 1 2-6"/></svg>';
  var LUA_TOOLS_BACK_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 18-6-6 6-6"/></svg>';
  var LUA_TOOLS_CUBE_SVG = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m21 16-9 5-9-5V8l9-5 9 5z"/><path d="m3.3 7 8.7 5 8.7-5M12 22V12"/></svg>';
  var LUA_TOOLS_CALENDAR_SVG = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 10h18"/></svg>';
  // lua.tools brand mark, embedded as a data URI. The menu bundle is injected
  // over CDP with no static file server behind it, so the bytes travel with the
  // script; pointing at the remote copy would make the settings window fetch a
  // third-party asset every time it opens. Source: status.lua.tools
  // /upload/logo1.png, 128x128 PNG, sha256 26056dbc170a35922f0ebce931421fd37fa78c8f3b835c4cbe783619b296ecd8.
  var LUA_TOOLS_LOGO = "data:image/png;base64,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";

  // The mark as an <img>. Decorative everywhere it is used (the text beside it
  // already names the account), so it carries an empty alt and is hidden from
  // assistive tech rather than announced twice.
  function luaToolsLogoImage(className) {
    var image = document.createElement("img");
    image.src = LUA_TOOLS_LOGO;
    image.alt = "";
    image.setAttribute("aria-hidden", "true");
    if (className) image.className = className;
    return image;
  }

  function luaToolsStrings() {
    var pt = pickLang() === "pt-BR";
    return pt ? {
      fixesTab: "Fixes", accountTitle: "Conta lua.tools", signIn: "Entrar no lua.tools",
      unlock: "Desbloqueie Fixes e Luie", connected: "Conectado",
      checking: "Verificando sua conta\u2026",
      accountIntro: "Escolha como conectar sua conta. As duas opções criam a mesma sessão segura do lua.tools.",
      discordTitle: "Continuar com Discord", discordBody: "Abra a autorização oficial dentro do navegador do Steam.",
      discordButton: "Entrar com Discord", codeTitle: "Usar código do Discord",
      codeBody: "Execute /login no Discord do LuaTools e digite o código de 6 caracteres.",
      codePlaceholder: "ABC123", codeButton: "Entrar com código", waiting: "Aguardando autorização do Discord…",
      signingIn: "Entrando…", invalidCode: "Digite o código de 6 caracteres.",
      clearAfter: "Limpar o Discord do Steam depois", clearAfterHint: "Desconecta o Discord apenas do navegador do Steam. Sua sessão lua.tools continua ativa.",
      clearingDiscord: "Atualizando…", cleared: "Discord desconectado do navegador do Steam.",
      clearFailed: "Não foi possível limpar o Discord. Feche as páginas do Discord no Steam e tente novamente.",
      logout: "Sair do lua.tools",
      fixesSearch: "Buscar jogo ou AppID", fixesEmpty: "Nenhum fix encontrado.", all: "Todos",
      previous: "Anterior", next: "Próxima", fixesCount: "fixes", back: "Voltar",
      apply: "Aplicar", reapply: "Reaplicar", applied: "Aplicado", applyingFix: "Aplicando…",
      downloadingFix: "Baixando {percent}%", extractingFix: "Extraindo…",
      applyDone: "Fix aplicado com sucesso.", applyFailed: "Não foi possível aplicar o fix.",
      needsPreparation: "Precisa do preparo do DenuvOwO", needsProton: "Requer Proton",
      notInstalled: "Jogo não instalado", manifest: "Manifest", archive: "Arquivos do fix",
    } : {
      fixesTab: "Fixes", accountTitle: "lua.tools account", signIn: "Sign in to lua.tools",
      unlock: "Unlock Fixes and Luie", connected: "Connected",
      checking: "Checking your account\u2026",
      accountIntro: "Choose how to connect your account. Both options create the same secure lua.tools session.",
      discordTitle: "Continue with Discord", discordBody: "Open the official authorization inside Steam's browser.",
      discordButton: "Sign in with Discord", codeTitle: "Use a Discord code",
      codeBody: "Run /login in the LuaTools Discord and enter the six-character code.",
      codePlaceholder: "ABC123", codeButton: "Sign in with code", waiting: "Waiting for Discord authorization…",
      signingIn: "Signing in…", invalidCode: "Enter the six-character code.",
      clearAfter: "Clear Discord from Steam afterwards", clearAfterHint: "Signs Discord out of Steam's browser only. Your lua.tools session stays connected.",
      clearingDiscord: "Updating…", cleared: "Discord signed out from Steam's browser.",
      clearFailed: "Discord could not be cleared. Close Discord pages in Steam and try again.",
      logout: "Sign out of lua.tools",
      fixesSearch: "Search game or AppID", fixesEmpty: "No fixes found.", all: "All",
      previous: "Previous", next: "Next", fixesCount: "fixes", back: "Back",
      apply: "Apply", reapply: "Reapply", applied: "Applied", applyingFix: "Applying…",
      downloadingFix: "Downloading {percent}%", extractingFix: "Extracting…",
      applyDone: "Fix applied successfully.", applyFailed: "The fix could not be applied.",
      needsPreparation: "Needs DenuvOwO preparation", needsProton: "Requires Proton",
      notInstalled: "Game is not installed", manifest: "Manifest", archive: "Fix files",
    };
  }

  function luaToolsParse(response) {
    try { return typeof response === "string" ? JSON.parse(response) : response; }
    catch (e) { return null; }
  }

  function luaToolsSafeAvatar(url) {
    url = String(url || "");
    return /^https:\/\/(cdn\.discordapp\.com|media\.discordapp\.net)\//i.test(url) ? url : "";
  }

  function luaToolsFixSlug(value) {
    return String(value || "").trim().toLowerCase()
      .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  }

  function luaToolsNormalizeFixTag(value) {
    var object = value && typeof value === "object" ? value : null;
    var label = String(object ? (object.name || object.slug || "") : (value || "")).trim();
    var key = luaToolsFixSlug(object ? (object.slug || object.name || "") : value);
    var rawColor = String(object && object.color || "").trim();
    var color = /^#[0-9a-f]{6}$/i.test(rawColor) ? rawColor : "";
    return { label: label || key, key: key, color: color };
  }

  function luaToolsFixTagKey(value) {
    return luaToolsNormalizeFixTag(value).key;
  }

  // ── tag chip palette ───────────────────────────────────────────────────────
  // Tag colours arrive verbatim from the lua.tools API, so a tag can be any hex:
  // dark brand blues (#0b6ee8) were unreadable as chip text on Lumen's near-black
  // surface, and bright hues (#edc72d) were unreadable under the white text the
  // selected chip used. Both chip states derive their colours from the raw hex
  // instead of painting with it directly, so any tag stays legible.
  var LUA_TOOLS_CHIP_SURFACE = [32, 36, 43]; // #20242b, the chip's resting fill
  var LUA_TOOLS_CHIP_INK_MIN = 0.3;          // relative luminance floor for text

  function luaToolsHexToRgb(hex) {
    var match = /^#([0-9a-f]{6})$/i.exec(String(hex || "").trim());
    if (!match) return null;
    var value = parseInt(match[1], 16);
    return [(value >> 16) & 255, (value >> 8) & 255, value & 255];
  }

  function luaToolsRgbToHex(rgb) {
    return "#" + rgb.map(function (channel) {
      var text = Math.max(0, Math.min(255, Math.round(channel))).toString(16);
      return text.length === 1 ? "0" + text : text;
    }).join("");
  }

  function luaToolsMixRgb(rgb, target, amount) {
    return rgb.map(function (channel, index) {
      return channel + (target[index] - channel) * amount;
    });
  }

  // WCAG relative luminance — the same measure the contrast ratio is built on.
  function luaToolsLuminance(rgb) {
    var linear = rgb.map(function (channel) {
      var part = channel / 255;
      return part <= 0.03928 ? part / 12.92 : Math.pow((part + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
  }

  function luaToolsTagPalette(color) {
    var rgb = luaToolsHexToRgb(color);
    if (!rgb) return null;
    var ink = rgb;
    for (var step = 0; step < 6 && luaToolsLuminance(ink) < LUA_TOOLS_CHIP_INK_MIN; step++) {
      ink = luaToolsMixRgb(ink, [255, 255, 255], 0.25);
    }
    return {
      ink: luaToolsRgbToHex(ink),
      border: luaToolsRgbToHex(luaToolsMixRgb(rgb, LUA_TOOLS_CHIP_SURFACE, 0.42)),
      fill: luaToolsRgbToHex(luaToolsMixRgb(rgb, LUA_TOOLS_CHIP_SURFACE, 0.86)),
      activeFill: luaToolsRgbToHex(rgb),
      activeInk: luaToolsLuminance(rgb) > 0.34 ? "#10131a" : "#ffffff",
    };
  }

  // Paint one chip/badge from a tag colour. Returns false for tags the API sent
  // without a colour, which keeps the per-tag CSS fallbacks in charge.
  function luaToolsPaintTagChip(node, color, active) {
    var palette = luaToolsTagPalette(color);
    if (!palette) return false;
    node.style.borderColor = active ? palette.activeFill : palette.border;
    node.style.backgroundColor = active ? palette.activeFill : palette.fill;
    node.style.color = active ? palette.activeInk : palette.ink;
    return true;
  }

  function luaToolsFixDisplayTitle(value) {
    value = String(value || "").trim();
    if (!value) return "Fix";
    return /^\d+$/.test(value) ? ("Build " + value) : value;
  }

  function luaToolsFormatFixDate(value, language) {
    var date = new Date(String(value || ""));
    if (!value || isNaN(date.getTime())) return "";
    try {
      return new Intl.DateTimeFormat(language === "pt-BR" ? "pt-BR" : "en-GB", {
        day: "numeric", month: "short", year: "numeric", timeZone: "UTC",
      }).format(date);
    } catch (e) { return ""; }
  }

  function luaToolsFilterFixGames(games, query, activeTag) {
    if (!Array.isArray(games)) return [];
    query = String(query || "").trim().toLowerCase();
    activeTag = luaToolsFixTagKey(activeTag);
    return games.filter(function (game) {
      game = game || {};
      var matchesQuery = !query
        || String(game.name || "").toLowerCase().indexOf(query) !== -1
        || String(game.appid || "").indexOf(query) !== -1;
      var matchesTag = !activeTag || (Array.isArray(game.tags) && game.tags.some(function (tag) {
        return luaToolsFixTagKey(tag) === activeTag;
      }));
      return matchesQuery && matchesTag;
    });
  }

  function luaToolsIsSelectableFixTag(value) {
    var key = luaToolsFixTagKey(value);
    return key !== "steamtools-achievements-fix"
      && key !== "steamtools-achievement-fix";
  }

  function luaToolsLoadFixesCatalogue(state, loader) {
    state = state || {};
    var next = {
      payload: state.payload || null,
      query: String(state.query || ""),
      activeTag: String(state.activeTag || ""),
      page: Math.max(0, Number(state.page) || 0),
    };
    if (next.payload) return Promise.resolve(next);
    return Promise.resolve().then(loader).then(function (payload) {
      next.payload = payload;
      return next;
    });
  }

  try {
    window.__lumenLuaToolsFilterFixGames = luaToolsFilterFixGames;
    window.__lumenLuaToolsNormalizeFixTag = luaToolsNormalizeFixTag;
    window.__lumenLuaToolsFixDisplayTitle = luaToolsFixDisplayTitle;
    window.__lumenLuaToolsFormatFixDate = luaToolsFormatFixDate;
    window.__lumenLuaToolsIsSelectableFixTag = luaToolsIsSelectableFixTag;
    window.__lumenLuaToolsTagPalette = luaToolsTagPalette;
    window.__lumenLuaToolsLuminance = luaToolsLuminance;
  } catch (e) {}

  function luaToolsButton(label, primary) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "lumen-account-button" + (primary ? " primary" : "");
    button.textContent = label;
    return button;
  }

  // Both sign-in paths hand off to Discord — one to an authorization window, one
  // to a code the bot has to redeem — and neither reports progress. The status
  // line said "Waiting…" and nothing else moved, which read as a dead screen. Fit
  // the card with the indeterminate sweep OAuth handoffs use, so the wait is
  // visibly live and belongs to the card you actually pressed.
  function luaToolsHandoff(section) {
    var track = document.createElement("div");
    track.className = "lumen-account-oauth";
    track.setAttribute("aria-hidden", "true");
    track.appendChild(document.createElement("span"));
    section.appendChild(track);
    return function (active) {
      section.classList.toggle("handoff", !!active);
      track.classList.toggle("on", !!active);
    };
  }

  function luaToolsFixesBackButton(label, onBack) {
    var back = luaToolsButton("\u2190 " + label, false);
    back.className += " lumen-fixes-detail-back";
    back.addEventListener("click", function () {
      if (typeof onBack === "function") onBack();
    });
    return back;
  }

  function luaToolsBuildConnectedAccount(status, options) {
    var S = luaToolsStrings();
    options = options || {};

    var root = document.createElement("div");
    root.className = "lumen-account-card lumen-account-connected-view";
    var profile = document.createElement("div"); profile.className = "lumen-account-connected";
    var avatar = document.createElement("span"); avatar.className = "lumen-account-connected-avatar";
    var avatarUrl = luaToolsSafeAvatar(status && status.account && status.account.avatarUrl);
    if (avatarUrl) {
      var img = document.createElement("img"); img.src = avatarUrl; img.alt = ""; avatar.appendChild(img);
    } else avatar.innerHTML = LUA_TOOLS_USER_SVG;
    var identity = document.createElement("span"); identity.className = "lumen-account-connected-identity";
    var name = document.createElement("strong");
    name.textContent = (status && status.account && status.account.displayName) || "lua.tools";
    var state = document.createElement("small"); state.textContent = S.connected;
    identity.appendChild(name); identity.appendChild(state);
    var logout = luaToolsButton(S.logout, false); logout.className += " lumen-account-logout";

    // Nothing to configure once connected: the Discord-cleanup preference belongs
    // to the sign-in choice that uses it and has already run by the time this card
    // exists. Re-offering it here made the screen look like a settings page for a
    // decision that was over.
    var statusNode = document.createElement("div");
    statusNode.className = "lumen-account-status"; statusNode.setAttribute("aria-live", "polite");
    logout.addEventListener("click", function () {
      if (typeof options.onLogout === "function") options.onLogout(logout, statusNode);
    });

    profile.appendChild(avatar); profile.appendChild(identity); profile.appendChild(logout);
    root.appendChild(profile); root.appendChild(statusNode);
    return { node: root, statusNode: statusNode, logout: logout };
  }

  function luaToolsTagsForFix(fix) {
    var result = [], seen = {};
    (Array.isArray(fix && fix.tags) ? fix.tags : []).forEach(function (value) {
      var tag = luaToolsNormalizeFixTag(value);
      if (!tag.key || seen[tag.key]) return;
      seen[tag.key] = true; result.push(tag);
    });
    if (!result.length && fix && fix.category) {
      var fallback = luaToolsNormalizeFixTag({
        name: fixesCategoryLabel(fix.category), slug: String(fix.category).replace(/_/g, "-"),
      });
      if (fallback.key) result.push(fallback);
    }
    return result;
  }

  function luaToolsFixTagBadge(tag) {
    var badge = document.createElement("span");
    badge.className = "lumen-fixes-fix-tag";
    badge.textContent = tag.label;
    badge.setAttribute("data-tag", tag.key);
    luaToolsPaintTagChip(badge, tag.color, false);
    return badge;
  }

  function luaToolsCompleteFix(appid, fix, context) {
    return call("GetFixLaunchOptions", {
      appid: Number(appid), compatToolName: "", currentLaunchOptions: "",
      installPath: context.installPath || "", contentScriptQuery: "",
    }).then(luaToolsParse).then(function (options) {
      if (!(options && options.success)) throw new Error("launch options unavailable");
      if (!(options.apply && options.launchOptions)) return true;
      return call("__lumenSetLaunchOptions", {
        appid: Number(appid), options: String(options.launchOptions),
      }).then(luaToolsParse).then(function (result) {
        if (!(result && result.ok)) throw new Error("launch options were not saved");
        return true;
      });
    }).then(function () {
      return call("CompleteLuaToolsFixApply", {
        appid: Number(appid), fixId: fix.id, contentScriptQuery: "",
      }).then(luaToolsParse);
    });
  }

  function luaToolsApplyDetailedFix(appid, fix, context, button, status, onDone) {
    var S = luaToolsStrings();
    button.disabled = true; button.textContent = S.applyingFix;
    status.className = "lumen-fixes-fix-status"; status.textContent = S.applyingFix;
    call("StartLuaToolsFix", {
      appid: Number(appid), fixId: fix.id, gameName: context.gameName || "",
      installPath: context.installPath || "", contentScriptQuery: "",
    }).then(luaToolsParse).then(function (started) {
      if (!(started && started.success)) throw new Error((started && started.error) || S.applyFailed);
      var poll = function () {
        call("GetApplyFixStatus", { appid: Number(appid), contentScriptQuery: "" })
          .then(luaToolsParse).then(function (payload) {
            var state = payload && payload.state;
            if (!(payload && payload.success && state)) { setTimeout(poll, 650); return; }
            if (state.status === "downloading") {
              var percent = state.totalBytes > 0
                ? Math.floor((state.bytesRead / state.totalBytes) * 100) : 0;
              status.textContent = S.downloadingFix.replace("{percent}", percent);
              setTimeout(poll, 650); return;
            }
            if (state.status === "extracting") {
              status.textContent = S.extractingFix; setTimeout(poll, 650); return;
            }
            if (state.status === "done") {
              luaToolsCompleteFix(appid, fix, context).then(function (completed) {
                if (!(completed && completed.success)) {
                  throw new Error((completed && completed.error) || S.applyFailed);
                }
                status.className = "lumen-fixes-fix-status success";
                status.textContent = S.applyDone;
                if (typeof onDone === "function") onDone();
              }).catch(fail);
              return;
            }
            if (state.status === "failed" || state.status === "cancelled") {
              throw new Error(state.error || S.applyFailed);
            }
            setTimeout(poll, 650);
          }).catch(fail);
      };
      setTimeout(poll, 450);
    }).catch(fail);

    function fail(error) {
      button.disabled = false;
      button.textContent = fix.applied ? S.reapply : S.apply;
      status.className = "lumen-fixes-fix-status error";
      status.textContent = error && error.message ? error.message : S.applyFailed;
    }
  }

  function renderLuaToolsFixGame(panel, summary, onBack) {
    var S = luaToolsStrings(), appid = Number(summary.appid);
    panel.textContent = "Loading…";
    Promise.all([
      call("GetLuaToolsFixesForGame", { appid: appid }).then(luaToolsParse),
      call("LumenFixesContext", { appid: appid }).then(luaToolsParse),
    ]).then(function (values) {
      var game = values[0], context = values[1] || {};
      if (!(game && game.success && Array.isArray(game.fixes))) {
        throw new Error((game && game.error) || "fixes unavailable");
      }
      panel.textContent = "";
      var header = document.createElement("div"); header.className = "lumen-fixes-detail-head";
      var back = luaToolsFixesBackButton(S.back, onBack);
      var heading = document.createElement("span");
      var title = document.createElement("strong"); title.textContent = game.name || summary.name || ("App " + appid);
      var app = document.createElement("small"); app.textContent = "App " + appid;
      heading.appendChild(title); heading.appendChild(app); header.appendChild(back); header.appendChild(heading);
      panel.appendChild(header);

      if (!game.fixes.length) {
        var empty = document.createElement("div"); empty.className = "lumen-fixes-empty";
        empty.textContent = S.fixesEmpty; panel.appendChild(empty); return;
      }
      var detailTags = document.createElement("div"); detailTags.className = "lumen-fixes-detail-tags";
      var cards = document.createElement("div"); cards.className = "lumen-fixes-fix-cards";
      panel.appendChild(detailTags); panel.appendChild(cards);

      var activeDetailTag = "", allDetailTags = [], seenDetailTags = {};
      game.fixes.forEach(function (fix) {
        luaToolsTagsForFix(fix).forEach(function (tag) {
          if (!luaToolsIsSelectableFixTag(tag) || seenDetailTags[tag.key]) return;
          seenDetailTags[tag.key] = true; allDetailTags.push(tag);
        });
      });

      function drawDetailTags() {
        detailTags.textContent = "";
        function addTag(label, key, color) {
          var chip = document.createElement("button"); chip.type = "button";
          chip.className = "lumen-fixes-tag" + (activeDetailTag === key ? " active" : "");
          chip.textContent = label; chip.setAttribute("data-tag", key || "all");
          chip.setAttribute("aria-pressed", activeDetailTag === key ? "true" : "false");
          luaToolsPaintTagChip(chip, color, activeDetailTag === key);
          chip.addEventListener("click", function () {
            activeDetailTag = key; drawDetailTags(); drawFixCards();
          });
          detailTags.appendChild(chip);
        }
        addTag(S.all, "", "");
        allDetailTags.forEach(function (tag) { addTag(tag.label, tag.key, tag.color); });
      }

      function drawFixCards() {
        cards.textContent = "";
        var visible = game.fixes.filter(function (fix) {
          return !activeDetailTag || luaToolsTagsForFix(fix).some(function (tag) {
            return tag.key === activeDetailTag;
          });
        });
        if (!visible.length) {
          var empty = document.createElement("div"); empty.className = "lumen-fixes-empty";
          empty.textContent = S.fixesEmpty; cards.appendChild(empty); return;
        }
        visible.forEach(function (fix) {
          var card = document.createElement("article");
          card.className = "lumen-fixes-fix-card" + (fix.applied ? " applied" : "");
          var top = document.createElement("div"); top.className = "lumen-fixes-fix-card-top";
          var information = document.createElement("div"); information.className = "lumen-fixes-fix-information";
          var name = document.createElement("strong"); name.className = "lumen-fixes-fix-title";
          name.textContent = luaToolsFixDisplayTitle(fix.title);
          information.appendChild(name);

          var formattedDate = luaToolsFormatFixDate(fix.createdAt, pickLang());
          if (formattedDate) {
            var date = document.createElement("span"); date.className = "lumen-fixes-fix-date";
            var calendar = document.createElement("span"); calendar.innerHTML = LUA_TOOLS_CALENDAR_SVG;
            var dateText = document.createElement("span"); dateText.textContent = formattedDate;
            date.appendChild(calendar); date.appendChild(dateText); information.appendChild(date);
          }

          var tagRow = document.createElement("div"); tagRow.className = "lumen-fixes-fix-tags";
          luaToolsTagsForFix(fix).forEach(function (tag) { tagRow.appendChild(luaToolsFixTagBadge(tag)); });
          information.appendChild(tagRow);

          var actions = document.createElement("div"); actions.className = "lumen-fixes-fix-actions";
          if (fix.applied) {
            var applied = document.createElement("span"); applied.className = "lumen-fixes-applied";
            applied.textContent = "\u2713 " + S.applied; actions.appendChild(applied);
          }
          var apply = luaToolsButton(fix.applied ? S.reapply : S.apply, true);
          var status = document.createElement("small"); status.className = "lumen-fixes-fix-status";
          var blocked = "";
          if (!context.isInstalled) blocked = S.notInstalled;
          else if (fix.requiresPreparation) blocked = S.needsPreparation;
          else if (fix.hasFix && !context.runsUnderProton) blocked = S.needsProton;
          if (blocked) { apply.disabled = true; apply.title = blocked; status.textContent = blocked; }
          apply.addEventListener("click", function () {
            luaToolsApplyDetailedFix(appid, fix, context, apply, status, function () {
              setTimeout(function () { renderLuaToolsFixGame(panel, summary, onBack); }, 450);
            });
          });
          actions.appendChild(apply); actions.appendChild(status);
          top.appendChild(information); top.appendChild(actions); card.appendChild(top);

          cards.appendChild(card);
        });
      }

      drawDetailTags(); drawFixCards();
    }).catch(function (error) {
      panel.textContent = "";
      var back = luaToolsFixesBackButton(S.back, onBack);
      var node = document.createElement("div"); node.className = "lumen-err";
      node.textContent = "Could not load lua.tools Fixes: " + (error && error.message ? error.message : error);
      panel.appendChild(back); panel.appendChild(node);
    });
  }

  function luaToolsClearDiscord(statusNode) {
    var S = luaToolsStrings();
    if (statusNode) { statusNode.textContent = S.clearingDiscord; statusNode.className = "lumen-account-status"; }
    return call("__lumenClearDiscordSession", {}).then(luaToolsParse).then(function (result) {
      if (!(result && result.ok)) throw new Error("cleanup failed");
      if (statusNode) { statusNode.textContent = S.cleared; statusNode.className = "lumen-account-status success"; }
      return result;
    }).catch(function () {
      if (statusNode) {
        statusNode.textContent = S.clearFailed;
        statusNode.className = "lumen-account-status error";
      }
    });
  }

  // The fixes catalogue is a network fetch (GetLuaToolsFixesCatalogue). Cached at
  // module scope so it is fetched once per session: reopening the settings window
  // renders it instantly instead of re-loading every time. invalidateFixes()
  // (auth change) clears it so a login/logout refetches.
  var _luaToolsFixesPayloadCache = null;
  function invalidateLuaToolsFixesCache() { _luaToolsFixesPayloadCache = null; }

  function renderLuaToolsFixes(panel, cachedState) {
    var S = luaToolsStrings();
    // An explicit cachedState (in-session detail back-navigation) wins; otherwise
    // fall back to the session cache so a fresh window open pays no network cost.
    if (!(cachedState && cachedState.payload) && _luaToolsFixesPayloadCache) {
      cachedState = { payload: _luaToolsFixesPayloadCache };
    }
    if (!(cachedState && cachedState.payload)) panel.textContent = "Loading…";
    return luaToolsLoadFixesCatalogue(cachedState, function () {
      return call("GetLuaToolsFixesCatalogue", {}).then(luaToolsParse);
    }).then(function (viewState) {
      var payload = viewState.payload;
      // Cache a good, authorized catalogue. authRequired payloads carry no games
      // and are left uncached so a later login refetches.
      if (payload && payload.success && Array.isArray(payload.games)) {
        _luaToolsFixesPayloadCache = payload;
      }
      panel.textContent = "";
      if (payload && payload.authRequired) {
        var gate = document.createElement("div");
        gate.className = "lumen-fixes-login-gate";
        gate.textContent = "Needs lua.tools login";
        panel.appendChild(gate);
        return payload;
      }
      if (!(payload && payload.success && Array.isArray(payload.games))) {
        throw new Error((payload && payload.error) || "catalogue unavailable");
      }

      var search = document.createElement("input");
      search.type = "search";
      search.className = "lumen-fixes-search";
      search.placeholder = S.fixesSearch;
      search.setAttribute("aria-label", S.fixesSearch);
      var tags = document.createElement("div");
      tags.className = "lumen-fixes-tags";
      var list = document.createElement("div");
      list.className = "lumen-fixes-list";
      var pager = document.createElement("div");
      pager.className = "lumen-fixes-pager";
      panel.appendChild(tags); panel.appendChild(search); panel.appendChild(list); panel.appendChild(pager);

      var page = viewState.page, pageSize = 12, activeTag = viewState.activeTag;
      search.value = viewState.query;
      var catalogueTags = [], seenTags = {};
      function rememberTag(value) {
        var tag = luaToolsNormalizeFixTag(value);
        if (!tag.label || !tag.key || !luaToolsIsSelectableFixTag(tag) || seenTags[tag.key]) return;
        seenTags[tag.key] = true; catalogueTags.push(tag);
      }
      if (Array.isArray(payload.tags)) payload.tags.forEach(rememberTag);
      payload.games.forEach(function (game) {
        if (Array.isArray(game.tags)) game.tags.forEach(rememberTag);
      });
      function filtered() {
        return luaToolsFilterFixGames(payload.games, search.value, activeTag);
      }
      function drawTags() {
        tags.textContent = "";
        function addTag(label, key, color) {
          var chip = document.createElement("button");
          chip.type = "button";
          chip.className = "lumen-fixes-tag" + (activeTag === key ? " active" : "");
          chip.textContent = label;
          chip.setAttribute("data-tag", key || "all");
          chip.setAttribute("aria-pressed", activeTag === key ? "true" : "false");
          luaToolsPaintTagChip(chip, color, activeTag === key);
          chip.addEventListener("click", function () {
            activeTag = key; page = 0; drawTags(); draw();
          });
          tags.appendChild(chip);
        }
        addTag(S.all, "");
        catalogueTags.forEach(function (tag) { addTag(tag.label, tag.key, tag.color); });
      }
      function draw() {
        var games = filtered();
        var pages = Math.max(1, Math.ceil(games.length / pageSize));
        page = Math.max(0, Math.min(page, pages - 1));
        list.textContent = ""; pager.textContent = "";
        if (!games.length) {
          pager.style.display = "none";
          var empty = document.createElement("div");
          empty.className = "lumen-fixes-empty"; empty.textContent = S.fixesEmpty;
          list.appendChild(empty); return;
        }
        games.slice(page * pageSize, page * pageSize + pageSize).forEach(function (game) {
          var row = document.createElement("button");
          row.type = "button"; row.className = "lumen-fixes-game";
          var image = document.createElement("img");
          image.alt = ""; image.loading = "lazy";
          image.src = game.headerImage || ("https://cdn.cloudflare.steamstatic.com/steam/apps/" + game.appid + "/header.jpg");
          var copy = document.createElement("span"); copy.className = "lumen-fixes-game-copy";
          var name = document.createElement("strong"); name.textContent = game.name || ("App " + game.appid);
          var meta = document.createElement("small"); meta.className = "lumen-fixes-game-meta";
          var metaIcon = document.createElement("span"); metaIcon.className = "lumen-fixes-game-meta-icon";
          metaIcon.innerHTML = LUA_TOOLS_CUBE_SVG;
          var metaText = document.createElement("span");
          metaText.textContent = Number(game.fixCount || 0) + " " + S.fixesCount;
          meta.appendChild(metaIcon); meta.appendChild(metaText);
          copy.appendChild(name); copy.appendChild(meta); row.appendChild(image); row.appendChild(copy);
          row.addEventListener("click", function () {
            var returnState = {
              payload: payload,
              query: search.value,
              activeTag: activeTag,
              page: page,
            };
            renderLuaToolsFixGame(panel, game, function () {
              renderLuaToolsFixes(panel, returnState);
            });
          });
          list.appendChild(row);
        });
        pager.style.display = pages > 1 ? "flex" : "none";
        var prev = luaToolsButton(S.previous, false), next = luaToolsButton(S.next, false);
        var count = document.createElement("span"); count.textContent = (page + 1) + " / " + pages;
        prev.disabled = page === 0; next.disabled = page >= pages - 1;
        prev.addEventListener("click", function () { page--; draw(); });
        next.addEventListener("click", function () { page++; draw(); });
        pager.appendChild(prev); pager.appendChild(count); pager.appendChild(next);
      }
      search.addEventListener("input", function () { page = 0; draw(); });
      drawTags(); draw();
      return payload;
    }).catch(function (error) {
      panel.textContent = "";
      var node = document.createElement("div"); node.className = "lumen-err";
      node.textContent = "Could not load lua.tools Fixes: " + (error && error.message ? error.message : error);
      panel.appendChild(node);
    });
  }

  function renderLuaToolsAccount(panel, hooks) {
    hooks = hooks || {};
    var S = luaToolsStrings();
    panel.textContent = "Loading…";

    function notify(status) {
      if (typeof hooks.onStatus === "function") hooks.onStatus(status);
    }
    function refresh() {
      return call("GetLuaToolsAuthStatus", {}).then(luaToolsParse).then(function (status) {
        if (!(status && status.success)) throw new Error((status && status.error) || "status unavailable");
        notify(status); panel.textContent = "";
        if (status.configured) renderConnected(status); else renderSignedOut();
        return status;
      }).catch(function (error) {
        panel.textContent = "";
        var node = document.createElement("div"); node.className = "lumen-err";
        node.textContent = "Could not load lua.tools account: " + (error && error.message ? error.message : error);
        panel.appendChild(node);
      });
    }
    function authChanged() {
      if (typeof hooks.onAuthChanged === "function") hooks.onAuthChanged();
      return refresh();
    }
    function clearPreference() {
      try { return localStorage.getItem("lumen.luaTools.clearDiscordAfterLogin") !== "0"; }
      catch (e) { return true; }
    }
    function saveClearPreference(value) {
      try { localStorage.setItem("lumen.luaTools.clearDiscordAfterLogin", value ? "1" : "0"); }
      catch (e) {}
    }

    // The Discord-cleanup preference. It governs the Discord path alone (code
    // sign-in never touches Steam's Discord session), so it belongs INSIDE the
    // Discord card. As its own settings card under the grid it read as a third,
    // global option and made the two method cards look like a subsection of it.
    // The whole row is the label, so the copy is a hit target too.
    function preferenceRow() {
      var row = document.createElement("label"); row.className = "lumen-account-method-option";
      var copy = document.createElement("span");
      var strong = document.createElement("strong"); strong.textContent = S.clearAfter;
      var small = document.createElement("small"); small.textContent = S.clearAfterHint;
      copy.appendChild(strong); copy.appendChild(small);
      // A <span>, not the usual <label>: nesting a label inside this row's label
      // is invalid, and the outer one already forwards clicks to the input.
      var toggle = document.createElement("span");
      toggle.className = "lumen-sw lumen-account-retention-switch";
      var input = document.createElement("input"); input.type = "checkbox"; input.checked = clearPreference();
      input.setAttribute("aria-label", S.clearAfter);
      var slider = document.createElement("span"); slider.className = "sl";
      toggle.appendChild(input); toggle.appendChild(slider);
      row.appendChild(copy); row.appendChild(toggle);
      input.addEventListener("change", function () { saveClearPreference(input.checked); });
      return { node: row, input: input };
    }

    function renderSignedOut() {
      var intro = document.createElement("p"); intro.className = "lumen-account-intro"; intro.textContent = S.accountIntro;
      var grid = document.createElement("div"); grid.className = "lumen-account-login-grid";
      var discord = document.createElement("section"); discord.setAttribute("data-method", "discord");
      var discordIcon = document.createElement("span"); discordIcon.className = "lumen-account-method-icon"; discordIcon.innerHTML = LUA_TOOLS_DISCORD_SVG;
      var discordTitle = document.createElement("h3"); discordTitle.textContent = S.discordTitle;
      var discordBody = document.createElement("p"); discordBody.textContent = S.discordBody;
      // Brand-filled, with the Discord mark on it, so this path is not a twin of
      // the code fallback's blue.
      var discordButton = luaToolsButton("", false);
      discordButton.className += " discord";
      var discordButtonIcon = document.createElement("span");
      // The mark sat on the label's baseline because a bare inline <span> gives an
      // svg nothing to centre against, so it rode low next to the text.
      discordButtonIcon.className = "lumen-account-button-icon";
      discordButtonIcon.innerHTML = LUA_TOOLS_DISCORD_SVG;
      var discordButtonLabel = document.createElement("span");
      discordButtonLabel.textContent = S.discordButton;
      discordButton.appendChild(discordButtonIcon);
      discordButton.appendChild(discordButtonLabel);
      var preference = preferenceRow();
      discord.appendChild(discordIcon); discord.appendChild(discordTitle);
      discord.appendChild(discordBody); discord.appendChild(discordButton);
      discord.appendChild(preference.node);

      var code = document.createElement("section"); code.setAttribute("data-method", "code");
      var codeIcon = document.createElement("span"); codeIcon.className = "lumen-account-method-icon code"; codeIcon.innerHTML = LUA_TOOLS_CODE_SVG;
      var codeTitle = document.createElement("h3"); codeTitle.textContent = S.codeTitle;
      var codeBody = document.createElement("p"); codeBody.textContent = S.codeBody;
      var codeRow = document.createElement("div"); codeRow.className = "lumen-account-code-row";
      var codeInput = document.createElement("input"); codeInput.type = "text"; codeInput.maxLength = 6;
      codeInput.autocomplete = "one-time-code"; codeInput.placeholder = S.codePlaceholder;
      codeInput.setAttribute("aria-label", S.codeTitle);
      var codeButton = luaToolsButton(S.codeButton, false);
      codeRow.appendChild(codeInput); codeRow.appendChild(codeButton);
      code.appendChild(codeIcon); code.appendChild(codeTitle); code.appendChild(codeBody);
      code.appendChild(codeRow);
      grid.appendChild(discord); grid.appendChild(code);
      var discordHandoff = luaToolsHandoff(discord);
      var codeHandoff = luaToolsHandoff(code);
      var statusNode = document.createElement("div"); statusNode.className = "lumen-account-status"; statusNode.setAttribute("aria-live", "polite");
      // No third "paste a session cookie" path: lua.tools issues its session
      // through Discord, so hand-pasted cookies were a dead end that only made
      // the screen look like it had a hidden expert mode. The backend RPC
      // (AdoptLuaToolsSessionValue) is untouched if it's ever needed again.
      panel.appendChild(intro); panel.appendChild(grid); panel.appendChild(statusNode);

      codeInput.addEventListener("input", function () {
        codeInput.value = codeInput.value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
      });
      function finishLogin(usedDiscord) {
        var cleanup = usedDiscord && preference.input.checked ? luaToolsClearDiscord() : Promise.resolve();
        return Promise.resolve(cleanup).then(authChanged);
      }
      function submitCode() {
        if (!/^[A-Z0-9]{6}$/.test(codeInput.value)) {
          statusNode.textContent = S.invalidCode; statusNode.className = "lumen-account-status error"; codeInput.focus(); return;
        }
        codeButton.disabled = true; codeHandoff(true);
        statusNode.textContent = S.signingIn; statusNode.className = "lumen-account-status";
        call("LoginLuaToolsWithCode", { code: codeInput.value, contentScriptQuery: "" }).then(luaToolsParse).then(function (result) {
          if (!(result && result.success && result.configured)) throw new Error((result && result.error) || "sign-in failed");
          return finishLogin(false);
        }).catch(function (error) {
          codeButton.disabled = false; codeHandoff(false);
          statusNode.textContent = error && error.message ? error.message : String(error);
          statusNode.className = "lumen-account-status error";
        });
      }
      codeButton.addEventListener("click", submitCode);
      codeInput.addEventListener("keydown", function (event) { if (event.key === "Enter") submitCode(); });

      discordButton.addEventListener("click", function () {
        discordButton.disabled = true; discordHandoff(true);
        statusNode.textContent = S.signingIn; statusNode.className = "lumen-account-status";
        call("StartLuaToolsDiscordLogin", {}).then(luaToolsParse).then(function (started) {
          if (!(started && started.status === "waiting" && started.authUrl)) throw new Error((started && started.error) || "sign-in unavailable");
          return call("__lumenLuaToolsLoginOpen", { url: started.authUrl }).then(luaToolsParse);
        }).then(function (opened) {
          if (!(opened && opened.ok)) throw new Error("Steam could not open the Discord authorization window.");
          statusNode.textContent = S.waiting;
          var began = Date.now();
          function poll() {
            if (!document.getElementById(OVERLAY_ID) || panel.style.display === "none") {
              call("CancelLuaToolsDiscordLogin", {}).catch(function () {});
              call("__lumenLuaToolsLoginClose", {}).catch(function () {});
              return;
            }
            call("PollLuaToolsDiscordLogin", {}).then(luaToolsParse).then(function (state) {
              if (state && state.status === "done" && state.configured) {
                call("__lumenLuaToolsLoginClose", {}).catch(function () {});
                finishLogin(true); return;
              }
              if (state && (state.status === "error" || state.status === "timeout" || state.status === "idle")) {
                throw new Error(state.error || "Discord sign-in did not complete.");
              }
              if (Date.now() - began > 300000) throw new Error("Discord sign-in timed out.");
              setTimeout(poll, 1000);
            }).catch(function (error) {
              call("CancelLuaToolsDiscordLogin", {}).catch(function () {});
              call("__lumenLuaToolsLoginClose", {}).catch(function () {});
              discordButton.disabled = false; discordHandoff(false);
              statusNode.textContent = error && error.message ? error.message : String(error);
              statusNode.className = "lumen-account-status error";
            });
          }
          setTimeout(poll, 700);
        }).catch(function (error) {
          call("CancelLuaToolsDiscordLogin", {}).catch(function () {});
          discordButton.disabled = false; discordHandoff(false);
          statusNode.textContent = error && error.message ? error.message : String(error);
          statusNode.className = "lumen-account-status error";
        });
      });

    }

    function renderConnected(status) {
      var view = luaToolsBuildConnectedAccount(status, {
        onLogout: function (logout, statusNode) {
          logout.disabled = true;
          call("LogoutLuaTools", {}).then(luaToolsParse).then(function (result) {
            if (!(result && result.success)) throw new Error((result && result.error) || "logout failed");
            return authChanged();
          }).catch(function (error) {
            logout.disabled = false; statusNode.textContent = error && error.message ? error.message : String(error);
            statusNode.className = "lumen-account-status error";
          });
        },
      });
      panel.appendChild(view.node);
    }

    return refresh();
  }
