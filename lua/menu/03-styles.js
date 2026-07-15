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
      "#" + BTN_ID + "{display:inline-flex;align-items:center;justify-content:center;",
      "cursor:pointer;font-size:13px;line-height:1;padding:2px 8px;margin:0 2px;",
      "opacity:.8;-webkit-app-region:no-drag;user-select:none;border-radius:3px;}",
      "#" + BTN_ID + ":hover{opacity:1;background:rgba(255,255,255,.08);}",
      "#lumen-access-layer{position:fixed!important;inset:0!important;",
      "z-index:2147483646!important;pointer-events:none!important;isolation:isolate!important;",
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
      "#" + OVERLAY_ID + "{position:fixed;inset:0;z-index:2147483647;display:flex;",
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
      ".lumen-gu-actions{display:flex;justify-content:flex-end;margin:0 0 12px;}",
      ".lumen-load-lua{font-size:13px;}",
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
      ".lumen-badge.err{background:#4a1a1a;color:#ff6f6f;display:inline-flex;align-items:center;vertical-align:middle;}",
      ".lumen-badge.err .info{display:inline-flex;margin-left:4px;width:11px;height:11px;",
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
      "padding:4px 9px;transition:background .15s ease-out,color .15s ease-out;}",
      ".lumen-channel-option:hover{color:var(--lumen-theme-text,#dcdedf);",
      "background:var(--lumen-theme-raised,rgba(255,255,255,.06));}",
      ".lumen-channel-option.active{color:#fff;background:var(--lumen-theme-accent,#1a9fff);}",
      ".lumen-channel-option:focus-visible{outline:2px solid var(--lumen-theme-accent,#66c0f4);outline-offset:2px;}",
      ".lumen-channel.busy{opacity:.65;}",
      ".lumen-channel.busy .lumen-channel-option{cursor:wait;pointer-events:none;}",
      ".lumen-channel-error{margin-top:4px;color:#ec5c5c;font-size:11px;line-height:1.35;}",
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
      ".lumen-about-btn{flex:0 0 auto;cursor:pointer;font-size:13px;font-weight:600;",
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
      ".lumen-capsule-badge.b-synced{background:#15321f;color:#6fd08c;}",
      ".lumen-capsule-badge.b-checking{background:#2b303a;color:#8f98a0;}",
      ".lumen-capsule-badge .lumen-spin{width:11px;height:11px;border-width:2px;}",
      // loading spinner (version line + state pill while versions are fetched)
      ".lumen-spin{display:inline-block;width:14px;height:14px;box-sizing:border-box;",
      "border:2px solid rgba(255,255,255,.16);border-top-color:#9aa3ab;border-radius:50%;",
      "animation:lumen-rot .7s linear infinite;vertical-align:middle;}",
      "@keyframes lumen-rot{to{transform:rotate(360deg);}}",
      // confirm modal (validate prompt) — sits above the settings overlay
      ".lumen-modal-back{position:fixed;inset:0;z-index:100000;display:flex;",
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
