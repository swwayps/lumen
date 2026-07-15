// LM-FRAGMENT Millennium-compatible Themes settings tab.

  var THEME_S = {
    en: {
      tab:"Themes", title:"Themes", enable:"Enable themes",
      enableDesc:"Themes are completely inactive until you enable this option.",
      js:"Allow theme JavaScript",
      jsDesc:"Allows themes to run JavaScript in the Steam interface. Disabling this option improves security, but some themes may be incomplete or not work correctly.",
      byId:"Install by ID", idDesc:"Find a theme in the Millennium theme gallery, copy its ID, and paste it below.",
      gallery:"Open Millennium theme gallery", id:"Theme ID", find:"Find theme",
      install:"Download and install", browseFolder:"Browse themes folder", installed:"Installed themes",
      use:"Use", active:"Active", remove:"Remove", steamDefault:"Default Steam theme",
      update:"Update", customize:"Customize", customizeDesc:"Options provided by this theme.",
      apply:"Apply changes", applyHint:"Changes take effect after the Steam interface reloads.",
      category:"Category", general:"General", themeColors:"Theme colors",
      loading:"Loading themes…", none:"No themes installed yet.", error:"Theme operation failed: ",
      confirm:"Install", cancel:"Cancel", downloading:"Downloading and installing…", reload:"Applying theme…"
    },
    pt: {
      tab:"Temas", title:"Temas", enable:"Ativar temas",
      enableDesc:"Os temas ficam completamente inativos enquanto esta opção estiver desligada.",
      js:"Permitir JavaScript dos temas",
      jsDesc:"Permite que os temas executem JavaScript na interface da Steam. Desativar esta opção aumenta a segurança, mas alguns temas podem ficar incompletos ou não funcionar corretamente.",
      byId:"Instalar por ID", idDesc:"Encontre um tema na galeria de temas do Millennium, copie o ID e cole abaixo.",
      gallery:"Abrir galeria de temas do Millennium", id:"ID do tema", find:"Buscar tema",
      install:"Baixar e instalar", browseFolder:"Abrir pasta de temas", installed:"Temas instalados",
      use:"Usar", active:"Ativo", remove:"Remover", steamDefault:"Tema padrão da Steam",
      update:"Atualizar", customize:"Personalizar", customizeDesc:"Opções fornecidas por este tema.",
      apply:"Aplicar alterações", applyHint:"As alterações entram em vigor após recarregar a interface da Steam.",
      category:"Categoria", general:"Geral", themeColors:"Cores do tema",
      loading:"Carregando temas…", none:"Nenhum tema instalado ainda.", error:"Falha na operação do tema: ",
      confirm:"Instalar", cancel:"Cancelar", downloading:"Baixando e instalando…", reload:"Aplicando tema…"
    }
  };
  function themeStrings(){ return THEME_S[pickLang()] || THEME_S.en; }

  function themeButton(label, click, secondary) {
    var b=document.createElement("div"); b.className="lumen-cloud-btn"+(secondary?" secondary":"");
    b.textContent=label; b.addEventListener("click",click); return b;
  }
  function themeAction(label, click, kind) {
    var b=document.createElement("button");b.type="button";
    b.className="lumen-theme-action"+(kind?" "+kind:"");b.textContent=label;
    b.addEventListener("click",click);return b;
  }
  function themeToggle(label, desc, checked, change) {
    var row=document.createElement("div"); row.className="lumen-row";
    var wrap=document.createElement("div"); wrap.className="lumen-lblwrap";
    var l=document.createElement("div"); l.className="lbl"; l.textContent=label;
    var d=document.createElement("div"); d.className="lumen-desc"; d.textContent=desc;
    wrap.appendChild(l);wrap.appendChild(d);row.appendChild(wrap);
    var sw=document.createElement("label");sw.className="lumen-sw";
    var input=document.createElement("input");input.type="checkbox";input.checked=checked;
    var sl=document.createElement("span");sl.className="sl";sw.appendChild(input);sw.appendChild(sl);row.appendChild(sw);
    input.addEventListener("change",function(){change(input.checked)}); return row;
  }
  function parseThemeReply(raw){var r=JSON.parse(raw);if(!r.success)throw new Error(r.error||"unknown error");return r}
  // rpc.dispatch maps object keys to positional arguments. Theme endpoints use
  // one JSON argument so optional fields survive without positional ambiguity.
  function themeCall(fn,args){return call(fn,{json:JSON.stringify(args||{})})}
  function themeError(body,e){var n=document.createElement("div");n.className="lumen-err";n.textContent=themeStrings().error+(e&&e.message?e.message:e);body.appendChild(n)}
  function showThemeApplying(body){
    var overlay=document.getElementById(OVERLAY_ID),S=themeStrings();
    if(overlay)overlay.classList.add("lumen-theme-busy");
    body.textContent="";
    var busy=document.createElement("div");busy.className="lumen-theme-applying";
    var spin=document.createElement("span");spin.className="lumen-spin";
    var text=document.createElement("span");text.textContent=S.reload;
    busy.appendChild(spin);busy.appendChild(text);body.appendChild(busy);
  }
  function clearThemeApplying(){
    var overlay=document.getElementById(OVERLAY_ID);
    if(overlay)overlay.classList.remove("lumen-theme-busy");
  }
  function themeInstallModal(theme,id,body,refresh){
    var S=themeStrings(),back=document.createElement("div");back.className="lumen-modal-back";
    var modal=document.createElement("div");modal.className="lumen-modal";
    var title=document.createElement("div");title.className="mt";title.textContent=theme.name;
    var desc=document.createElement("div");desc.className="mb";desc.style.whiteSpace="pre-wrap";
    desc.textContent=(theme.author?"By "+theme.author+"\n\n":"")+(theme.description||"");
    var row=document.createElement("div");row.className="mrow";
    var cancel=document.createElement("div");cancel.className="lumen-mbtn";cancel.textContent=S.cancel;
    var install=document.createElement("div");install.className="lumen-mbtn primary";install.textContent=S.install;
    function close(){if(back.parentNode)back.remove()}
    cancel.addEventListener("click",close);back.addEventListener("click",function(e){if(e.target===back)close()});
    install.addEventListener("click",function(){
      row.textContent="";var busy=document.createElement("div");busy.className="lumen-theme-installing";
      var spin=document.createElement("span");spin.className="lumen-spin";
      var text=document.createElement("span");text.textContent=S.downloading;
      busy.appendChild(spin);busy.appendChild(text);row.appendChild(busy);
      themeCall("LumenThemesInstallId",{id:id}).then(parseThemeReply).then(function(){close();refresh()}).catch(function(e){close();themeError(body,e)});
    });
    row.appendChild(cancel);row.appendChild(install);modal.appendChild(title);modal.appendChild(desc);modal.appendChild(row);back.appendChild(modal);
    (document.body||document.documentElement).appendChild(back);
  }
  function applyThemeConfig(patch, body) {
    var transaction=Object.assign({},patch,{reload:true});
    try{sessionStorage.setItem("lumen-return-tab","themes")}catch(e){}
    showThemeApplying(body);
    return themeCall("LumenThemesSetConfig",transaction).then(parseThemeReply).then(function(){
      return call("__lumenRestartJSContext",{});
    }).catch(function(e){
      clearThemeApplying();body.textContent="";themeError(body,e);
    });
  }

  function renderThemes(body) {
    var S=themeStrings(); body.textContent=S.loading;
    themeCall("LumenThemesStatus",{}).then(parseThemeReply).then(function(state){
      body.textContent=""; var cfg=state.config||{};
      function refresh(){renderThemes(body)}
      body.appendChild(themeToggle(S.enable,S.enableDesc,!!cfg.enabled,function(on){
        if(cfg.active){applyThemeConfig({enabled:on},body).catch(function(e){themeError(body,e)})}
        else themeCall("LumenThemesSetConfig",{enabled:on}).then(parseThemeReply).then(refresh).catch(function(e){themeError(body,e)});
      }));
      if(!cfg.enabled)return;
      body.appendChild(themeToggle(S.js,S.jsDesc,cfg.allow_javascript!==false,function(on){
        applyThemeConfig({allow_javascript:on},body).catch(function(e){themeError(body,e)});
      }));

      var sec=document.createElement("div");sec.className="lumen-theme-section";
      var h=document.createElement("div");h.className="lumen-theme-head";h.textContent=S.byId;sec.appendChild(h);
      var desc=document.createElement("div");desc.className="lumen-note";desc.textContent=S.idDesc;sec.appendChild(desc);
      var link=document.createElement("a");link.className="lumen-theme-link";link.textContent=S.gallery;
      link.addEventListener("click",function(){call("__lumenOpenExternalUrl",{url:"https://steambrew.app/themes"})});sec.appendChild(link);
      var ir=document.createElement("div");ir.className="lumen-theme-actions";
      var input=document.createElement("input");input.type="text";input.maxLength=20;input.placeholder=S.id;ir.appendChild(input);
      ir.appendChild(themeButton(S.find,function(){
        themeCall("LumenThemesLookup",{id:input.value.trim()}).then(parseThemeReply).then(function(res){
          themeInstallModal(res.theme,input.value.trim(),body,refresh);
        }).catch(function(e){themeError(body,e)});
      }));sec.appendChild(ir);body.appendChild(sec);

      var listHead=document.createElement("div");listHead.className="lumen-theme-list-head";
      var ih=document.createElement("div");ih.className="lumen-theme-head";ih.textContent=S.installed;listHead.appendChild(ih);
      listHead.appendChild(themeAction(S.browseFolder,function(){themeCall("LumenThemesOpenFolder",{}).catch(function(e){themeError(body,e)})},"lumen-theme-folder-action"));
      body.appendChild(listHead);

      var themeList=document.createElement("div");themeList.className="lumen-theme-list";body.appendChild(themeList);
      function appendThemeCard(theme, isDefault) {
        var active=isDefault?!cfg.active:cfg.active===theme.native;
        var card=document.createElement("div");card.className="lumen-theme-card"+(active?" active":"");
        var meta=document.createElement("div");meta.className="lumen-theme-meta";
        var titleRow=document.createElement("div");titleRow.className="lumen-theme-title-row";
        var name=document.createElement("div");name.className="name";
        name.textContent=isDefault?S.steamDefault:theme.name+(theme.version?" v"+theme.version:"");titleRow.appendChild(name);
        if(active){var status=document.createElement("span");status.className="lumen-theme-status";status.textContent=S.active;titleRow.appendChild(status)}
        meta.appendChild(titleRow);
        if(!isDefault&&theme.author){var author=document.createElement("div");author.className="author";author.textContent="By "+theme.author;meta.appendChild(author)}
        if(!isDefault&&theme.description){var description=document.createElement("div");description.className="description";description.textContent=theme.description;meta.appendChild(description)}
        card.appendChild(meta);
        var actions=document.createElement("div");actions.className="lumen-theme-card-actions";
        if(!active){actions.appendChild(themeAction(S.use,function(){applyThemeConfig({active:isDefault?false:theme.native},body).catch(function(e){themeError(body,e)})},"primary"))}
        if(!isDefault&&theme.updateable){actions.appendChild(themeAction(S.update,function(){themeCall("LumenThemesUpdate",{native:theme.native}).then(parseThemeReply).then(function(){if(active)return applyThemeConfig({},body);refresh()}).catch(function(e){themeError(body,e)})},"neutral"))}
        if(!isDefault){actions.appendChild(themeAction(S.remove,function(){themeCall("LumenThemesRemove",{native:theme.native}).then(parseThemeReply).then(refresh).catch(function(e){themeError(body,e)})},"danger"))}
        card.appendChild(actions);themeList.appendChild(card);
      }
      appendThemeCard({},true);
      (state.themes||[]).forEach(function(t){
        appendThemeCard(t,false);
      });
      var activeTheme=(state.themes||[]).filter(function(t){return t.native===cfg.active})[0];
      if(activeTheme&&activeTheme.configurable){
        var prefs=JSON.parse(JSON.stringify((cfg.preferences&&cfg.preferences[cfg.active])||{}));
        var groups=[],groupMap={};
        function groupFor(key,label){
          if(!groupMap[key]){groupMap[key]={key:key,label:label,conditions:[],colors:[]};groups.push(groupMap[key])}
          return groupMap[key];
        }
        (activeTheme.conditions||[]).forEach(function(c){
          if(prefs[c.name]===undefined)prefs[c.name]=c.default;
          var tab=typeof c.tab==="string"&&c.tab.trim()?c.tab.trim():S.general;
          groupFor("tab:"+tab,tab).conditions.push(c);
        });
        if((activeTheme.root_colors||[]).length){
          prefs.__rootcolors=prefs.__rootcolors||{};
          (activeTheme.root_colors||[]).forEach(function(c){
            if(prefs.__rootcolors[c.name]===undefined)prefs.__rootcolors[c.name]=c.default;
            groupFor("root-colors",S.themeColors).colors.push(c);
          });
        }
        if(groups.length){
          var customize=document.createElement("section");customize.className="lumen-theme-customize";
          var customHead=document.createElement("div");customHead.className="lumen-theme-customize-head";
          var customTitle=document.createElement("div");customTitle.className="lumen-theme-head";customTitle.textContent=S.customize+" "+activeTheme.name;customHead.appendChild(customTitle);
          var customDesc=document.createElement("div");customDesc.className="lumen-note";customDesc.textContent=S.customizeDesc;customHead.appendChild(customDesc);customize.appendChild(customHead);
          var fields=document.createElement("div");fields.className="lumen-theme-customize-fields";
          var applyButton,initialPrefs=JSON.stringify(prefs);
          function updateDirty(){if(applyButton)applyButton.disabled=JSON.stringify(prefs)===initialPrefs}
          function optionRow(c){
            var row=document.createElement("div");row.className="lumen-theme-option";var wrap=document.createElement("div");wrap.className="lumen-lblwrap";
            var l=document.createElement("div");l.className="lbl";l.textContent=c.name;wrap.appendChild(l);
            if(c.description){var d=document.createElement("div");d.className="lumen-desc";d.textContent=c.description;wrap.appendChild(d)}row.appendChild(wrap);
            var control=document.createElement("div");control.className="lumen-theme-option-control";
            if(c.slider){var range=document.createElement("input");range.className="lumen-theme-range";range.type="range";range.min=c.slider.min;range.max=c.slider.max;range.step=c.slider.step||1;range.value=prefs[c.name];
              var value=document.createElement("span");value.className="lumen-theme-range-value";value.textContent=range.value+(c.slider.unit||"");
              range.addEventListener("input",function(){prefs[c.name]=Number(range.value);value.textContent=range.value+(c.slider.unit||"");updateDirty()});control.appendChild(range);control.appendChild(value);
            }else{var sel=document.createElement("select");sel.className="lumen-theme-select";(c.values||[]).forEach(function(v){var o=document.createElement("option");o.value=v;o.textContent=v;sel.appendChild(o)});
              sel.value=prefs[c.name];sel.addEventListener("change",function(){prefs[c.name]=sel.value;updateDirty()});control.appendChild(sel)}row.appendChild(control);fields.appendChild(row);
          }
          function colorRow(c){
            var row=document.createElement("div");row.className="lumen-theme-option";var l=document.createElement("div");l.className="lbl";l.textContent=c.name;row.appendChild(l);
            var control=document.createElement("div");control.className="lumen-theme-option-control";
            var input=document.createElement("input");input.className="lumen-theme-color";input.type=/^#[0-9a-f]{6}$/i.test(c.default)?"color":"text";input.value=prefs.__rootcolors[c.name];
            input.addEventListener("change",function(){prefs.__rootcolors[c.name]=input.value;updateDirty()});control.appendChild(input);row.appendChild(control);fields.appendChild(row);
          }
          function renderGroup(key){
            fields.textContent="";var group=groupMap[key]||groups[0],lastSection;
            group.conditions.forEach(function(c){
              var section=typeof c.section==="string"&&c.section.trim()?c.section.trim():"";
              if(section&&section!==S.general&&section!==lastSection){var sh=document.createElement("div");sh.className="lumen-theme-option-section";sh.textContent=section;fields.appendChild(sh)}
              lastSection=section;optionRow(c);
            });
            group.colors.forEach(colorRow);
          }
          if(groups.length>1){
            var categoryBar=document.createElement("div");categoryBar.className="lumen-theme-category-bar";
            var categoryLabel=document.createElement("label");categoryLabel.className="lumen-theme-category-label";categoryLabel.textContent=S.category;categoryBar.appendChild(categoryLabel);
            var category=document.createElement("select");category.className="lumen-theme-category";
            groups.forEach(function(group){var o=document.createElement("option");o.value=group.key;o.textContent=group.label;category.appendChild(o)});
            category.value=groups[0].key;category.addEventListener("change",function(){renderGroup(category.value)});categoryBar.appendChild(category);customize.appendChild(categoryBar);
          }
          customize.appendChild(fields);renderGroup(groups[0].key);
          var footer=document.createElement("div");footer.className="lumen-theme-customize-footer";
          var hint=document.createElement("div");hint.className="lumen-note";hint.textContent=S.applyHint;footer.appendChild(hint);
          applyButton=themeAction(S.apply,function(){applyThemeConfig({preferences:prefs},body).catch(function(e){themeError(body,e)})},"primary");applyButton.disabled=true;footer.appendChild(applyButton);
          customize.appendChild(footer);body.appendChild(customize);
        }
      }
      if(!(state.themes||[]).length){var empty=document.createElement("div");empty.className="lumen-empty";empty.textContent=S.none;themeList.appendChild(empty)}
    }).catch(function(e){body.textContent="";themeError(body,e)});
  }
