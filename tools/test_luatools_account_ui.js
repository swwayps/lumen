const fs = require("fs");

const overlay = fs.readFileSync("lua/menu/09-overlay.js", "utf8");
const account = fs.existsSync("lua/menu/09-luatools-account.js")
  ? fs.readFileSync("lua/menu/09-luatools-account.js", "utf8") : "";
const styles = fs.readFileSync("lua/menu/03-styles.js", "utf8");
const boot = fs.readFileSync("lua/boot.lua", "utf8");
let failures = 0;
function check(name, condition) {
  if (condition) console.log("ok   " + name);
  else { console.log("FAIL " + name); failures++; }
}

check("U1 lua.tools account fragment is assembled before the overlay",
  /"09-luatools-account\.js",\s*"09-overlay\.js"/.test(boot));
check("U2 Fixes is an always-visible plugin tab",
  overlay.includes('mkTab(luaToolsStrings().fixesTab, LUA_TOOLS_FIXES_SVG)')
    && overlay.includes("window.__lumenNoPlugin"));
check("U3 account surface is placed after a flexible sidebar spacer",
  overlay.includes('className = "lumen-side-spacer"')
    && overlay.includes('className = "lumen-account-entry checking"'));
check("U4 account view has a top back control",
  overlay.includes('className = "lumen-account-back"')
    && overlay.includes("selectTab(accountPreviousTab)"));
check("U5 logged-out Fixes gate contains only the requested message",
  account.includes('textContent = "Needs lua.tools login"')
    && account.includes('className = "lumen-fixes-login-gate"'));
check("U6 Discord OAuth and bot code are peer login choices",
  account.includes('className = "lumen-account-login-grid"')
    && account.includes('setAttribute("data-method", "discord")')
    && account.includes('setAttribute("data-method", "code")'));
check("U7 connected account uses one Discord-retention switch",
  account.includes('lumen.luaTools.clearDiscordAfterLogin')
    && account.includes('function luaToolsBuildConnectedAccount(status, options)')
    && account.includes('keepSignedIn: !clearPreference()')
    && !account.includes('var clearButton = luaToolsButton(S.clearDiscord, false)'));
check("U8 UI uses the dedicated auth and catalogue RPCs",
  account.includes('call("StartLuaToolsDiscordLogin"')
    && account.includes('call("LoginLuaToolsWithCode"')
    && account.includes('call("GetLuaToolsFixesCatalogue"')
    && account.includes('call("LogoutLuaTools"'));
check("U23 sign-in offers only the two Discord paths",
  !account.includes('call("AdoptLuaToolsSessionValue"')
    && !account.includes("lumen-account-advanced")
    && !/cookiePlaceholder|cookieButton|cookieSafety|advancedBody/.test(account)
    && !styles.includes(".lumen-account-advanced")
    && !styles.includes(".lumen-account-cleanup"));
check("U24 the two sign-in methods are peer cards, Discord owning the loud action",
  styles.includes(".lumen-account-login-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;")
    && styles.includes(".lumen-account-button.discord{background:#5865f2;")
    && account.includes('discordButton.className += " discord"')
    // one filled call to action per screen: the code path is the quiet fallback
    && !/luaToolsButton\(S\.(discordButton|codeButton), true\)/.test(account));
check("U25 the Discord-cleanup preference is a switch row, never a checkbox",
  account.includes('setting.className = "lumen-account-security"')
    && account.includes('toggle.className = "lumen-sw lumen-account-retention-switch"')
    && account.includes("lumen.luaTools.clearDiscordAfterLogin")
    && styles.includes(".lumen-account-connected+.lumen-account-security{border-top:"));
check("U28 the lua.tools mark is embedded locally, not fetched",
  /var LUA_TOOLS_LOGO = "data:image\/png;base64,/.test(account)
    && account.includes("function luaToolsLogoImage(className)")
    && !account.includes("https://status.lua.tools"));
check("U29 the sidebar mark yields to the profile glyph on hover",
  overlay.includes('luaToolsLogoImage("lumen-account-avatar-brand")')
    && overlay.includes('glyph.className = "lumen-account-avatar-glyph"')
    && styles.includes(".lumen-account-entry:hover .lumen-account-avatar-brand{opacity:0;}")
    && styles.includes(".lumen-account-entry:hover .lumen-account-avatar-glyph{opacity:1;}"));
