// LM-FRAGMENT slsteam-moon settings tab (makeRow, renderConfig)
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

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
      var hasMin = typeof entry.min === "number";
      var hasMax = typeof entry.max === "number";
      if (hasMin) ni.min = String(entry.min);
      if (hasMax) ni.max = String(entry.max);
      var clampInt = function (n) {
        n = Math.floor(Number(n) || 0);
        if (hasMin && n < entry.min) n = entry.min;
        if (hasMax && n > entry.max) n = entry.max;
        return n;
      };
      ni.value = String(clampInt(value != null ? value : 0));
      ni.addEventListener("change", function () {
        var v = clampInt(ni.value);
        ni.value = String(v); // reflect the clamp back into the box
        onChange(v);
      });
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
      if (entry.hidden) return; // deprecated/no-op keys are parsed but not shown
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
