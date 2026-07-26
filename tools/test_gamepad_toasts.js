// DOM-free contract test for lua/gamepad-toasts.js.
// Run: node tools/test_gamepad_toasts.js
const fs = require("fs");
const vm = require("vm");

function check(condition, message) {
  if (!condition) throw new Error(message);
  console.log("ok:   " + message);
}

const source = fs.readFileSync("lua/gamepad-toasts.js", "utf8");

function baseContext() {
  const timers = [];
  const context = {
    console,
    Symbol,
    Object,
    Number,
    Date,
    setInterval(fn) { timers.push(fn); return timers.length; },
    clearInterval() {},
  };
  context.window = context;
  return context;
}

// Decky coexistence: use its public toaster and do not touch NotificationStore.
{
  const context = baseContext();
  let got;
  context.__TOASTER_INSTANCE = { toast(event) { got = event; } };
  context.NotificationStore = { ProcessNotification() { throw new Error("must not use own renderer"); } };
  vm.runInNewContext(source, context);
  check(context.__lumenGamepadToast({ title: "SLS", body: "Ready", timeout_ms: 12345 }),
    "Decky path accepts a notification");
  check(got && got.title === "SLS" && got.body === "Ready" && got.duration === 12345,
    "Decky path preserves title, body and timeout");
}

// Standalone path: discover the Valve renderer from the webpack factory source,
// register through NotificationStore, and render only the Lumen-tagged group.
{
  const context = baseContext();
  const hooks = {
    useContext() {}, useCallback() {}, useLayoutEffect() {}, useEffect() {},
    useMemo() {}, useRef() {}, useState() {},
  };
  context.SP_REACT = {
    version: "19.1.1",
    __CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE: { hooks },
    createElement(type, props, ...children) {
      if (typeof type === "function") return type(Object.assign({}, props, { children }));
      return { type, props: Object.assign({}, props, { children }) };
    },
  };
  context.SP_REACTDOM = { version: "19.1.1" };
  context.SP_JSX = { jsx() {}, jsxs() {} };

  function ValveRenderer() { return { valve: true }; }
  ValveRenderer.toString = () => 'function(){return {controller:"notification",method:"render"}}';
  const factory = function () {};
  factory.toString = () => 'function(){controller:"notification",method:"render"}';
  function webpackRequire(id) {
    if (String(id) !== "42") throw new Error("unexpected module");
    return { ToastRenderer: ValveRenderer };
  }
  webpackRequire.m = { 42: factory };
  context.webpackChunksteamui = { push(tuple) { tuple[2](webpackRequire); } };

  let delivered;
  context.NotificationStore = {
    m_nNextTestNotificationID: 10000,
    ProcessNotification(info, event, operation) { delivered = { info, event, operation }; },
  };
  vm.runInNewContext(source, context);
  check(context.__lumenGamepadToast({ title: "SLS", body: "Gamepad", timeout_ms: 10000 }),
    "standalone path accepts a notification");
  check(delivered && delivered.event.lumen === true && delivered.event.eType === 31,
    "standalone path tags and submits the Steam notification");
  const tree = ValveRenderer.prototype.render.call({ props: {
    group: { notifications: [delivered.event] }, location: 1,
  } });
  check(JSON.stringify(tree).includes("SLS") && JSON.stringify(tree).includes("Gamepad"),
    "standalone renderer contains the notification text");
}

console.log("ALL PASS");
