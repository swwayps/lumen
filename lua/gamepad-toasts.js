// Lumen bridge for Steam's internal Gamepad UI notification system.
// Runs in SharedJSContext. Decky is optional: when its toaster is present we
// reuse it; otherwise a small renderer handles only notifications tagged by
// Lumen and leaves every Valve notification untouched.
(function () {
  "use strict";
  if (window.__lumenGamepadToast) return;

  var ownReady = false;
  var retrying = [];

  function deckyToast(event) {
    var toaster = window.__TOASTER_INSTANCE;
    if (!toaster || typeof toaster.toast !== "function") return false;
    try {
      toaster.toast({
        title: event.title,
        body: event.body,
        duration: event.timeout_ms,
        showNewIndicator: true,
        showToast: true,
        playSound: true,
        sound: 6
      });
      return true;
    } catch (e) {
      console.warn("[Lumen] Decky toast failed", e);
      return false;
    }
  }

  function internalHooks() {
    var react = window.SP_REACT;
    var legacy = react && react.__SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED;
    if (legacy && legacy.ReactCurrentDispatcher) {
      return legacy.ReactCurrentDispatcher.current;
    }
    var modern = react && react.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
    if (!modern) return null;
    return Object.values(modern).find(function (value) {
      return value && typeof value.useEffect === "function";
    }) || null;
  }

  // React keeps the Valve renderer by function reference, so replacing its
  // webpack export is not enough. This trampoline makes that same reference a
  // class component whose render delegates to a patchable function component.
  // The hook stubs are active only during React's synchronous class probe.
  function trampoline(component) {
    var react = window.SP_REACT;
    var reactDOM = window.SP_REACTDOM;
    var jsx = window.SP_JSX;
    var hooks = internalHooks();
    if (!component || !react || !reactDOM || !hooks) return null;
    var reactVersion = String(reactDOM.version || "");
    if (reactVersion.indexOf("18.") !== 0 && reactVersion.indexOf("19.") !== 0) return null;

    var user = { component: function () { return component.apply(this, arguments); } };
    component.prototype.render = function () {
      return react.createElement(user.component, this.props, this.props.children);
    };
    component.prototype.isReactComponent = true;

    var savedHooks;
    var savedCreate = react.createElement;
    var savedJsx = jsx && jsx.jsx;
    var savedJsxs = jsx && jsx.jsxs;
    var stubsApplied = false;
    var step = 0;
    var patchJsx = reactVersion.indexOf("19.") === 0;

    function applyStubs() {
      if (stubsApplied) return;
      stubsApplied = true;
      savedHooks = {
        useContext: hooks.useContext,
        useCallback: hooks.useCallback,
        useLayoutEffect: hooks.useLayoutEffect,
        useEffect: hooks.useEffect,
        useMemo: hooks.useMemo,
        useRef: hooks.useRef,
        useState: hooks.useState
      };
      hooks.useCallback = function (cb) { return cb; };
      hooks.useContext = function (ctx) { return ctx && ctx._currentValue; };
      hooks.useLayoutEffect = function () {};
      hooks.useEffect = function () {};
      hooks.useMemo = function (cb) { return cb(); };
      hooks.useRef = function (value) { return { current: value || {} }; };
      hooks.useState = function (value) {
        var current = value;
        return [current, function (next) { current = next; }];
      };
      react.createElement = function () { return Object.create(component.prototype); };
      if (patchJsx && jsx) {
        jsx.jsx = function () { return Object.create(component.prototype); };
        jsx.jsxs = function () { return Object.create(component.prototype); };
      }
    }

    function removeStubs() {
      if (!stubsApplied) return;
      stubsApplied = false;
      Object.assign(hooks, savedHooks);
      react.createElement = savedCreate;
      if (patchJsx && jsx) { jsx.jsx = savedJsx; jsx.jsxs = savedJsxs; }
    }

    if (patchJsx) {
      Object.defineProperty(component, "contextType", {
        configurable: true,
        get: function () {
          if (step === 0) step = 1;
          if (this._lumenContextType == null) this._lumenContextType = {};
          var ctx = this._lumenContextType;
          if (!ctx.__lumenCurrentValueHook) {
            ctx.__lumenCurrentValueHook = true;
            Object.defineProperty(ctx, "_currentValue", {
              configurable: true,
              get: function () {
                if (step === 1) { step = 2; applyStubs(); }
                return this.__lumenCurrentValue;
              },
              set: function (value) { this.__lumenCurrentValue = value; }
            });
          }
          return ctx;
        },
        set: function (value) { this._lumenContextType = value; }
      });
      Object.defineProperty(component.prototype, "updater", {
        configurable: true,
        get: function () { return this._lumenUpdater; },
        set: function (value) {
          if (step === 1 || step === 2) { step = 0; removeStubs(); }
          this._lumenUpdater = value;
        }
      });
      Object.defineProperty(component, "getDerivedStateFromProps", {
        configurable: true,
        get: function () {
          if (step === 1 || step === 2) { step = 0; removeStubs(); }
          return this._lumenDerivedState;
        },
        set: function (value) { this._lumenDerivedState = value; }
      });
    } else if (reactVersion.indexOf("18.") === 0) {
      Object.defineProperty(component, "contextType", {
        configurable: true,
        get: function () {
          if (step === 0) step = 1;
          else if (step === 3) step = 4;
          return this._lumenContextType;
        },
        set: function (value) { this._lumenContextType = value; }
      });
      Object.defineProperty(component, "contextTypes", {
        configurable: true,
        get: function () { if (step === 1) { step = 2; applyStubs(); } return this._lumenContextTypes; },
        set: function (value) { this._lumenContextTypes = value; }
      });
      Object.defineProperty(component.prototype, "updater", {
        configurable: true,
        get: function () { return this._lumenUpdater; },
        set: function (value) {
          if (step === 2) { step = 0; removeStubs(); }
          this._lumenUpdater = value;
        }
      });
      Object.defineProperty(component, "getDerivedStateFromProps", {
        configurable: true,
        get: function () { if (step === 2) { step = 0; removeStubs(); } return this._lumenDerivedState; },
        set: function (value) { this._lumenDerivedState = value; }
      });
    }
    return user;
  }

  function findValveRenderer() {
    var chunks = window.webpackChunksteamui;
    if (!chunks || typeof chunks.push !== "function") return null;
    var requireFn;
    chunks.push([[Symbol("lumen-toast")], {}, function (r) { requireFn = r; }]);
    if (!requireFn || !requireFn.m) return null;

    var ids = Object.keys(requireFn.m).filter(function (id) {
      try {
        return String(requireFn.m[id]).indexOf('controller:"notification",method:') !== -1;
      } catch (e) { return false; }
    });
    for (var i = 0; i < ids.length; i++) {
      var module;
      try { module = requireFn(ids[i]); } catch (e) { continue; }
      var roots = [module && module.default, module];
      for (var j = 0; j < roots.length; j++) {
        var root = roots[j];
        if (!root || typeof root !== "object" || root === window) continue;
        for (var key in root) {
          var value;
          try { value = root[key]; } catch (e) { continue; }
          if (typeof value === "function" &&
              String(value).indexOf('controller:"notification",method:') !== -1) {
            return value;
          }
        }
      }
    }
    return null;
  }

  function renderEvent(event, key) {
    var h = window.SP_REACT.createElement;
    return h("div", {
      key: key,
      style: { display: "flex", alignItems: "center", gap: "12px", width: "100%",
        minHeight: "64px", padding: "10px 14px", boxSizing: "border-box", color: "#f3f4f5" }
    },
      h("div", { style: { display: "flex", alignItems: "center", justifyContent: "center",
        width: "38px", height: "38px", flex: "0 0 38px", borderRadius: "50%",
        background: "#1a9fff", color: "#fff", fontSize: "25px", lineHeight: "38px" } }, "☾"),
      h("div", { style: { minWidth: 0, flex: "1 1 auto", lineHeight: "1.25" } },
        h("div", { style: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
          fontSize: "16px", fontWeight: 600 } }, event.title),
        h("div", { style: { marginTop: "3px", overflow: "hidden", textOverflow: "ellipsis",
          fontSize: "14px", color: "#dcdedf" } }, event.body)
      )
    );
  }

  function installOwnRenderer() {
    if (ownReady) return true;
    var renderer = findValveRenderer();
    // A loader is already changing this component. Give Decky time to expose
    // its public toaster instead of stacking incompatible trampolines.
    if (!renderer || (renderer.prototype && renderer.prototype.isReactComponent)) return false;
    var holder = trampoline(renderer);
    if (!holder) return false;
    var original = holder.component;
    holder.component = function (props) {
      var group = props && props.group;
      var notifications = group && group.notifications;
      var ours = notifications && notifications.filter(function (item) { return item && item.lumen; });
      if (!ours || !ours.length) return original.apply(this, arguments);
      return ours.map(function (item) {
        return renderEvent(item.data || {}, item.nNotificationID);
      });
    };
    Object.assign(holder.component, original);
    holder.component.toString = function () { return original.toString(); };
    ownReady = true;
    return true;
  }

  function sendOwn(event) {
    var store = window.NotificationStore;
    if (!store || typeof store.ProcessNotification !== "function" || !installOwnRenderer()) {
      return false;
    }
    var notification = {
      nNotificationID: store.m_nNextTestNotificationID++,
      bNewIndicator: true,
      rtCreated: Date.now(),
      eType: 31,
      eSource: 1,
      nToastDurationMS: event.timeout_ms,
      data: event,
      lumen: true
    };
    function addToTray(item, tray) {
      tray.unshift({ eType: item.eType, notifications: [item], lumen: true });
    }
    store.ProcessNotification({
      showToast: true,
      sound: 6,
      playSound: true,
      eFeature: 0,
      toastDurationMS: event.timeout_ms,
      bCritical: false,
      fnTray: addToTray
    }, notification, 0);
    return true;
  }

  function normalize(raw) {
    if (!raw || typeof raw !== "object") return null;
    if (typeof raw.title !== "string" || typeof raw.body !== "string") return null;
    var timeout = Number(raw.timeout_ms);
    if (!Number.isFinite(timeout)) timeout = 10000;
    timeout = Math.max(1000, Math.min(60000, Math.floor(timeout)));
    return { title: raw.title.slice(0, 256), body: raw.body.slice(0, 4096), timeout_ms: timeout };
  }

  window.__lumenGamepadToast = function (raw) {
    var event = normalize(raw);
    if (!event) return false;
    if (deckyToast(event) || sendOwn(event)) return true;

    // Decky and Steam initialize asynchronously. Retain a bounded retry rather
    // than dropping a notification during that short startup window.
    retrying.push(event);
    if (retrying.length === 1) {
      var attempts = 0;
      var timer = setInterval(function () {
        attempts++;
        retrying = retrying.filter(function (pending) {
          return !(deckyToast(pending) || sendOwn(pending));
        });
        if (!retrying.length || attempts >= 20) {
          retrying = [];
          clearInterval(timer);
        }
      }, 250);
    }
    return true;
  };
})();
