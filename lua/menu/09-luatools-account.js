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

  function luaToolsStrings() {
    var pt = pickLang() === "pt-BR";
    return pt ? {
      fixesTab: "Fixes", accountTitle: "Conta lua.tools", signIn: "Entrar no lua.tools",
      unlock: "Desbloqueie fixes, Luie e outros recursos úteis.", connected: "Conectado",
      accountIntro: "Escolha como conectar sua conta. As duas opções criam a mesma sessão segura do lua.tools.",
      discordTitle: "Continuar com Discord", discordBody: "Abra a autorização oficial dentro do navegador do Steam.",
      discordButton: "Entrar com Discord", codeTitle: "Usar código do Discord",
      codeBody: "Execute /login no Discord do LuaTools e digite o código de 6 caracteres.",
      codePlaceholder: "ABC123", codeButton: "Entrar com código", waiting: "Aguardando autorização do Discord…",
      signingIn: "Entrando…", invalidCode: "Digite o código de 6 caracteres.",
      clearAfter: "Limpar o Discord do Steam depois do login pelo Discord", clearAfterHint: "Recomendado. Isso desconecta o Discord somente do navegador interno do Steam; sua sessão lua.tools continua ativa. O login por código não mexe no Discord do Steam.",
      security: "Discord no Steam",
      keepDiscordHint: "Mantém o Discord conectado no navegador interno do Steam. Ative esta opção somente se necessário.",
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
      unlock: "Unlock fixes, Luie, and other quality-of-life features.", connected: "Connected",
      accountIntro: "Choose how to connect your account. Both options create the same secure lua.tools session.",
      discordTitle: "Continue with Discord", discordBody: "Open the official authorization inside Steam's browser.",
      discordButton: "Sign in with Discord", codeTitle: "Use a Discord code",
      codeBody: "Run /login in the LuaTools Discord and enter the six-character code.",
      codePlaceholder: "ABC123", codeButton: "Sign in with code", waiting: "Waiting for Discord authorization…",
      signingIn: "Signing in…", invalidCode: "Enter the six-character code.",
      clearAfter: "Clear Discord from Steam after Discord sign-in", clearAfterHint: "Recommended. This signs Discord out only inside Steam's browser; your lua.tools session stays connected. Code sign-in never touches Steam's Discord session.",
      security: "Discord in Steam",
      keepDiscordHint: "Keeps Discord signed in to Steam's internal browser. Enable this only when necessary.",
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

    var setting = document.createElement("section"); setting.className = "lumen-account-security";
    var settingCopy = document.createElement("span"); settingCopy.className = "lumen-account-security-copy";
    var settingTitle = document.createElement("strong"); settingTitle.textContent = S.security;
    var settingHint = document.createElement("small"); settingHint.textContent = S.keepDiscordHint;
    settingCopy.appendChild(settingTitle); settingCopy.appendChild(settingHint);
    var toggle = document.createElement("label"); toggle.className = "lumen-sw lumen-account-retention-switch";
    var input = document.createElement("input"); input.type = "checkbox";
    input.checked = !!options.keepSignedIn; input.setAttribute("aria-label", S.security);
    var slider = document.createElement("span"); slider.className = "sl";
    toggle.appendChild(input); toggle.appendChild(slider);

    var statusNode = document.createElement("div");
    statusNode.className = "lumen-account-status"; statusNode.setAttribute("aria-live", "polite");
    input.addEventListener("change", function () {
      if (typeof options.onKeepChange === "function") options.onKeepChange(input.checked, input, statusNode);
    });
    logout.addEventListener("click", function () {
      if (typeof options.onLogout === "function") options.onLogout(logout, statusNode);
    });

    profile.appendChild(avatar); profile.appendChild(identity); profile.appendChild(logout);
    setting.appendChild(settingCopy); setting.appendChild(toggle);
    root.appendChild(profile); root.appendChild(setting); root.appendChild(statusNode);
    return { node: root, retentionInput: input, statusNode: statusNode, logout: logout };
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

  function renderLuaToolsFixes(panel, cachedState) {
    var S = luaToolsStrings();
    if (!(cachedState && cachedState.payload)) panel.textContent = "Loading…";
    return luaToolsLoadFixesCatalogue(cachedState, function () {
      return call("GetLuaToolsFixesCatalogue", {}).then(luaToolsParse);
    }).then(function (viewState) {
      var payload = viewState.payload;
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

    // The Discord-cleanup preference, as the same settings row the connected card
    // uses for it. It was a bare checkbox floating under the method cards, so one
    // preference had two different controls depending on whether you were signed in.
    function preferenceRow() {
      var card = document.createElement("div"); card.className = "lumen-account-card";
      var row = document.createElement("section"); row.className = "lumen-account-security";
      var copy = document.createElement("span"); copy.className = "lumen-account-security-copy";
      var strong = document.createElement("strong"); strong.textContent = S.clearAfter;
      var small = document.createElement("small"); small.textContent = S.clearAfterHint;
      copy.appendChild(strong); copy.appendChild(small);
      var toggle = document.createElement("label");
      toggle.className = "lumen-sw lumen-account-retention-switch";
      var input = document.createElement("input"); input.type = "checkbox"; input.checked = clearPreference();
      input.setAttribute("aria-label", S.clearAfter);
      var slider = document.createElement("span"); slider.className = "sl";
      toggle.appendChild(input); toggle.appendChild(slider);
      row.appendChild(copy); row.appendChild(toggle); card.appendChild(row);
      input.addEventListener("change", function () { saveClearPreference(input.checked); });
      return { node: card, input: input };
    }

    function renderSignedOut() {
      var intro = document.createElement("p"); intro.className = "lumen-account-intro"; intro.textContent = S.accountIntro;
      var grid = document.createElement("div"); grid.className = "lumen-account-login-grid";
      var discord = document.createElement("section"); discord.setAttribute("data-method", "discord");
      var discordIcon = document.createElement("span"); discordIcon.className = "lumen-account-method-icon"; discordIcon.innerHTML = LUA_TOOLS_DISCORD_SVG;
      var discordTitle = document.createElement("h3"); discordTitle.textContent = S.discordTitle;
      var discordBody = document.createElement("p"); discordBody.textContent = S.discordBody;
      // Brand-filled, with the Discord mark on it: the recommended path should be
      // the one obvious button, not a twin of the code fallback's blue.
      var discordButton = luaToolsButton("", false);
      discordButton.className += " discord";
      var discordButtonIcon = document.createElement("span");
      discordButtonIcon.innerHTML = LUA_TOOLS_DISCORD_SVG;
      var discordButtonLabel = document.createElement("span");
      discordButtonLabel.textContent = S.discordButton;
      discordButton.appendChild(discordButtonIcon);
      discordButton.appendChild(discordButtonLabel);
      discord.appendChild(discordIcon); discord.appendChild(discordTitle);
      discord.appendChild(discordBody); discord.appendChild(discordButton);

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
      code.appendChild(codeIcon); code.appendChild(codeTitle); code.appendChild(codeBody); code.appendChild(codeRow);
      grid.appendChild(discord); grid.appendChild(code);
      var preference = preferenceRow();
      var statusNode = document.createElement("div"); statusNode.className = "lumen-account-status"; statusNode.setAttribute("aria-live", "polite");
      // No third "paste a session cookie" path: lua.tools issues its session
      // through Discord, so hand-pasted cookies were a dead end that only made
      // the screen look like it had a hidden expert mode. The backend RPC
      // (AdoptLuaToolsSessionValue) is untouched if it's ever needed again.
      panel.appendChild(intro); panel.appendChild(grid);
      panel.appendChild(preference.node); panel.appendChild(statusNode);

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
        codeButton.disabled = true; statusNode.textContent = S.signingIn; statusNode.className = "lumen-account-status";
        call("LoginLuaToolsWithCode", { code: codeInput.value, contentScriptQuery: "" }).then(luaToolsParse).then(function (result) {
          if (!(result && result.success && result.configured)) throw new Error((result && result.error) || "sign-in failed");
          return finishLogin(false);
        }).catch(function (error) {
          codeButton.disabled = false; statusNode.textContent = error && error.message ? error.message : String(error);
          statusNode.className = "lumen-account-status error";
        });
      }
      codeButton.addEventListener("click", submitCode);
      codeInput.addEventListener("keydown", function (event) { if (event.key === "Enter") submitCode(); });

      discordButton.addEventListener("click", function () {
        discordButton.disabled = true; statusNode.textContent = S.signingIn; statusNode.className = "lumen-account-status";
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
              discordButton.disabled = false; statusNode.textContent = error && error.message ? error.message : String(error);
              statusNode.className = "lumen-account-status error";
            });
          }
          setTimeout(poll, 700);
        }).catch(function (error) {
          call("CancelLuaToolsDiscordLogin", {}).catch(function () {});
          discordButton.disabled = false; statusNode.textContent = error && error.message ? error.message : String(error);
          statusNode.className = "lumen-account-status error";
        });
      });

    }

    function renderConnected(status) {
      var view = luaToolsBuildConnectedAccount(status, {
        keepSignedIn: !clearPreference(),
        onKeepChange: function (keepSignedIn, input, statusNode) {
          saveClearPreference(!keepSignedIn);
          if (keepSignedIn) {
            statusNode.textContent = ""; statusNode.className = "lumen-account-status";
            return;
          }
          input.disabled = true;
          luaToolsClearDiscord(statusNode).then(function () { input.disabled = false; });
        },
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