// The mark is itself a round badge, so it is the avatar circle rather than a
// picture sitting inside one: no inset, or it reads as a shrunken logo in a ring.
check("U37 the sidebar mark fills the avatar circle",
  /lumen-account-avatar-brand\{position:absolute;inset:0;width:100%;height:100%;/.test(styles)
    && !/lumen-account-avatar-brand\{[^}]*padding:/.test(styles));
check("U30 the account tab title carries the mark before its text",
  overlay.includes('accountTitle.className = "lumen-account-title"')
    && overlay.includes('luaToolsLogoImage("lumen-account-title-mark")')
    && styles.includes(".lumen-account-title{display:inline-flex;align-items:center;"));
check("U31 the sidebar copy is short enough to render whole",
  account.includes('unlock: "Unlock Fixes and Luie"')
    && !/quality-of-life/.test(account)
    && styles.includes("-webkit-line-clamp:3;"));
check("U32 the Discord mark is centred against its label",
  account.includes('discordButtonIcon.className = "lumen-account-button-icon"')
    && styles.includes(".lumen-account-button-icon{display:inline-flex;align-items:center;")
    && styles.includes(".lumen-account-button svg{display:block;"));
check("U33 the cleanup switch belongs to the Discord card it applies to",
  account.includes("discord.appendChild(preference.node)")
    && account.includes('row.className = "lumen-account-method-option"')
    && !account.includes("panel.appendChild(preference.node)")
    && styles.includes(".lumen-account-method-option{"));
check("U36 neither method card is flagged as the recommended one",
  !/discordFlag|method-flag|recommended:/.test(account)
    && !styles.includes(".lumen-account-method-flag"));
// The two actions must line up across the cards. Bottom-anchoring them cannot do
// it — the Discord card carries a cleanup row below its button — so both sit
// directly under a copy block held to the same height instead.
check("U38 the two sign-in actions line up, top and bottom",
  !/lumen-account-code-row\{[^}]*margin-top:auto/.test(styles)
    && !/lumen-account-login-grid>section>button\{[^}]*margin-top:auto/.test(styles)
    && /lumen-account-login-grid p\{[^}]*min-height:/.test(styles)
    && /lumen-account-code-row\{[^}]*height:34px/.test(styles)
    && /lumen-account-button\{[^}]*min-height:34px/.test(styles));
check("U35 the code card ends at its action, with no footer or dividing rule",
  !/method-note|codeSafety/.test(account)
    && !styles.includes(".lumen-account-method-note")
    && styles.includes(".lumen-account-code-row input{min-width:0;flex:1;")
    && styles.includes(".lumen-account-login-grid>section>button{align-self:stretch;}"));
check("U34 a sign-in handoff runs the OAuth progress animation",
  account.includes("function luaToolsHandoff(section)")
    && account.includes('track.className = "lumen-account-oauth"')
    && styles.includes("@keyframes lumen-oauth-sweep")
    && styles.includes(".lumen-account-login-grid>section.handoff{"));
check("U26 account, catalogue and fix cards share one surface",
  styles.includes(".lumen-account-card{box-sizing:border-box;overflow:hidden;border:1px solid #414955;")
    && styles.includes("border-radius:8px;background:#20242b;}")
    && styles.includes("border:1px solid #414955;border-radius:8px;background:#20242b;color:#dcdedf;")
    && styles.includes(".lumen-fixes-fix-card{padding:17px 18px;border:1px solid #414955;border-radius:8px;background:#20242b;}")
    && !styles.includes("background:#191b20")
    && !styles.includes("background:#181a1f"));
check("U27 signing out announces itself on hover",
  styles.includes(".lumen-account-logout:hover{border-color:#a2464b;"));
check("U9 account styles include keyboard focus and scoped scrollbars",
  styles.includes(".lumen-account-entry:focus-visible")
    && styles.includes('"#" + OVERLAY_ID + " ::-webkit-scrollbar{'));

check("U10 signed-in Fixes catalogue drills into every official fix",
  account.includes('call("GetLuaToolsFixesForGame"')
    && account.includes('className = "lumen-fixes-detail-tags"')
    && account.includes('className = "lumen-fixes-fix-card"'));
check("U11 each usable fix has Apply/Reapply and completes the shared receipt",
  account.includes('call("StartLuaToolsFix"')
    && account.includes('call("CompleteLuaToolsFixApply"')
    && account.includes('S.reapply')
    && account.includes('className = "lumen-fixes-applied"'));
check("U12 Fixes sidebar icon matches the solid 16px tab icon family",
  account.includes('LUA_TOOLS_FIXES_SVG = \'<svg viewBox="0 0 16 16" width="16" height="16"')
    && account.includes('fill="currentColor" transform="rotate(45 8 8)"')
    && !/stroke/.test((/LUA_TOOLS_FIXES_SVG = ([\s\S]*?);\n/.exec(account) || ["", "stroke"])[1])
    && styles.includes('.lumen-tab .ico svg{display:block;width:16px;height:16px}'));
check("U13 Fixes catalogue has category chips and a three-column game grid",
  account.includes('className = "lumen-fixes-tags"')
    && account.includes('className = "lumen-fixes-tag"')
    && account.includes('game.tags')
    && styles.includes('.lumen-fixes-list{display:grid;grid-template-columns:repeat(3,minmax(0,1fr))'));
check("U14 game cards use uncropped Steam headers above their copy",
  account.includes('className = "lumen-fixes-game-meta-icon"')
    && styles.includes('aspect-ratio:460/215')
    && styles.includes('object-fit:cover')
    && styles.includes('.lumen-fixes-game-copy{display:flex;min-width:0;flex:1;flex-direction:column'));
check("U15 internal Fixes cards mirror the website release hierarchy",
  account.includes('className = "lumen-fixes-fix-date"')
    && account.includes('className = "lumen-fixes-fix-tags"')
    && !account.includes('className = "lumen-fixes-fix-description"')
    && styles.includes('.lumen-fixes-fix-card{')
    && styles.includes('.lumen-fixes-fix-card-top{'));
check("U16 game cards use the Lumen-blue hover border",
  styles.includes('.lumen-fixes-game:hover{border-color:#1a9fff'));
check("U17 account footer shares the sidebar surface and its hover/active values",
  styles.includes('border-top:1px solid rgba(255,255,255,.07);background:transparent;')
    && styles.includes('.lumen-account-entry:hover{background:rgba(255,255,255,.04);}')
    && styles.includes('.lumen-account-entry.active{background:#3d4450;}')
    && styles.includes('.lumen-account-entry strong{color:#f1f3f5'));
check("U19 connected footer states its status with the shared green dot",
  styles.includes('.lumen-account-entry.connected small{display:flex;align-items:center;gap:6px;')
    && styles.includes('.lumen-account-entry.connected small:before{')
    && styles.includes('background:#79c754;}'));
check("U20 tag chips derive readable ink/fill from arbitrary API colours",
  account.includes("function luaToolsTagPalette(color)")
    && account.includes("function luaToolsPaintTagChip(node, color, active)")
    && account.includes("luaToolsPaintTagChip(badge, tag.color, false)")
    && !account.includes('chip.style.backgroundColor = activeTag === key ? color : (color + "18")')
    && styles.includes('.lumen-fixes-tag.active{background:#1a9fff;border-color:#1a9fff;color:#fff;}'));
check("U21 chip rows wrap instead of clipping the last chip",
  styles.includes('.lumen-fixes-tags{display:flex;align-items:center;flex-wrap:wrap;gap:7px;')
    && styles.includes('.lumen-fixes-detail-tags{display:flex;align-items:center;flex-wrap:wrap;gap:7px;')
    && !styles.includes('.lumen-fixes-tags{display:flex;align-items:center;gap:7px;overflow-x:auto;'));
check("U22 an unavailable fix action drops the accent fill",
  styles.includes('.lumen-fixes-fix-actions .lumen-account-button.primary:disabled{background:#2f3742;'));
check("U18 internal Apply/Reapply uses Lumen blue",
  styles.includes('.lumen-fixes-fix-actions .lumen-account-button.primary{background:#1a9fff;border-color:#1a9fff')
    && styles.includes('.lumen-fixes-fix-actions .lumen-account-button.primary:hover{background:#3cb0ff;border-color:#3cb0ff')
    && !styles.includes('.lumen-fixes-fix-description{'));

process.exitCode = failures ? 1 : 0;
