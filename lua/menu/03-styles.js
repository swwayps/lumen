// LM-FRAGMENT injectStyles() - all menu CSS
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.


  // ── styles (match the native Steam Settings window exactly) ────────────────
  // Theme-defined RootColors do not have standardized names. Resolve the
  // palette from both the effective RootColors seed and a bounded sample of
  // the already-themed Steam UI.
  var _lumenPaletteCache = {};
  function applyAdaptivePalette(force) {
    var root = document.documentElement;
    if (!window.__lumenThemeApplied) {
      ["bg","panel","side","raised","text","muted","accent","border"].forEach(function (name) {
        root.style.removeProperty("--lumen-theme-" + name);
      });
      _lumenPaletteCache = {};
      return;
    }
    if (typeof getComputedStyle !== "function") return;
    var rootStyle = getComputedStyle(root);
    var colorProbe = null;

    function parse(value, noProbe) {
      if (!value) return null;
      value = String(value).trim();
      var ref = value.match(/^var\(\s*(--[\w-]+)/);
      if (ref) {
        var resolved = rootStyle.getPropertyValue(ref[1]);
        if (resolved && resolved.trim() !== value) return parse(resolved, noProbe);
      }
      var keywords = { white:[255,255,255,1], black:[0,0,0,1], transparent:[0,0,0,0] };
      if (keywords[value.toLowerCase()]) return keywords[value.toLowerCase()].slice();
      var match = value.match(/^#([0-9a-f]{3,8})$/i);
      var hex, alpha = 1;
      if (match) {
        hex = match[1];
        if (hex.length === 3 || hex.length === 4) {
          hex = hex.split("").map(function (part) { return part + part; }).join("");
        }
        if (hex.length === 8) alpha = parseInt(hex.slice(6, 8), 16) / 255;
        if (hex.length === 6 || hex.length === 8) {
          return [parseInt(hex.slice(0, 2), 16), parseInt(hex.slice(2, 4), 16),
            parseInt(hex.slice(4, 6), 16), alpha];
        }
      }
      match = value.match(/^hsl[a]?\(\s*([0-9.+-]+)(?:deg)?[,\s]+([0-9.]+)%[,\s]+([0-9.]+)%(?:\s*[,/]\s*([0-9.]+)%?)?/i);
      if (match) {
        var h = ((Number(match[1]) % 360) + 360) % 360 / 360;
        var saturation = Number(match[2]) / 100, lightness = Number(match[3]) / 100;
        var hue = function (p, q, t) {
          if (t < 0) t += 1; if (t > 1) t -= 1;
          if (t < 1/6) return p + (q-p)*6*t;
          if (t < 1/2) return q;
          if (t < 2/3) return p + (q-p)*(2/3-t)*6;
          return p;
        };
        var q = lightness < .5 ? lightness*(1+saturation) : lightness+saturation-lightness*saturation;
        var p = 2*lightness-q;
        var hsl = saturation === 0 ? [lightness,lightness,lightness] :
          [hue(p,q,h+1/3),hue(p,q,h),hue(p,q,h-1/3)];
        alpha = match[4] == null ? 1 : Number(match[4]) /
          (value.lastIndexOf("%") > value.lastIndexOf(match[3]) ? 100 : 1);
        return [hsl[0]*255,hsl[1]*255,hsl[2]*255,alpha];
      }
      if (/^(?:rgb[a]?\(|[-+0-9.])/.test(value)) {
        var numbers = value.match(/[-+]?(?:\d*\.)?\d+/g);
        if (numbers && numbers.length >= 3) {
          var firstThree = value.split(/[\/,]/).slice(0, 3).join(",");
          var scale = firstThree.indexOf("%") >= 0 ? 2.55 : 1;
          alpha = numbers[3] == null ? 1 : Number(numbers[3]) /
            (value.slice(value.lastIndexOf(numbers[3])).indexOf("%") >= 0 ? 100 : 1);
          return [Number(numbers[0])*scale,Number(numbers[1])*scale,
            Number(numbers[2])*scale,alpha];
        }
      }
      // Let Chromium normalize modern CSS formats (hwb/lab/oklch/color) only
      // when needed. The same hidden probe is reused for every uncommon value.
      if (!noProbe && root.appendChild && document.createElement) {
        try {
          if (!colorProbe) {
            colorProbe = document.createElement("span");
            colorProbe.style.cssText = "position:absolute;visibility:hidden;pointer-events:none";
            root.appendChild(colorProbe);
          }
          colorProbe.style.color = "";
          colorProbe.style.color = value;
          if (colorProbe.style.color) return parse(getComputedStyle(colorProbe).color, true);
        } catch (e) {}
      }
      return null;
    }

    function mix(a,b,t) { return a.slice(0,3).map(function (x,i) { return Math.round(x+(b[i]-x)*t); }); }
    function rgb(color) { return "rgb(" + color.slice(0,3).map(function (x) {
      return Math.max(0,Math.min(255,Math.round(x)));
    }).join(",") + ")"; }
    function luminance(color) {
      var values=color.slice(0,3).map(function(x){x=x/255;return x<=.04045?x/12.92:Math.pow((x+.055)/1.055,2.4);});
      return .2126*values[0]+.7152*values[1]+.0722*values[2];
    }
    function contrast(a,b) { var x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05); }
    function chroma(color) { return (Math.max(color[0],color[1],color[2])-Math.min(color[0],color[1],color[2]))/255; }
    function distance(a,b) { return Math.sqrt(Math.pow(a[0]-b[0],2)+Math.pow(a[1]-b[1],2)+Math.pow(a[2]-b[2],2)); }
    function opaque(color) { return color && color[3] > .12; }
    function colorKey(color) { return color.slice(0,3).map(function(x){return Math.round(x);}).join(","); }
    function addWeighted(list,color,weight) {
      if (!opaque(color)) return;
      var key=colorKey(color),found=list.filter(function(item){return item.key===key;})[0];
      if (found) found.weight += weight;
      else list.push({key:key,color:color,weight:weight});
    }
    function setPalette(palette) {
      Object.keys(palette).forEach(function(name){root.style.setProperty("--lumen-theme-"+name,palette[name]);});
    }

    var seed=window.__lumenThemePaletteSeed||{};
    var seedColors=Array.isArray(seed.colors)?seed.colors:[];
    var cacheKey=(window.__lumenThemeApplied||"")+":"+(seed.revision||"")+":"+JSON.stringify(seedColors);
    if (document.querySelectorAll) {
      Array.from(document.querySelectorAll('link[data-lumen-theme-asset^="css:"]')).forEach(function(link){
        var ready=false;try{ready=!!link.sheet;}catch(e){}
        if(ready||!link.addEventListener)return;
        link.dataset=link.dataset||{};
        if(link.dataset.lumenPaletteWatch===cacheKey)return;
        link.dataset.lumenPaletteWatch=cacheKey;
        link.addEventListener("load",function(){
          delete _lumenPaletteCache[cacheKey];
          applyAdaptivePalette(true);
        },{once:true});
        link.addEventListener("error",function(){delete _lumenPaletteCache[cacheKey];},{once:true});
      });
    }
    if (!force && _lumenPaletteCache[cacheKey]) {
      setPalette(_lumenPaletteCache[cacheKey]);
      return;
    }
    var entries=[];
    function addEntry(name,value) {
      var color=parse(value);
      if (opaque(color)) entries.push({name:String(name||"").toLowerCase(),color:color});
    }
    seedColors.forEach(function(item){if(item)addEntry(item.name,item.value);});
    [
      ["background",["--st-background","--background-color","--main-background","--theme-background"]],
      ["panel",["--st-color-2","--st-color-1","--panel-background","--modal-background"]],
      ["accent",["--st-accent-1","--SystemAccentColor","--accent-color","--theme-accent"]]
    ].forEach(function(group){group[1].forEach(function(name){var value=rootStyle.getPropertyValue(name);if(value)addEntry(group[0]+" "+name,value);});});

    var backgrounds=[],texts=[];
    if (document.elementsFromPoint) {
      var width=Math.max(1,window.innerWidth||root.clientWidth||1);
      var height=Math.max(1,window.innerHeight||root.clientHeight||1);
      var points=[[8,8],[width*.25,8],[width*.5,8],[width*.75,8],[width-8,8],
        [8,height*.16],[width*.5,height*.16],[width-8,height*.16],
        [8,height*.52],[width*.5,height*.52],[width-8,height*.52],
        [8,height-12],[width*.5,height-12],[width-8,height-12]];
      var styleCache=typeof WeakMap!=="undefined"?new WeakMap():null;
      points.forEach(function(point){
        Array.from(document.elementsFromPoint(point[0],point[1])||[]).slice(0,8)
          .forEach(function(element,depth){
            var marker=((element.id||"")+" "+(typeof element.className==="string"?element.className:"")).toLowerCase();
            if (marker.indexOf("lumen-") >= 0) return;
            var style=styleCache&&styleCache.get(element);
            if (!style) { try { style=getComputedStyle(element); } catch(e) { return; } if(styleCache)styleCache.set(element,style); }
            var weight=1/(depth+1);
            addWeighted(backgrounds,parse(style.backgroundColor),weight);
            addWeighted(texts,parse(style.color),weight*.65);
          });
      });
    }
    if (colorProbe && colorProbe.remove) colorProbe.remove();

    function named(pattern) {
      var best=null,bestScore=-1;
      entries.forEach(function(entry){
        var score=0;
        Object.keys(pattern).forEach(function(token){
          if(entry.name.indexOf(token)>=0) {
            // Exact RootColors names are intentional theme API. A substring
            // remains useful for aliases such as "panel --st-color-2", but
            // must not beat an exact semantic declaration.
            score=Math.max(score,pattern[token]+(entry.name===token?30:0));
          }
        });
        if(score>bestScore){best=entry;bestScore=score;}
      });
      return bestScore>0?best:null;
    }
    backgrounds.sort(function(a,b){return b.weight-a.weight;});
    var baseEntry=named({background:120,backdrop:115,canvas:110,
      "color-darker":108,"color-darkest":100});
    var base=baseEntry&&baseEntry.color||(backgrounds[0]&&backgrounds[0].color);
    if (!base && entries.length) {
      var ordered=entries.map(function(entry){return entry.color;}).sort(function(a,b){return luminance(a)-luminance(b);});
      var darkMode=luminance(ordered[Math.floor(ordered.length/2)])<.5;
      base=ordered[darkMode?Math.max(0,Math.floor(ordered.length*.18)):
        Math.min(ordered.length-1,Math.ceil(ordered.length*.82))];
    }
    if (!base) return;
    var dark=luminance(base)<.5;
    var panelEntry=named({panel:120,surface:115,modal:110,"color-2":100,
      "color-dark":108,"color-light":92});
    var panel=panelEntry&&panelEntry.color;
    function panelScore(candidate,weight) {
      var delta=luminance(candidate)-luminance(base),direction=dark?delta:-delta;
      if(distance(candidate,base)<5||direction<-.015)return -1;
      return (weight||.1)*10-Math.abs(Math.abs(delta)-.035)*4;
    }
    if (!panel) {
      var bestPanel=-1;
      backgrounds.concat(entries.map(function(entry){return {color:entry.color,weight:.08};}))
        .forEach(function(item){var score=panelScore(item.color,item.weight);if(score>bestPanel){bestPanel=score;panel=item.color;}});
    }
    if (!panel) panel=mix(base,dark?[255,255,255]:[0,0,0],.08);

    var textEntry=named({foreground:120,text:115,darkwhite:105,white:100});
    var text=textEntry&&contrast(textEntry.color,panel)>=3?textEntry.color:null;
    if (!text) {
      var bestText=0;
      texts.concat(entries.map(function(entry){return {color:entry.color,weight:.05};}))
        .forEach(function(item){var score=contrast(item.color,panel)+(item.weight||0);if(score>bestText){bestText=score;text=item.color;}});
    }
    if (!text) text=dark?[232,235,238]:[25,28,32];

    var accentEntry=named({accent:140,primary:130,highlight:120,online:110,link:105,blue:100,ingame:90});
    var accent=accentEntry&&accentEntry.color,bestAccent=accent?100:-1;
    if (!accent) entries.forEach(function(entry){
      if(distance(entry.color,base)<12||distance(entry.color,panel)<12||contrast(entry.color,panel)<1.35)return;
      var score=chroma(entry.color)*100+Math.min(contrast(entry.color,panel),4);
      if(score>bestAccent){bestAccent=score;accent=entry.color;}
    });
    if (!accent) backgrounds.concat(texts).forEach(function(item){
      if(chroma(item.color)<.12||distance(item.color,base)<12||distance(item.color,panel)<12||
          distance(item.color,text)<12||contrast(item.color,panel)<1.35)return;
      var score=chroma(item.color)*100+Math.min(contrast(item.color,panel),4)+Math.min(item.weight||0,5);
      if(score>bestAccent){bestAccent=score;accent=item.color;}
    });
    if (!accent) accent=[26,159,255];

    var light=!dark,edge=light?[0,0,0]:[255,255,255];
    var palette={
      bg:rgb(base),panel:rgb(panel),side:rgb(mix(panel,edge,light?.04:.06)),
      raised:rgb(mix(panel,edge,light?.08:.09)),text:rgb(text),
      muted:rgb(mix(text,panel,.42)),accent:rgb(accent),
      border:"rgba("+edge.join(",")+",.14)"
    };
    _lumenPaletteCache[cacheKey]=palette;
    setPalette(palette);
  }

  function injectStyles() {
    if (document.getElementById(STYLE_ID)) return;
    var s = document.createElement("style");
    s.id = STYLE_ID;
    s.textContent = [
      // Gamepad focus ring. Steam's own focus ring is drawn by its React
      // components, so anything Lumen injects has to paint its own — otherwise
      // the D-pad moves an invisible selection. Applies to every Lumen surface
      // (menubar entry, settings window, Fixes Menu, guard modals) via the
      // .active-focus class the gamepad navigation sets.
      // Gamepad UI runs at a device scale factor, and a 2px outline on a small
      // control rounds down to a hairline. Keep the ring readable everywhere.
      ".active-focus{outline:3px solid #66c0f4 !important;outline-offset:2px !important;",
      "border-radius:4px;box-shadow:0 0 0 4px rgba(102,192,244,.20) !important;",
      "position:relative;z-index:2;}",
      // Gamepad focus should read exactly like a pointer hover, so the styles
      // below are written once for both. `.active-focus` is what the gamepad
      // navigation sets; keeping the pairs here avoids duplicating every rule.
      ".lumen-tab.active-focus{background:rgba(255,255,255,.04);}",
      ".lumen-account-entry.active-focus{background:rgba(255,255,255,.04);}",
      ".lumen-account-back.active-focus{color:#fff;background:rgba(255,255,255,.07);}",
      ".lumen-account-button.active-focus{background:#3b4350;color:#fff;}",
      ".lumen-account-button.primary.active-focus{background:#3cb0ff;border-color:#3cb0ff;}",
      ".lumen-account-button.discord.active-focus{background:#6b76f5;border-color:#6b76f5;}",
      ".lumen-account-logout.active-focus{border-color:#a2464b;background:rgba(236,92,92,.1);color:#f0908f;}",
      ".lumen-ctop .x.active-focus,.lumen-ctop .reset.active-focus{color:#fff;background:rgba(255,255,255,.08);}",
      ".lumen-info.active-focus{color:#fff;border-color:#8f98a0;}",
      ".lumen-row select.active-focus,.lumen-row input.active-focus{border-color:#4a5663;}",
      ".lumen-fixes-tag.active-focus{border-color:#657181;color:#fff;}",
      ".lumen-fixes-game.active-focus{border-color:#1a9fff;background:#262b33;}",
      ".lumen-game-head.active-focus{background:rgba(255,255,255,.03);}",
      ".lumen-ver.active-focus{background:rgba(255,255,255,.05);}",
      ".lumen-ver.active-focus .lumen-del{opacity:1;}",
      ".lumen-ver.disabled.active-focus{background:none;}",
      ".lumen-del.active-focus,.lumen-icon-btn.active-focus{color:#ec5c5c;background:rgba(236,92,92,.12);}",
      ".lumen-back.active-focus{color:#fff;}",
      ".lumen-adv.active-focus,.lumen-more.active-focus,.lumen-about-credit a.active-focus{text-decoration:underline;}",
      ".lumen-builder-add.active-focus,.lumen-import.active-focus{color:#8fd0ff;}",
      ".lumen-builder-result.active-focus{background:#303844;}",
      ".lumen-secret-toggle.active-focus{color:#fff;background:#292f38;}",
      ".lumen-channel-option.active-focus{color:var(--lumen-theme-text,#dcdedf);}",
      ".lumen-about-btn.active-focus,.lumen-cloud-btn.active-focus{background:#3cb0ff;border-color:#3cb0ff;}",
      ".lumen-cloud-btn.secondary.active-focus{background:rgba(255,255,255,.08);color:#fff;}",
      "#" + BTN_ID + "{display:inline-flex;align-items:center;justify-content:flex-start;gap:0;",
      "cursor:pointer;font-size:13px;line-height:1;height:22px;padding:0;margin:0 2px;overflow:hidden;",
      "opacity:.8;-webkit-app-region:no-drag;user-select:none;border-radius:999px;white-space:nowrap;",
      "transition:background-color .26s cubic-bezier(.4,0,.2,1),opacity .18s cubic-bezier(.4,0,.2,1);}",
      // The fill starts as a 22px circle right under the moon and grows to the
      // right with the copy, so the pill slides out of the moon (and back into
      // it) instead of popping up beside it. Lumen accent, same as the buttons.
      "#" + BTN_ID + ":hover,#" + BTN_ID + ".lumen-auto-fix-active{opacity:1;",
      "background:var(--lumen-theme-accent,#1a9fff);color:#fff;}",
      "#" + BTN_ID + ":focus-visible{opacity:1;outline:2px solid #66c0f4;outline-offset:1px;}",
      ".lumen-moon-glyph{display:inline-flex;align-items:center;justify-content:center;width:22px;height:22px;flex:0 0 22px;}",
      ".lumen-auto-fix-pill-copy{display:inline-block;max-width:0;margin-left:0;padding:0;overflow:hidden;opacity:0;",
      "transform:translateX(-6px);font-size:11px;font-weight:700;font-variant-numeric:tabular-nums;",
      "transition:max-width .26s cubic-bezier(.4,0,.2,1),margin-left .26s cubic-bezier(.4,0,.2,1),",
      "padding .26s cubic-bezier(.4,0,.2,1),opacity .18s cubic-bezier(.4,0,.2,1),",
      "transform .26s cubic-bezier(.4,0,.2,1);}",
      // Hover opens the pill too: the resting copy ("Lumen", or the update
      // notice) is always in the DOM, so this needs no JS.
      "#" + BTN_ID + ":hover .lumen-auto-fix-pill-copy,",
      "#" + BTN_ID + ".lumen-auto-fix-active .lumen-auto-fix-pill-copy{max-width:180px;margin-left:0;padding:0 9px 0 6px;opacity:1;transform:none;}",
      "@media (prefers-reduced-motion:reduce){.lumen-auto-fix-pill-copy,#" + BTN_ID + "{transition:none!important;}}",
      "#lumen-access-layer{position:fixed!important;inset:0!important;",
      "z-index:2147483645!important;pointer-events:none!important;isolation:isolate!important;",
      "display:block!important;visibility:visible!important;opacity:1!important;",
      "transform:none!important;filter:none!important;contain:none!important;}",
      "#" + BTN_ID + ".lumen-fallback{display:flex!important;visibility:visible!important;",
      "opacity:.9!important;position:absolute!important;top:4px!important;left:4px!important;right:auto!important;",
      "width:32px!important;height:32px!important;padding:0!important;margin:0!important;",
      "z-index:1!important;pointer-events:auto!important;",
      "background:var(--lumen-theme-panel,rgba(28,31,37,.98))!important;color:#b8bcbf!important;",
      "border:1px solid var(--lumen-theme-border,rgba(255,255,255,.14))!important;",
      "border-radius:4px!important;box-shadow:0 1px 4px rgba(0,0,0,.38)!important;",
      "font-size:13px!important;box-sizing:border-box!important;transform:none!important;filter:none!important;}",
      "#" + BTN_ID + ".lumen-fallback:hover{opacity:1!important;",
      "background:rgba(62,68,78,.96)!important;}",
      "#" + BTN_ID + ".lumen-fallback svg{display:block!important;width:16px!important;",
      "height:16px!important;margin:auto!important;}",
      "#" + BTN_ID + ".lumen-fallback.lumen-fallback-slot{position:absolute!important;",
      "top:4px!important;left:4px!important;right:auto!important;}",
      "#" + OVERLAY_ID + "{position:fixed;inset:0;z-index:2147483646!important;display:flex;",
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
      ".lumen-tab .ico svg{display:block;width:16px;height:16px}",
      ".lumen-side-spacer{flex:1 1 auto;min-height:18px;}",
      // The account row is the last item of the sidebar list, so it shares the
      // sidebar surface (#2a2d34) and borrows .lumen-tab's hover/active values.
      // It used to paint its own darker slab (#1f2228) behind a hard #3b424c
      // rule, which detached it from the sidebar and read as a stray dark box.
      ".lumen-account-entry{display:flex;align-items:center;gap:10px;width:100%;box-sizing:border-box;",
      "padding:13px 14px 14px;border:0;border-top:1px solid rgba(255,255,255,.07);background:transparent;",
      "color:#e6e9ec;text-align:left;font-family:inherit;cursor:pointer;transition:background .12s;}",
      ".lumen-account-entry:hover{background:rgba(255,255,255,.04);}",
      ".lumen-account-entry.active{background:#3d4450;}",
      ".lumen-account-entry:focus-visible{outline:2px solid #66c0f4;outline-offset:-3px;}",
      ".lumen-account-avatar{position:relative;display:inline-flex;align-items:center;justify-content:center;width:32px;height:32px;",
      "box-sizing:border-box;flex:0 0 32px;border:1px solid rgba(255,255,255,.13);border-radius:50%;",
      "background:rgba(255,255,255,.05);color:#a6afb9;overflow:hidden;",
      "transition:border-color .14s,background-color .14s;}",
      // Two stacked layers, crossfaded: the lua.tools mark at rest, the profile
      // glyph once the row is pointed at (or gamepad-focused, same treatment).
      // The mark is a round badge, so it fills the circle instead of being inset
      // inside it — any padding here reads as a shrunken logo floating in a ring.
      ".lumen-account-avatar>img.lumen-account-avatar-brand{position:absolute;inset:0;width:100%;height:100%;",
      "box-sizing:border-box;object-fit:contain;opacity:1;transition:opacity .14s;}",
      ".lumen-account-avatar>.lumen-account-avatar-glyph{position:absolute;inset:0;display:flex;",
      "align-items:center;justify-content:center;opacity:0;transition:opacity .14s;}",
      ".lumen-account-entry:hover .lumen-account-avatar-brand{opacity:0;}",
      ".lumen-account-entry:hover .lumen-account-avatar-glyph{opacity:1;}",
      ".lumen-account-entry.active-focus .lumen-account-avatar-brand{opacity:0;}",
      ".lumen-account-entry.active-focus .lumen-account-avatar-glyph{opacity:1;}",
      // While the mark rests it IS the circle, so the avatar's own rim and fill
      // must not ring it. Written as the ABSENCE of chrome at rest rather than as
      // a hover rule that repaints it: hover and gamepad focus then fall back to
      // whichever rim the row's state already owns (neutral, or connected blue).
      ".lumen-account-entry:not(:hover):not(.active-focus) .lumen-account-avatar.branded{",
      "border-color:transparent;background-color:transparent;}",
      // A rim, not a ring: at full accent this read as a bright blue circle
      // drawn around the avatar rather than as part of it.
      ".lumen-account-entry.connected .lumen-account-avatar{border-color:rgba(102,192,244,.24);",
      "background:rgba(26,159,255,.1);color:#66c0f4;}",
      ".lumen-account-avatar svg{width:17px;height:17px}.lumen-account-avatar img{width:100%;height:100%;object-fit:cover;}",
      ".lumen-account-entry>span:last-child{display:flex;min-width:0;flex-direction:column;gap:3px;}",
      ".lumen-account-entry strong{color:#f1f3f5;font-size:12.5px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}",
      // Three lines, not two: the 200px sidebar column is ~130px wide once the
      // avatar and padding are taken out, and a two-line clamp ate the tail of the
      // signed-out copy with no ellipsis to show it had been cut.
      ".lumen-account-entry small{color:#9aa3ad;font-size:10.5px;line-height:1.3;display:-webkit-box;",
      "-webkit-box-orient:vertical;-webkit-line-clamp:3;overflow:hidden;}",
      // While the auth status is still being fetched the row says so, with the
      // shared spinner in place of the avatar, instead of guessing "signed out".
      ".lumen-account-entry.checking strong{color:#c5cad0;}",
      ".lumen-account-entry.checking .lumen-account-avatar{border-style:dashed;}",
      ".lumen-account-entry .lumen-spin{width:13px;height:13px;}",
      // Connected reads as status, not as body copy — same dot + green as the
      // account panel's own "Connected" line in the content area.
      ".lumen-account-entry.connected small{display:flex;align-items:center;gap:6px;",
      "color:#8fd06e;font-weight:700;}",
      ".lumen-account-entry.connected small:before{content:'';flex:0 0 auto;width:5px;height:5px;",
      "border-radius:50%;background:#79c754;}",
      // content
      ".lumen-content{flex:1;background:#25282e;background-image:radial-gradient(circle at left top,",
      "rgba(74,81,92,.4) 0%,rgba(75,81,92,0) 60%);display:flex;flex-direction:column;overflow:hidden;}",
      ".lumen-ctop{display:flex;align-items:center;padding:24px 24px 14px;}",
      ".lumen-ctop .h{flex:1;color:#fff;font-size:22px;font-weight:700;}",
      // The account tab is the one header that names a third-party service, so it
      // is signed with that service's mark rather than left as bare text.
      ".lumen-account-title{display:inline-flex;align-items:center;gap:10px;}",
      ".lumen-account-title-mark{width:26px;height:26px;flex:0 0 26px;object-fit:contain;}",
      ".lumen-account-back{display:inline-flex;align-items:center;justify-content:center;width:30px;height:30px;",
      "margin-right:8px;padding:0;border:0;border-radius:3px;background:transparent;color:#b8bcbf;cursor:pointer;}",
      ".lumen-account-back svg{width:20px;height:20px}.lumen-account-back:hover{color:#fff;background:rgba(255,255,255,.07);}",
      ".lumen-account-back:focus-visible{outline:2px solid #66c0f4;outline-offset:1px;}",
      ".lumen-exp{display:inline-block;vertical-align:middle;margin-left:10px;font-size:10px;",
      "font-weight:700;text-transform:uppercase;letter-spacing:.5px;color:#c89bf2;",
      "background:#2c2440;padding:2px 8px;border-radius:10px;}",
      ".lumen-info{display:inline-flex;vertical-align:middle;margin-left:6px;width:16px;height:16px;",
      "align-items:center;justify-content:center;font-size:11px;font-weight:700;font-style:italic;",
      "cursor:pointer;color:#8f98a0;border:1px solid #4a5663;border-radius:50%;}",
      ".lumen-info:hover{color:#fff;border-color:#8f98a0;}",
      ".lumen-ctop .x{cursor:pointer;color:#b8bcbf;font-size:18px;padding:2px 8px;border-radius:3px;}",
      ".lumen-ctop .x:hover{color:#fff;background:rgba(255,255,255,.08);}",
      ".lumen-ctop .reset{cursor:pointer;color:#b8bcbf;font-size:12px;font-weight:600;" +
        "margin-right:10px;padding:5px 12px;border-radius:4px;white-space:nowrap;" +
        "border:1px solid rgba(255,255,255,.14);transition:.12s;}",
      ".lumen-ctop .reset:hover{color:#fff;background:rgba(255,255,255,.08);}",
      ".lumen-ctop .reset.confirm{color:#ffb84d;border-color:#ffb84d;}",
      ".lumen-body{flex:1;min-height:0;padding:0 24px 22px;overflow-y:auto;overflow-x:hidden;overscroll-behavior:contain;}",
      ".lumen-tab-panel{display:none;}",
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
      ".lumen-row input[type=text],.lumen-row input[type=password],.lumen-row input[type=number],.lumen-row select{",
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
      // lua.tools account and Fixes catalogue
      ".lumen-account-intro{max-width:78ch;margin:0 0 18px;color:#b8bcbf;font-size:13px;line-height:1.55;}",
      // ── one card surface for the whole plugin area ────────────────────────
      // The account card, the sign-in methods, the catalogue game cards and the
      // per-fix cards are peers, so they share one fill and one ring. They used
      // to disagree (#20242b vs #191b20 vs #181a1f), which made the same kind of
      // panel look like three different materials between tabs.
      ".lumen-account-card{box-sizing:border-box;overflow:hidden;border:1px solid #414955;",
      "border-radius:8px;background:#20242b;}",
      // Sign-in methods are two peer cards, not one panel cut down the middle.
      // minmax(0,...), not a bare 1fr: 1fr floors at min-content, so the code card
      // (input + button on one line) claimed 333px against the Discord card's 307
      // and the two actions came out 26px apart in width.
      ".lumen-account-login-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));",
      "gap:12px;margin-bottom:14px;align-items:stretch;}",
      ".lumen-account-login-grid>section{display:flex;position:relative;flex-direction:column;align-items:flex-start;",
      "gap:0;padding:20px;box-sizing:border-box;border:1px solid #414955;border-radius:8px;background:#20242b;}",
      ".lumen-account-method-icon{display:inline-flex;align-items:center;justify-content:center;width:34px;height:34px;",
      "box-sizing:border-box;margin-bottom:14px;border:1px solid rgba(88,101,242,.4);color:#8c95f8;",
      "background:rgba(88,101,242,.16);border-radius:50%;}",
      ".lumen-account-method-icon svg{width:18px;height:18px}",
      ".lumen-account-method-icon.code{border-color:rgba(102,192,244,.36);color:#66c0f4;background:rgba(102,192,244,.13);}",
      ".lumen-account-login-grid h3{margin:0 0 7px;color:#fff;font-size:15px;font-weight:700;}",
      // Two lines' worth of room whether the copy needs it or not. It is what keeps
      // the two cards' headers the same height, and so their actions on one line.
      ".lumen-account-login-grid p{margin:0 0 16px;min-height:36px;color:#9ba3ab;font-size:12px;line-height:1.5;}",
      // The card's only action reads as its call to action, so it spans the card
      // rather than sitting as a small tag in the corner of a wide panel. NOT
      // bottom-anchored: the Discord card has a cleanup row under its button, so
      // pushing both actions down put them on different lines. They follow the copy
      // instead, which is held to a fixed height above.
      ".lumen-account-login-grid>section>button{align-self:stretch;}",
      // The Discord-cleanup preference, inside the card whose button it qualifies.
      // The whole row is the <label>, so the copy toggles the switch too.
      ".lumen-account-method-option{display:flex;align-items:center;gap:14px;width:100%;box-sizing:border-box;",
      "margin-top:15px;padding-top:14px;border-top:1px solid rgba(255,255,255,.08);cursor:pointer;}",
      ".lumen-account-method-option>span:first-child{display:flex;min-width:0;flex:1;flex-direction:column;gap:4px;}",
      ".lumen-account-method-option strong{color:#dfe3e7;font-size:11.5px;font-weight:700;}",
      ".lumen-account-method-option small{color:#8f98a0;font-size:10.5px;line-height:1.45;}",
      // OAuth handoff: an indeterminate sweep pinned to the bottom edge of the card
      // that owns the wait, plus a brand-tinted rim and a breathing method icon.
      ".lumen-account-oauth{position:absolute;right:0;bottom:0;left:0;height:2px;overflow:hidden;",
      "border-radius:0 0 8px 8px;background:rgba(255,255,255,.06);opacity:0;transition:opacity .18s;}",
      ".lumen-account-oauth.on{opacity:1;}",
      ".lumen-account-oauth span{position:absolute;top:0;bottom:0;width:38%;",
      "background:linear-gradient(90deg,rgba(88,101,242,0),#5865f2,rgba(88,101,242,0));",
      "animation:lumen-oauth-sweep 1.15s linear infinite;}",
      ".lumen-account-login-grid>section[data-method='code'] .lumen-account-oauth span{",
      "background:linear-gradient(90deg,rgba(102,192,244,0),#66c0f4,rgba(102,192,244,0));}",
      ".lumen-account-login-grid>section.handoff{border-color:#5865f2;box-shadow:0 0 0 1px rgba(88,101,242,.25);}",
      ".lumen-account-login-grid>section[data-method='code'].handoff{border-color:#66c0f4;",
      "box-shadow:0 0 0 1px rgba(102,192,244,.25);}",
      ".lumen-account-login-grid>section.handoff .lumen-account-method-icon{",
      "animation:lumen-oauth-pulse 1.4s ease-in-out infinite;}",
      "@keyframes lumen-oauth-sweep{0%{transform:translateX(-100%);}100%{transform:translateX(340%);}}",
      "@keyframes lumen-oauth-pulse{0%,100%{transform:scale(1);}50%{transform:scale(1.07);}}",
      // Same height as .lumen-account-button's min-height, so this row and the
      // Discord button match on both edges rather than only on their top.
      ".lumen-account-code-row{display:flex;align-items:stretch;gap:8px;width:100%;height:34px;}",
      // The field grows with the card. At a fixed 104px it left a dead strip of
      // panel to the right of the button, which read as an unfinished row.
      ".lumen-account-code-row input{min-width:0;flex:1;box-sizing:border-box;background:#171a20;color:#fff;",
      "border:1px solid #414955;border-radius:3px;padding:4px 9px;font:700 14px monospace;letter-spacing:.12em;",
      "text-align:center;text-transform:uppercase;}",
      ".lumen-account-code-row input:focus,.lumen-fixes-search:focus{outline:2px solid #66c0f4;outline-offset:1px;border-color:#66c0f4;}",
      ".lumen-account-button{display:inline-flex;align-items:center;justify-content:center;gap:7px;min-height:34px;",
      "padding:7px 13px;border:1px solid #4a5663;border-radius:3px;background:#303640;color:#dcdedf;",
      "font:600 12px inherit;cursor:pointer;transition:background .12s,border-color .12s,color .12s;}",
      ".lumen-account-button:hover{background:#3b4350;color:#fff}.lumen-account-button.primary{background:#1a9fff;border-color:#1a9fff;color:#fff;}",
      ".lumen-account-button.primary:hover{background:#3cb0ff;border-color:#3cb0ff}.lumen-account-button:disabled{opacity:.5;cursor:wait;}",
      ".lumen-account-button:focus-visible,.lumen-fixes-game:focus-visible{outline:2px solid #66c0f4;outline-offset:2px;}",
      ".lumen-account-button svg{display:block;width:14px;height:14px;flex:0 0 auto;}",
      // A bare inline wrapper gives the mark nothing to centre against, so it rode
      // on the label's baseline instead of on its optical middle.
      ".lumen-account-button-icon{display:inline-flex;align-items:center;justify-content:center;flex:0 0 auto;}",
      // Signing in with Discord IS Discord — brand fill, so the primary action is
      // unmistakable next to the quiet code fallback.
      ".lumen-account-button.discord{background:#5865f2;border-color:#5865f2;color:#fff;}",
      ".lumen-account-button.discord:hover{background:#6b76f5;border-color:#6b76f5;}",
      ".lumen-account-status{min-height:18px;margin-top:10px;color:#9ba3ab;font-size:12px;line-height:1.45;}",
      ".lumen-account-status.error{color:#ec7777}.lumen-account-status.success{color:#79c754;}",
      ".lumen-account-connected-view{width:100%;max-width:650px;}",
      ".lumen-account-connected{display:flex;align-items:center;gap:14px;padding:18px 20px;}",
      ".lumen-account-connected-avatar{display:inline-flex;align-items:center;justify-content:center;width:46px;height:46px;",
      "box-sizing:border-box;flex:0 0 46px;border:1px solid rgba(102,192,244,.4);border-radius:50%;overflow:hidden;",
      "background:rgba(26,159,255,.16);color:#66c0f4;}",
      ".lumen-account-connected-avatar img{width:100%;height:100%;object-fit:cover;}",
      ".lumen-account-connected-avatar svg{width:23px;height:23px}.lumen-account-connected-identity{display:flex;min-width:0;flex-direction:column;gap:5px;}",
      ".lumen-account-connected-identity strong{overflow:hidden;color:#fff;font-size:17px;font-weight:700;text-overflow:ellipsis;white-space:nowrap;}",
      ".lumen-account-connected-identity small{display:inline-flex;align-items:center;gap:6px;color:#8fd06e;font-size:11px;font-weight:700;}",
      ".lumen-account-connected-identity small:before{content:'';width:6px;height:6px;border-radius:50%;background:#79c754;}",
      // Sign-out stays quiet until you reach for it, then admits what it does.
      ".lumen-account-logout{flex:0 0 auto;margin-left:auto;background:transparent;}",
      ".lumen-account-logout:hover{border-color:#a2464b;background:rgba(236,92,92,.1);color:#f0908f;}",
      ".lumen-account-retention-switch{flex:0 0 38px}.lumen-account-retention-switch input:focus-visible+.sl{outline:2px solid #66c0f4;outline-offset:2px;}",
      ".lumen-account-card>.lumen-account-status{min-height:0;margin:0;padding:0 20px 16px;}",
      ".lumen-account-card>.lumen-account-status:empty{display:none;}",
      ".lumen-fixes-login-gate{display:flex;align-items:center;justify-content:center;min-height:430px;color:#66c0f4;",
      "font-size:14px;font-weight:700;}",
      // Chip rows wrap. They used to scroll horizontally, which sliced the last
      // chip in half against the panel edge with nothing to say it kept going.
      ".lumen-fixes-tags{display:flex;align-items:center;flex-wrap:wrap;gap:7px;padding:0 0 12px;}",
      ".lumen-fixes-tag{flex:0 0 auto;padding:6px 11px;border:1px solid #414955;border-radius:999px;background:#20242b;",
      "color:#aeb6bf;font:700 10.5px 'Motiva Sans',Arial;line-height:1;cursor:pointer;white-space:nowrap;}",
      ".lumen-fixes-tag:hover{border-color:#657181;color:#fff}",
      // Selection is the Lumen accent, not a second purple accent of its own.
      ".lumen-fixes-tag.active{background:#1a9fff;border-color:#1a9fff;color:#fff;}",
      ".lumen-fixes-tag[data-tag='denuvowo']:not(.active){border-color:#4c3b70;color:#b797ff;background:#211b31;}",
      ".lumen-fixes-tag[data-tag='generic']:not(.active){border-color:#642844;color:#ed6b9f;background:#2c1721;}",
      ".lumen-fixes-tag[data-tag='online-fix']:not(.active){border-color:#274d7b;color:#58a6ff;background:#16243a;}",
      ".lumen-fixes-tag[data-tag='rockstar-games']:not(.active){border-color:#754012;color:#f59d38;background:#2b1c10;}",
      ".lumen-fixes-tag[data-tag='steamtools-achievements-fix']:not(.active){border-color:#6c5b10;color:#edc72d;background:#29250f;}",
      ".lumen-fixes-tag[data-tag='ubisoft']:not(.active){border-color:#692b31;color:#f06e79;background:#2c181b;}",
      ".lumen-fixes-tag[data-tag='voices38-crack']:not(.active),.lumen-fixes-tag[data-tag='voices38']:not(.active){border-color:#17653e;color:#38d786;background:#10291e;}",
      ".lumen-fixes-search{width:100%;box-sizing:border-box;margin:0 0 14px;padding:9px 11px;border:1px solid #414955;",
      "border-radius:3px;background:#171a20;color:#dcdedf;font:13px inherit;}",
      ".lumen-fixes-list{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;align-items:stretch;}",
      ".lumen-fixes-game{display:flex;min-width:0;overflow:hidden;flex-direction:column;align-items:stretch;width:100%;padding:0;",
      "border:1px solid #414955;border-radius:8px;background:#20242b;color:#dcdedf;text-align:left;font-family:inherit;cursor:pointer;}",
      ".lumen-fixes-game:hover{border-color:#1a9fff;background:#262b33}.lumen-fixes-game img{display:block;width:100%;height:auto;",
      "aspect-ratio:460/215;object-fit:cover;background:#111318;border-radius:0;}",
      ".lumen-fixes-game-copy{display:flex;min-width:0;flex:1;flex-direction:column;gap:8px;padding:11px 12px 12px;}",
      ".lumen-fixes-game-copy strong{display:-webkit-box;overflow:hidden;color:#e7e9eb;font-size:13px;font-weight:700;line-height:1.25;",
      "-webkit-box-orient:vertical;-webkit-line-clamp:2;}",
      ".lumen-fixes-game-meta{display:flex;align-items:center;gap:5px;margin-top:auto;color:#747e88;font-size:10.5px;font-variant-numeric:tabular-nums;}",
      ".lumen-fixes-game-meta-icon{display:inline-flex;width:12px;height:12px;flex:0 0 12px}.lumen-fixes-game-meta-icon svg{display:block;width:12px;height:12px;}",
      ".lumen-fixes-empty{grid-column:1/-1;padding:48px 0;text-align:center;color:#8f98a0;font-size:13px;}",
      ".lumen-fixes-pager{display:flex;align-items:center;justify-content:flex-end;gap:10px;padding-top:12px}.lumen-fixes-pager span{color:#8f98a0;font-size:11px;font-variant-numeric:tabular-nums;}",
      ".lumen-fixes-detail-head{display:flex;align-items:center;gap:13px;padding:0 0 14px;border-bottom:1px solid rgba(255,255,255,.09);}",
      ".lumen-fixes-detail-back{min-height:28px;padding:4px 8px;font-size:11.5px;line-height:1;}",
      ".lumen-fixes-detail-head>span{display:flex;min-width:0;flex-direction:column;gap:3px}.lumen-fixes-detail-head strong{color:#fff;font-size:16px;}",
      ".lumen-fixes-detail-head small{color:#7f8992;font-size:10.5px}",
      ".lumen-fixes-detail-tags{display:flex;align-items:center;flex-wrap:wrap;gap:7px;padding:14px 0;}",
      ".lumen-fixes-fix-cards{display:flex;flex-direction:column;gap:12px;padding-bottom:6px;}",
      ".lumen-fixes-fix-card{padding:17px 18px;border:1px solid #414955;border-radius:8px;background:#20242b;}",
      ".lumen-fixes-fix-card.applied{border-color:rgba(121,199,84,.45);background:#1f2620;}",
      ".lumen-fixes-fix-card-top{display:flex;align-items:flex-start;justify-content:space-between;gap:22px;}",
      ".lumen-fixes-fix-information{display:flex;min-width:0;flex:1;flex-direction:column;align-items:flex-start;gap:8px;}",
      ".lumen-fixes-fix-title{color:#eef0f2;font-size:14px;font-weight:750;line-height:1.3;}",
      ".lumen-fixes-fix-date{display:inline-flex;align-items:center;gap:5px;color:#707983;font-size:10.5px;font-variant-numeric:tabular-nums;}",
      ".lumen-fixes-fix-date>span:first-child{display:inline-flex;width:12px;height:12px}.lumen-fixes-fix-date svg{display:block;width:12px;height:12px;}",
      ".lumen-fixes-fix-tags{display:flex;align-items:center;gap:6px;flex-wrap:wrap;}",
      ".lumen-fixes-fix-tag{display:inline-flex;padding:4px 8px;border:1px solid #415168;border-radius:3px;background:#172234;color:#58a6ff;",
      "font-size:9.5px;font-weight:700;line-height:1;white-space:nowrap;}",
      ".lumen-fixes-fix-actions{display:flex;min-width:116px;flex:0 0 116px;flex-direction:column;align-items:flex-end;gap:7px;}",
      ".lumen-fixes-fix-actions .lumen-account-button.primary{background:#1a9fff;border-color:#1a9fff;padding-left:16px;padding-right:16px;}",
      ".lumen-fixes-fix-actions .lumen-account-button.primary:hover{background:#3cb0ff;border-color:#3cb0ff;}",
      // A blocked fix (not installed / needs Proton / needs preparation) kept the
      // accent fill at half opacity, so an action that cannot run still looked
      // like the primary one. Unavailable reads as neutral, not as dimmed blue.
      ".lumen-fixes-fix-actions .lumen-account-button.primary:disabled{background:#2f3742;",
      "border-color:#414955;color:#93a0ad;opacity:1;}",
      ".lumen-fixes-applied{white-space:nowrap;color:#9bdc7c;font-size:10.5px;font-weight:800;text-transform:uppercase;letter-spacing:.35px;}",
      ".lumen-fixes-fix-status{max-width:190px;color:#8f98a0;font-size:10.5px;line-height:1.3;text-align:right;}",
      ".lumen-fixes-fix-status.success{color:#9bdc7c}.lumen-fixes-fix-status.error{color:#ec7777;}",
      "#" + OVERLAY_ID + " ::selection{background:#1a9fff;color:#fff;}",
      "#" + OVERLAY_ID + " ::-webkit-scrollbar{width:9px;height:9px}#" + OVERLAY_ID + " ::-webkit-scrollbar-track{background:#202329;}",
      "#" + OVERLAY_ID + " ::-webkit-scrollbar-thumb{background:#4a515c;border:2px solid #202329;border-radius:8px;}",
      "@media(max-width:760px){.lumen-account-login-grid{grid-template-columns:1fr}.lumen-account-login-grid>section+section{border-left:0;border-top:1px solid #414955;}.lumen-fixes-list{grid-template-columns:repeat(2,minmax(0,1fr))}}",
      "@media(max-width:520px){.lumen-account-connected{flex-wrap:wrap}.lumen-account-logout{margin-left:60px}.lumen-fixes-list{grid-template-columns:1fr}.lumen-fixes-fix-card-top{flex-direction:column}.lumen-fixes-fix-actions{width:100%;min-width:0;flex-basis:auto;align-items:flex-start}.lumen-fixes-fix-status{text-align:left;}}",
      // Game Updates tab
      ".lumen-gu-search{width:100%;box-sizing:border-box;background:#1a1d23;color:#dcdedf;",
      "border:1px solid #3d4450;border-radius:3px;padding:8px 10px;font-size:13px;",
      "font-family:inherit;margin:0 0 12px;}",
      ".lumen-gu-search:focus{outline:none;border-color:#1a9fff;}",
      ".lumen-gu-actions{display:flex;justify-content:flex-end;gap:8px;margin:0 0 12px;}",
      ".lumen-load-lua{font-size:13px;}",
      ".lumen-game-builder{padding:8px 0 20px;}",
      ".lumen-builder-lookup{display:flex;align-items:center;gap:8px;margin-top:14px;}",
      ".lumen-builder-searchbox{position:relative;flex:1;min-width:0;}",
      ".lumen-builder-lookup input{width:100%;box-sizing:border-box;min-width:0;background:#1a1d23;color:#dcdedf;",
      "border:1px solid #3d4450;border-radius:3px;padding:9px 10px;font:13px inherit;}",
      ".lumen-builder-lookup input:focus,.lumen-builder-field input:focus{outline:none;border-color:#1a9fff;}",
      ".lumen-builder-results{display:none;position:absolute;left:0;right:0;top:calc(100% + 5px);z-index:6;",
      "flex-direction:column;max-height:286px;overflow-y:auto;border:1px solid #414955;border-radius:3px;",
      "background:#20242b;box-shadow:0 12px 28px rgba(0,0,0,.42);}",
      ".lumen-builder-results.open{display:flex;}",
      ".lumen-builder-result{display:flex;align-items:center;gap:10px;width:100%;padding:8px;border:0;",
      "border-bottom:1px solid rgba(255,255,255,.07);background:#20242b;color:#dcdedf;text-align:left;cursor:pointer;}",
      ".lumen-builder-result:last-child{border-bottom:0;}",
      ".lumen-builder-result:hover,.lumen-builder-result:focus,.lumen-builder-result.selected{background:#303844;outline:none;}",
      ".lumen-builder-result img{width:92px;height:43px;object-fit:cover;background:#171a20;border-radius:2px;}",
      ".lumen-builder-result span{display:flex;flex-direction:column;gap:3px;min-width:0;}",
      ".lumen-builder-result strong{font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}",
      ".lumen-builder-result small,.lumen-builder-results-empty{color:#8f98a0;font-size:11px;}",
      ".lumen-builder-results-empty{padding:11px 12px;line-height:1.4;}",
      ".lumen-builder-results-empty.loading{color:#b8bcbf;}",
      ".lumen-builder-results-empty.error{color:#ec7777;}",
      ".lumen-builder-status{min-height:22px;color:#8f98a0;font-size:12px;padding:12px 0;}",
      ".lumen-builder-status.loading{display:flex;align-items:center;gap:8px;color:#b8bcbf;}",
      ".lumen-builder-identity{display:flex;align-items:center;gap:14px;padding:14px 0 18px;",
      "border-bottom:1px solid rgba(255,255,255,.08);}",
      ".lumen-builder-identity img{width:138px;height:65px;object-fit:cover;border-radius:3px;background:#1a1d23;}",
      ".lumen-builder-game-name{color:#fff;font-size:18px;font-weight:700;line-height:1.25;}",
      ".lumen-builder-game-meta{color:#8f98a0;font-size:11px;line-height:1.4;margin-top:5px;}",
      ".lumen-builder-section-head{padding:19px 0 9px;}",
      ".lumen-builder-section-head>div{color:#dcdedf;font-size:14px;font-weight:700;}",
      ".lumen-builder-section-head small{display:block;color:#8f98a0;font-size:11.5px;",
      "line-height:1.4;margin-top:3px;}",
      ".lumen-builder-dlcs{display:flex;flex-direction:column;gap:5px;}",
      ".lumen-builder-dlc{display:flex;align-items:center;gap:9px;min-height:32px;}",
      ".lumen-builder-dlc input{width:150px;background:#1a1d23;color:#dcdedf;border:1px solid #3d4450;",
      "border-radius:3px;padding:7px 8px;font:12px inherit;}",
      ".lumen-builder-dlc small{flex:1;color:#6f7780;font-size:11px;}",
      ".lumen-icon-btn{flex:0 0 auto;width:28px;height:28px;padding:0;border:0;border-radius:3px;",
      "background:transparent;color:#737b84;cursor:pointer;font-size:18px;line-height:1;}",
      ".lumen-icon-btn:hover{background:rgba(236,92,92,.12);color:#ec5c5c;}",
      ".lumen-builder-add{margin-top:7px;padding:4px 2px;border:0;background:transparent;color:#66c0f4;",
      "font:600 12px inherit;cursor:pointer;}",
      ".lumen-builder-add:hover{color:#8fd0ff;text-decoration:underline;}",
      ".lumen-builder-depots{display:flex;flex-direction:column;border-top:1px solid rgba(255,255,255,.07);}",
      ".lumen-builder-depot{padding:12px 0;border-bottom:1px solid rgba(255,255,255,.07);}",
      ".lumen-builder-depot.virtual{padding-bottom:14px;}",
      ".lumen-builder-depot-top{display:flex;align-items:flex-end;gap:10px;margin-bottom:9px;}",
      ".lumen-builder-depot-top>a{color:#66c0f4;font-size:11px;text-decoration:none;margin-left:auto;",
      "padding:7px 2px;white-space:nowrap;}",
      ".lumen-builder-depot-top>a:hover{text-decoration:underline;color:#8fd0ff;}",
      ".lumen-builder-depot-top>a.disabled{opacity:.35;pointer-events:none;}",
      ".lumen-builder-package{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.3px;",
      "color:#8f98a0;background:rgba(255,255,255,.05);padding:4px 7px;border-radius:3px;margin-bottom:5px;}",
      ".lumen-builder-depot-fields{display:grid;grid-template-columns:minmax(0,2fr) minmax(145px,1fr);gap:10px;}",
      ".lumen-builder-field{display:flex;flex-direction:column;gap:4px;min-width:0;color:#8f98a0;font-size:10px;",
      "font-weight:700;text-transform:uppercase;letter-spacing:.35px;}",
      ".lumen-builder-field input{width:100%;box-sizing:border-box;min-width:0;background:#1a1d23;color:#dcdedf;",
      "border:1px solid #3d4450;border-radius:3px;padding:7px 8px;font:12px 'Motiva Sans',Arial,sans-serif;}",
      ".lumen-builder-depot-top .lumen-builder-field{width:150px;}",
      ".lumen-builder-secret{position:relative;min-width:0;}",
      ".lumen-virtual-key{grid-column:1/-1;color:#8f98a0;font-size:11.5px;padding:8px 10px;",
      "border:1px dashed #434b56;border-radius:3px;background:rgba(255,255,255,.025);}",
      ".lumen-builder-secret input{padding-right:60px;font-family:monospace;}",
      ".lumen-secret-toggle{position:absolute;right:4px;top:3px;bottom:3px;border:0;border-left:1px solid #343b45;",
      "background:#20242b;color:#8f98a0;border-radius:0 2px 2px 0;padding:0 8px;font:600 10px inherit;cursor:pointer;}",
      ".lumen-secret-toggle:hover{color:#fff;background:#292f38;}",
      ".lumen-builder-latest-note{color:#8f98a0;font-size:11px;line-height:1.45;margin-top:12px;",
      "padding-left:9px;border-left:2px solid #3d4450;}",
      ".lumen-builder-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:18px;padding-top:14px;",
      "border-top:1px solid rgba(255,255,255,.07);}",
      ".lumen-mbtn:disabled{opacity:.5;cursor:default;pointer-events:none;}",
      ".lumen-import-summary{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;margin:12px 0;",
      "background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.08);border-radius:3px;overflow:hidden;}",
      ".lumen-import-stat{display:flex;flex-direction:column;gap:4px;background:#202329;padding:11px 12px;}",
      ".lumen-import-stat span{color:#8f98a0;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.4px;}",
      ".lumen-import-stat strong{color:#fff;font-size:18px;font-weight:700;}",
      ".lumen-import-list{border-top:1px solid rgba(255,255,255,.07);margin-bottom:10px;}",
      ".lumen-import-item{display:flex;align-items:center;gap:12px;padding:9px 2px;",
      "border-bottom:1px solid rgba(255,255,255,.07);color:#dcdedf;font-size:13px;}",
      ".lumen-import-item>span{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}",
      ".lumen-import-item small{color:#8f98a0;font-size:11px;white-space:nowrap;}",
      "@media(max-width:760px){.lumen-builder-depot-fields{grid-template-columns:1fr;}",
      ".lumen-builder-depot-top{flex-wrap:wrap}.lumen-builder-identity img{width:108px;height:51px;}}",
      ".lumen-game{border-bottom:1px solid rgba(255,255,255,.06);}",
      ".lumen-game-head{display:flex;align-items:center;gap:12px;padding:10px 2px;cursor:pointer;}",
      ".lumen-game-head:hover{background:rgba(255,255,255,.03);}",
      ".lumen-cap{flex:0 0 auto;width:92px;height:43px;border-radius:3px;object-fit:cover;",
      "background:#1a1d23;}",
      ".lumen-game-meta{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px;}",
      ".lumen-game-name{color:#dcdedf;font-size:14px;white-space:nowrap;overflow:hidden;",
      "text-overflow:ellipsis;}",
      ".lumen-game-sub{color:#8f98a0;font-size:11px;}",
      ".lumen-depot-id{color:#727b84;font-size:11px;font-variant-numeric:tabular-nums;}",
      ".lumen-badge{display:inline-block;font-size:10px;font-weight:700;text-transform:uppercase;",
      "padding:2px 6px;border-radius:3px;margin-left:6px;vertical-align:middle;}",
      ".lumen-badge.lock{background:#3a2f1a;color:#ffb84d;}",
      ".lumen-badge.cur{background:#1a3a24;color:#6fd08c;}",
      ".lumen-badge.lt{background:#1a2c3a;color:#66c0f4;}",
      ".lumen-badge.err{background:#4a1a1a;color:#ff6f6f;display:inline-flex;align-items:center;vertical-align:middle;}",
      ".lumen-badge.err .info{display:inline-flex;margin-left:4px;width:11px;height:11px;",
      "align-items:center;justify-content:center;font-size:8px;font-weight:700;font-style:italic;",
      "border:1px solid currentColor;border-radius:50%;text-transform:none;line-height:1;box-sizing:border-box;}",
      ".lumen-badge.synth{background:#2a2d32;color:#cbd5e1;display:inline-flex;align-items:center;vertical-align:middle;}",
      ".lumen-badge.synth .info{display:inline-flex;margin-left:4px;width:11px;height:11px;",
      "align-items:center;justify-content:center;font-size:8px;font-weight:700;font-style:italic;",
      "border:1px solid currentColor;border-radius:50%;text-transform:none;line-height:1;box-sizing:border-box;}",
      ".lumen-badge.mute{background:#2a2d32;color:#cbd5e1;display:inline-flex;align-items:center;vertical-align:middle;}",
      ".lumen-badge.mute .info{display:inline-flex;margin-left:4px;width:11px;height:11px;",
      "align-items:center;justify-content:center;font-size:8px;font-weight:700;font-style:italic;",
      "border:1px solid currentColor;border-radius:50%;text-transform:none;line-height:1;box-sizing:border-box;}",
      ".lumen-ver.disabled{color:#5c6370;cursor:default;}",
      ".lumen-ver.disabled:hover{background:none;}",
      ".lumen-ver.disabled .dot{border-color:#434956;}",
      ".lumen-adv{flex:0 0 auto;color:#5c6370;font-size:11px;padding:2px 6px;",
      "cursor:pointer;white-space:nowrap;align-self:flex-start;}",
      ".lumen-adv:hover{color:#a0a6ad;text-decoration:underline;}",
      ".lumen-import{color:#66c0f4;}",
      ".lumen-import:hover{color:#8fd0ff;}",
      ".lumen-more{color:#66c0f4;font-size:12px;cursor:pointer;padding:6px 8px 4px 12px;",
      "user-select:none;}",
      ".lumen-more:hover{text-decoration:underline;}",
      ".lumen-vers{padding:4px 2px 10px 104px;display:flex;flex-direction:column;gap:2px;}",
      ".lumen-ver{display:flex;align-items:center;gap:10px;padding:6px 8px;border-radius:3px;",
      "cursor:pointer;font-size:13px;color:#cdd1d4;}",
      ".lumen-ver:hover{background:rgba(255,255,255,.05);}",
      ".lumen-ver.sel{background:#2b3340;}",
      ".lumen-ver .dot{flex:0 0 auto;width:12px;height:12px;border-radius:50%;border:2px solid #6b7280;}",
      ".lumen-ver.sel .dot{border-color:#1a9fff;background:#1a9fff;}",
      ".lumen-ver .vgid{color:#8f98a0;font-size:11px;font-family:monospace;}",
      ".lumen-del{margin-left:auto;flex:0 0 auto;cursor:pointer;color:#6b7280;",
      "font-size:13px;padding:2px 8px;border-radius:3px;opacity:0;transition:.12s;}",
      ".lumen-ver:hover .lumen-del{opacity:1;}",
      ".lumen-del:hover{color:#ec5c5c;background:rgba(236,92,92,.12);}",
      ".lumen-back{display:inline-flex;align-items:center;gap:6px;cursor:pointer;color:#b8bcbf;",
      "font-size:13px;}",
      ".lumen-back:hover{color:#fff;}",
      ".lumen-sub-title{color:#fff;font-size:16px;font-weight:700;margin:10px 0 2px;}",
      ".lumen-empty{color:#8f98a0;font-size:13px;padding:20px 4px;text-align:center;}",
      // About tab
      ".lumen-about-intro{color:#8f98a0;font-size:12px;padding:0 0 14px;line-height:1.4;}",
      ".lumen-about-ver{display:flex;align-items:center;gap:12px;padding:12px 2px;",
      "border-bottom:1px solid rgba(255,255,255,.06);}",
      ".lumen-about-ver .nm{flex:1;min-width:0;color:#dcdedf;font-size:14px;font-weight:600;}",
      ".lumen-about-ver .vv{color:#8f98a0;font-size:12px;font-family:monospace;margin-top:3px;",
      "font-weight:400;min-height:15px;}",
      ".lumen-channel-host{min-height:25px;margin-top:7px;}",
      ".lumen-channel{display:inline-flex;align-items:center;gap:2px;padding:2px;box-sizing:border-box;",
      "border:1px solid var(--lumen-theme-border,rgba(255,255,255,.10));border-radius:6px;",
      "background:var(--lumen-theme-bg,rgba(0,0,0,.16));}",
      ".lumen-channel.single{padding:4px 8px;border-color:transparent;",
      "background:var(--lumen-theme-raised,rgba(255,255,255,.04));",
      "color:var(--lumen-theme-muted,#8f98a0);font-size:11px;font-weight:600;line-height:1.2;}",
      ".lumen-channel-option{appearance:none;border:0;border-radius:4px;background:transparent;",
      "color:var(--lumen-theme-muted,#8f98a0);cursor:pointer;font:600 11px/1.2 'Motiva Sans',Arial,sans-serif;",
      "padding:4px 9px;transition:background .16s ease-out,color .16s ease-out,",
      "opacity .16s ease-out,transform .16s ease-out;}",
      ".lumen-channel-option:hover{color:var(--lumen-theme-text,#dcdedf);",
      "background:var(--lumen-theme-raised,rgba(255,255,255,.06));}",
      ".lumen-channel-option:active{transform:scale(.98);}",
      ".lumen-channel-option.active{color:#fff;background:var(--lumen-theme-accent,#1a9fff);}",
      ".lumen-channel-option:focus-visible{outline:2px solid var(--lumen-theme-accent,#66c0f4);outline-offset:2px;}",
      ".lumen-channel.busy{opacity:.6;}",
      ".lumen-channel.busy .lumen-channel-option{cursor:wait;pointer-events:none;}",
      ".lumen-channel-error{margin-top:4px;color:#ec5c5c;font-size:11px;line-height:1.35;}",
      ".lumen-channel-card-control{flex:0 0 160px;width:160px;text-align:right;}",
      ".lumen-channel-card-control .lumen-channel{position:relative;width:100%;height:40px;",
      "gap:4px;padding:4px;border-radius:10px;background:var(--lumen-theme-bg,rgba(0,0,0,.20));}",
      ".lumen-channel-card-control .lumen-channel::before{content:'';position:absolute;",
      "top:4px;bottom:4px;left:4px;width:calc(50% - 6px);box-sizing:border-box;",
      "border:1px solid rgba(102,192,244,.28);border-radius:6px;background:rgba(26,159,255,.18);",
      "border-color:color-mix(in srgb,var(--lumen-theme-accent,#1a9fff) 32%,transparent);",
      "background:color-mix(in srgb,var(--lumen-theme-accent,#1a9fff) 18%,transparent);",
      "transition:transform .18s ease-out;pointer-events:none;}",
      ".lumen-channel-card-control .lumen-channel[data-channel=beta]::before{",
      "transform:translateX(calc(100% + 4px));}",
      ".lumen-channel-card-control .lumen-channel-option{position:relative;z-index:1;",
      "display:inline-flex;align-items:center;justify-content:center;flex:1 1 50%;height:100%;min-width:0;",
      "padding:0 12px;border-radius:6px;background:transparent;font-size:13px;line-height:1;}",
      ".lumen-channel-card-control .lumen-channel-option:hover{background:transparent;}",
      ".lumen-channel-card-control .lumen-channel-option:not(.active):hover{",
      "background:var(--lumen-theme-raised,rgba(255,255,255,.055));}",
      ".lumen-channel-card-control .lumen-channel-option.active{",
      "color:var(--lumen-theme-text,#f5faff);background:transparent;}",
      ".lumen-channel-card-control .lumen-channel-option:focus-visible{outline-offset:-2px;}",
      "@media (prefers-reduced-motion:reduce){",
      ".lumen-channel-card-control .lumen-channel::before,.lumen-channel-option{transition-duration:.01ms;}}",
      ".lumen-about-state{flex:0 0 auto;font-size:11px;font-weight:700;text-transform:uppercase;",
      "letter-spacing:.4px;padding:3px 9px;border-radius:10px;white-space:nowrap;}",
      ".lumen-about-state.cur{background:#1a3a24;color:#6fd08c;}",
      ".lumen-about-state.upd{background:#3a2f1a;color:#ffb84d;}",
      ".lumen-about-state.unk{background:#2b303a;color:#8f98a0;}",
      ".lumen-about-actions{margin-top:22px;display:flex;flex-direction:column;gap:16px;}",
      ".lumen-about-act{background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.08);",
      "border-radius:8px;padding:16px 18px;display:flex;align-items:center;gap:16px;}",
      ".lumen-about-act .txt{flex:1;min-width:0;}",
      ".lumen-about-act .at{color:#dcdedf;font-size:14px;font-weight:600;margin-bottom:4px;}",
      ".lumen-about-act .ad{color:#8f98a0;font-size:12px;line-height:1.45;}",
      ".lumen-about-btn{flex:0 0 103px;width:103px;height:38px;box-sizing:border-box;",
      "display:flex;align-items:center;justify-content:center;cursor:pointer;font-size:13px;font-weight:600;",
      "padding:9px 18px;border-radius:4px;border:1px solid #1a9fff;background:#1a9fff;",
      "color:#fff;white-space:nowrap;transition:.12s;}",
      ".lumen-about-btn:hover{background:#3cb0ff;border-color:#3cb0ff;}",
      ".lumen-about-btn.confirm{background:#e0922f;border-color:#e0922f;}",
      ".lumen-about-btn.busy{opacity:.6;pointer-events:none;}",
      ".lumen-about-credit{margin-top:26px;text-align:center;color:#5c6370;font-size:11px;",
      "letter-spacing:.3px;}",
      ".lumen-about-credit a{color:#66c0f4;text-decoration:none;}",
      ".lumen-about-credit a:hover{text-decoration:underline;}",
      ".lumen-about-right{flex:0 0 auto;display:inline-flex;align-items:center;min-width:90px;",
      "justify-content:flex-end;}",
      // Cloud Saves tab — sign in/out button (primary filled + outline variant)
      ".lumen-cloud-btn{flex:0 0 auto;cursor:pointer;font-size:13px;font-weight:600;",
      "padding:8px 18px;border-radius:4px;border:1px solid #1a9fff;background:#1a9fff;",
      "color:#fff;white-space:nowrap;transition:.12s;user-select:none;}",
      ".lumen-cloud-btn:hover{background:#3cb0ff;border-color:#3cb0ff;}",
      ".lumen-cloud-btn.secondary{background:transparent;border-color:rgba(255,255,255,.18);",
      "color:#b8bcbf;}",
      ".lumen-cloud-btn.secondary:hover{background:rgba(255,255,255,.08);color:#fff;",
      "border-color:rgba(255,255,255,.3);}",
      ".lumen-cloud-btn.busy{opacity:.6;pointer-events:none;}",
      ".lumen-cloud-actions{position:sticky;bottom:0;z-index:4;display:flex;align-items:center;",
      "justify-content:space-between;gap:12px;margin:18px -8px 0;padding:12px;",
      "background:#23262d;border:1px solid rgba(255,255,255,.12);border-radius:5px;",
      "box-shadow:0 -8px 24px rgba(0,0,0,.25);color:#dcdedf;font-size:13px;font-weight:600;}",
      ".lumen-cloud-action-buttons{display:flex;gap:8px;align-items:center;}",
      ".lumen-cloud-pending{margin-top:8px;padding:16px;background:rgba(26,159,255,.08);",
      "border:1px solid rgba(26,159,255,.25);border-radius:4px;display:flex;flex-direction:column;gap:5px;}",
      // Cloud Saves games list: search + cards (reuses .lumen-game* look) + a
      // per-game location/sync badge with a leading status dot.
      ".lumen-cloud-search{width:100%;box-sizing:border-box;background:#1a1d23;color:#dcdedf;",
      "border:1px solid #3d4450;border-radius:3px;padding:8px 10px;font-size:13px;",
      "font-family:inherit;margin:6px 0 8px;}",
      ".lumen-cloud-search:focus{outline:none;border-color:#1a9fff;}",
      ".lumen-cloud-acct{display:inline-flex;align-items:center;gap:6px;margin:0 0 12px;",
      "padding:3px 4px 3px 10px;border-radius:14px;background:rgba(255,255,255,.05);",
      "border:1px solid rgba(255,255,255,.10);}",
      ".lumen-cloud-acct:hover{background:rgba(255,255,255,.08);border-color:rgba(255,255,255,.18);}",
      ".lumen-cloud-acct .fico{display:inline-flex;color:#8f98a0;flex:0 0 auto;}",
      ".lumen-cloud-acctsel{background:transparent;color:#cdd1d4;border:0;outline:none;",
      "font-size:12px;font-weight:600;font-family:inherit;cursor:pointer;padding:2px 4px;",
      "max-width:180px;}",
      ".lumen-cloud-acctsel option{background:#23262d;color:#dcdedf;}",
      ".lumen-capsule-badge{flex:0 0 auto;display:inline-flex;align-items:center;gap:6px;",
      "font-size:11px;font-weight:700;padding:4px 10px;border-radius:12px;white-space:nowrap;}",
      ".lumen-capsule-badge .d{width:7px;height:7px;border-radius:50%;background:currentColor;",
      "flex:0 0 auto;}",
      ".lumen-capsule-badge.b-local{background:#2b303a;color:#9fb3c4;}",
      ".lumen-capsule-badge.b-cloud{background:#14283a;color:#66c0f4;}",
      ".lumen-capsule-badge.b-both{background:#1e2933;color:#9bc8e4;}",
      ".lumen-capsule-badge.b-checking{background:#2b303a;color:#8f98a0;}",
      ".lumen-capsule-badge .lumen-spin{width:11px;height:11px;border-width:2px;}",
      // loading spinner (version line + state pill while versions are fetched)
      ".lumen-spin{display:inline-block;width:14px;height:14px;box-sizing:border-box;",
      "border:2px solid rgba(255,255,255,.16);border-top-color:#9aa3ab;border-radius:50%;",
      "animation:lumen-rot .7s linear infinite;vertical-align:middle;}",
      "@keyframes lumen-rot{to{transform:rotate(360deg);}}",
      // confirm modal (validate prompt) — sits above the settings overlay
      ".lumen-modal-back{position:fixed;inset:0;z-index:2147483647!important;display:flex;",
      "align-items:center;justify-content:center;background:rgba(0,0,0,.6);",
      "font-family:'Motiva Sans',Arial,Helvetica,sans-serif;}",
      ".lumen-modal{width:420px;max-width:90vw;background:#23262d;border-radius:4px;",
      "border:1px solid rgba(0,0,0,.5);box-shadow:0 16px 48px rgba(0,0,0,.6);",
      "padding:22px 24px 18px;}",
      ".lumen-modal .mt{color:#fff;font-size:17px;font-weight:700;margin-bottom:10px;}",
      ".lumen-modal .mb{color:#b8bcbf;font-size:13px;line-height:1.5;margin-bottom:18px;}",
      ".lumen-modal .mrow{display:flex;justify-content:flex-end;gap:10px;}",
      ".lumen-mbtn{cursor:pointer;font-size:13px;font-weight:600;padding:8px 16px;",
      "border-radius:4px;border:1px solid rgba(255,255,255,.14);color:#b8bcbf;",
      "background:transparent;transition:.12s;}",
      ".lumen-mbtn:hover{color:#fff;background:rgba(255,255,255,.08);}",
      ".lumen-mbtn.primary{background:#1a9fff;border-color:#1a9fff;color:#fff;}",
      ".lumen-mbtn.primary:hover{background:#3cb0ff;border-color:#3cb0ff;}",
      ".lumen-del-all{border-color:rgba(236,92,92,.4);color:#e88a8a;}",
      ".lumen-del-all:hover{background:rgba(236,92,92,.15);border-color:#ec5c5c;color:#fff;}",
      ".lumen-del-all-row{margin-top:16px;justify-content:center;}",
      // Themes tab
      ".lumen-theme-section{margin:16px 0 22px;padding:14px 16px;background:rgba(255,255,255,.025);border:1px solid rgba(255,255,255,.07);border-radius:6px;}",
      ".lumen-theme-head{color:#dcdedf;font-size:15px;font-weight:700;margin:16px 0 9px;}",
      ".lumen-theme-section .lumen-theme-head{margin-top:0;}",
      ".lumen-theme-list-head{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;margin:16px 0 9px;}",
      ".lumen-theme-list-head .lumen-theme-head{margin:0;}",
      ".lumen-theme-link{display:inline-block;color:#66c0f4;font-size:12px;cursor:pointer;margin-bottom:10px;}",
      ".lumen-theme-link:hover{text-decoration:underline;}",
      ".lumen-theme-actions{display:flex;align-items:center;gap:9px;flex-wrap:wrap;}",
      ".lumen-theme-actions input[type=text]{flex:1;min-width:220px;background:#1a1d23;color:#dcdedf;border:1px solid #3d4450;border-radius:3px;padding:8px 10px;font-size:13px;}",
      ".lumen-theme-list{overflow:hidden;border:1px solid rgba(255,255,255,.07);border-radius:6px;background:rgba(0,0,0,.08);}",
      ".lumen-theme-card{display:flex;align-items:center;gap:16px;padding:14px 16px;border-bottom:1px solid rgba(255,255,255,.06);transition:background-color .16s ease-out;}",
      ".lumen-theme-card:last-child{border-bottom:0;}",
      ".lumen-theme-card.active{background:rgba(255,255,255,.04);box-shadow:inset 3px 0 var(--lumen-theme-accent,#1a9fff);}",
      ".lumen-theme-meta{flex:1;min-width:0;color:#dcdedf;font-size:14px;}",
      ".lumen-theme-title-row{display:flex;align-items:center;gap:8px;min-width:0;}",
      ".lumen-theme-meta .name{font-weight:600;line-height:1.3;}",
      ".lumen-theme-meta .author{color:#9da5ad;font-size:12px;margin-top:4px;line-height:1.35;}",
      ".lumen-theme-meta .description{color:#8f98a0;font-size:12px;line-height:1.45;margin-top:5px;max-width:440px;white-space:normal;}",
      ".lumen-theme-status{display:inline-flex;align-items:center;gap:5px;flex:0 0 auto;padding:3px 7px;border-radius:10px;background:rgba(26,159,255,.12);color:var(--lumen-theme-accent,#66c0f4);font-size:11px;font-weight:700;line-height:1;}",
      ".lumen-theme-status:before{content:'✓';font-size:10px;}",
      ".lumen-theme-card-actions{display:flex;align-items:center;justify-content:flex-end;gap:4px;flex:0 0 auto;}",
      ".lumen-theme-action{display:inline-flex;align-items:center;justify-content:center;min-height:32px;box-sizing:border-box;border:0;border-radius:4px;padding:6px 10px;background:transparent;color:#aeb6bf;font:600 12px 'Motiva Sans',Arial,Helvetica,sans-serif;white-space:nowrap;cursor:pointer;transition:background-color .16s ease-out,color .16s ease-out,opacity .16s ease-out;}",
      ".lumen-theme-action:hover{background:rgba(255,255,255,.07);color:#fff;}",
      ".lumen-theme-action:focus-visible{outline:2px solid var(--lumen-theme-accent,#1a9fff);outline-offset:2px;}",
      ".lumen-theme-action:disabled{cursor:default;opacity:.42;pointer-events:none;}",
      ".lumen-theme-action.primary{padding-left:14px;padding-right:14px;background:var(--lumen-theme-accent,#1a9fff);color:#fff;}",
      ".lumen-theme-action.primary:hover{filter:brightness(1.12);}",
      ".lumen-theme-action.danger:hover{background:rgba(236,92,92,.12);color:#f07a7a;}",
      ".lumen-theme-folder-action{min-height:30px;padding:4px 2px;color:#8f98a0;font-weight:500;}",
      ".lumen-theme-folder-action:before{content:'';width:14px;height:14px;margin-right:7px;background:currentColor;-webkit-mask:url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M3 6h6l2 2h10v10H3z'/%3E%3C/svg%3E\") center/contain no-repeat;mask:url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M3 6h6l2 2h10v10H3z'/%3E%3C/svg%3E\") center/contain no-repeat;}",
      ".lumen-theme-customize{margin-top:24px;}",
      ".lumen-theme-customize-head{margin-bottom:10px;}",
      ".lumen-theme-customize-head .lumen-theme-head{margin:0 0 4px;}",
      ".lumen-theme-category-bar{display:flex;align-items:center;justify-content:space-between;gap:16px;margin:0 0 10px;padding:10px 12px;border-radius:6px;background:rgba(255,255,255,.025);}",
      ".lumen-theme-category-label{color:#b8bcbf;font-size:12px;font-weight:600;}",
      ".lumen-theme-category{width:min(100%,280px);height:34px;box-sizing:border-box;border:1px solid #3d4450;border-radius:4px;padding:0 30px 0 10px;background:#1a1d23;color:#dcdedf;font:500 12px 'Motiva Sans',Arial,Helvetica,sans-serif;}",
      ".lumen-theme-customize-fields{overflow:hidden;border:1px solid rgba(255,255,255,.07);border-radius:6px;background:rgba(0,0,0,.08);}",
      ".lumen-theme-option-section{padding:9px 16px;border-bottom:1px solid rgba(255,255,255,.06);background:rgba(255,255,255,.025);color:#8f98a0;font-size:11px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;}",
      ".lumen-theme-option{display:grid;grid-template-columns:minmax(0,1fr) minmax(180px,240px);align-items:center;gap:20px;padding:14px 16px;border-bottom:1px solid rgba(255,255,255,.06);}",
      ".lumen-theme-option:last-child{border-bottom:0;}",
      ".lumen-theme-option .lbl{color:#dcdedf;font-size:13px;font-weight:600;line-height:1.35;}",
      ".lumen-theme-option .lumen-desc{margin-top:4px;line-height:1.4;}",
      ".lumen-theme-option-control{display:flex;align-items:center;justify-content:flex-end;gap:10px;min-width:0;}",
      ".lumen-theme-select{width:100%;height:34px;box-sizing:border-box;border:1px solid #3d4450;border-radius:4px;padding:0 30px 0 10px;background:#1a1d23;color:#dcdedf;font:500 12px 'Motiva Sans',Arial,Helvetica,sans-serif;}",
      ".lumen-theme-category:focus-visible,.lumen-theme-select:focus-visible,.lumen-theme-color:focus-visible,.lumen-theme-range:focus-visible{outline:2px solid var(--lumen-theme-accent,#1a9fff);outline-offset:2px;}",
      ".lumen-theme-range{flex:1;min-width:110px;accent-color:var(--lumen-theme-accent,#1a9fff);}",
      ".lumen-theme-range-value{color:#b8bcbf;font-size:12px;min-width:42px;text-align:right;}",
      ".lumen-theme-color{width:100%;height:34px;box-sizing:border-box;border:1px solid #3d4450;border-radius:4px;background:#1a1d23;color:#dcdedf;padding:4px 8px;}",
      ".lumen-theme-customize-footer{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-top:12px;}",
      ".lumen-theme-customize-footer .lumen-note{max-width:430px;line-height:1.4;}",
      "@media(max-width:700px){.lumen-theme-card{align-items:flex-start;flex-direction:column}.lumen-theme-card-actions{width:100%}.lumen-theme-category-bar{align-items:stretch;flex-direction:column;gap:7px}.lumen-theme-category{width:100%}.lumen-theme-option{grid-template-columns:1fr;gap:10px}.lumen-theme-option-control{justify-content:stretch}.lumen-theme-customize-footer{align-items:flex-start;flex-direction:column}.lumen-theme-customize-footer .lumen-theme-action{align-self:flex-end}}",
      ".lumen-theme-installing{display:flex;align-items:center;gap:10px;color:#b8bcbf;font-size:13px;padding:7px 0;}",
      "#"+OVERLAY_ID+".lumen-theme-busy{pointer-events:none;}",
      ".lumen-theme-applying{min-height:240px;display:flex;align-items:center;justify-content:center;gap:11px;color:#dcdedf;font-size:14px;font-weight:600;}",
      ".lumen-theme-applying .lumen-spin{width:18px;height:18px;border-color:rgba(255,255,255,.2);border-top-color:var(--lumen-theme-accent,#1a9fff);}",
      // Adaptive theme palette. Layout and control geometry stay protected;
      // only presentation follows colors exposed by the active client theme.
      ".lumen-win{border-color:var(--lumen-theme-border,rgba(0,0,0,.5));}",
      ".lumen-side{background:var(--lumen-theme-side,#2a2d34);}",
      ".lumen-content{background:var(--lumen-theme-panel,#25282e);background-image:none;}",
      ".lumen-side-title,.lumen-theme-link{color:var(--lumen-theme-accent,#1a9fff);}",
      ".lumen-tab.active{background:var(--lumen-theme-raised,#3d4450);color:var(--lumen-theme-text,#fff);}",
      ".lumen-ctop .h,.lumen-row .lbl,.lumen-theme-head,.lumen-theme-meta,.lumen-modal .mt{color:var(--lumen-theme-text,#fff);}",
      ".lumen-note,.lumen-desc,.lumen-theme-meta .author,.lumen-theme-meta .description,.lumen-modal .mb{color:var(--lumen-theme-muted,#8f98a0);}",
      ".lumen-row,.lumen-theme-card,.lumen-theme-option{border-color:var(--lumen-theme-border,rgba(255,255,255,.06));}",
      ".lumen-theme-list,.lumen-theme-customize-fields{background:var(--lumen-theme-bg,rgba(0,0,0,.08));border-color:var(--lumen-theme-border,rgba(255,255,255,.07));}",
      ".lumen-theme-category-bar,.lumen-theme-option-section{background:var(--lumen-theme-raised,rgba(255,255,255,.025));border-color:var(--lumen-theme-border,rgba(255,255,255,.06));}",
      ".lumen-theme-section,.lumen-about-act{background:var(--lumen-theme-bg,rgba(255,255,255,.03));border-color:var(--lumen-theme-border,rgba(255,255,255,.08));}",
      ".lumen-modal{background:var(--lumen-theme-panel,#23262d);border-color:var(--lumen-theme-border,rgba(0,0,0,.5));}",
      ".lumen-cloud-btn,.lumen-mbtn.primary,.lumen-theme-action.primary{background:var(--lumen-theme-accent,#1a9fff);border-color:var(--lumen-theme-accent,#1a9fff);}",
      ".lumen-sw input:checked + .sl{background:var(--lumen-theme-accent,#1a9fff);}",
      // Controls and content surfaces use the same resolved palette. Keep these
      // selectors explicit: themes frequently restyle generic Steam controls.
      ".lumen-gu-search,.lumen-cloud-search,.lumen-theme-actions input[type=text],.lumen-theme-category,.lumen-theme-select,.lumen-theme-color,.lumen-cloud-acctsel{background:var(--lumen-theme-bg,#1a1d23);color:var(--lumen-theme-text,#dcdedf);border-color:var(--lumen-theme-border,#3d4450);}",
      ".lumen-row input[type=text],.lumen-row input[type=number],.lumen-row select{background:var(--lumen-theme-bg,#1a1d23);color:var(--lumen-theme-text,#dcdedf);border-color:var(--lumen-theme-border,#3d4450);}",
      ".lumen-gu-search:focus,.lumen-cloud-search:focus,.lumen-theme-actions input[type=text]:focus,.lumen-row input[type=text]:focus,.lumen-row input[type=number]:focus,.lumen-row select:focus{border-color:var(--lumen-theme-accent,#1a9fff);}",
      ".lumen-game-name,.lumen-about-ver .nm,.lumen-about-act .at,.lumen-sub-title,.lumen-theme-option .lbl,.lumen-theme-applying{color:var(--lumen-theme-text,#dcdedf);}",
      ".lumen-game-sub,.lumen-ver .vgid,.lumen-empty,.lumen-about-intro,.lumen-about-ver .vv,.lumen-about-act .ad,.lumen-about-credit,.lumen-cloud-acct .fico,.lumen-theme-folder-action,.lumen-theme-range-value,.lumen-theme-installing,.lumen-theme-category-label,.lumen-theme-option-section{color:var(--lumen-theme-muted,#8f98a0);}",
      ".lumen-tab,.lumen-ctop .x,.lumen-ctop .reset,.lumen-back,.lumen-theme-action,.lumen-mbtn,.lumen-cloud-btn.secondary{color:var(--lumen-theme-muted,#aeb6bf);border-color:var(--lumen-theme-border,#3d4450);}",
      ".lumen-game,.lumen-about-ver,.lumen-ver,.lumen-cloud-acct{border-color:var(--lumen-theme-border,rgba(255,255,255,.08));}",
      ".lumen-game-head:hover,.lumen-ver:hover,.lumen-theme-action:hover,.lumen-cloud-acct:hover,.lumen-ctop .x:hover,.lumen-ctop .reset:hover,.lumen-back:hover{background:var(--lumen-theme-raised,rgba(255,255,255,.07));color:var(--lumen-theme-text,#fff);}",
      ".lumen-ver.sel,.lumen-cloud-acct,.lumen-theme-card.active,.lumen-sw .sl{background:var(--lumen-theme-raised,#3d4450);}",
      ".lumen-cap,.lumen-cloud-acctsel option{background:var(--lumen-theme-panel,#25282e);color:var(--lumen-theme-text,#dcdedf);}",
      ".lumen-sw .sl:before{background:var(--lumen-theme-text,#fff);}",
    ].join("");
    (document.head || document.documentElement).appendChild(s);
    applyAdaptivePalette();
  }
