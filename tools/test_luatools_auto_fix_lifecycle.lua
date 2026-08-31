local plugintick = require("plugintick")

local failures = 0
local function check(name, condition)
  if condition then print("ok   " .. name)
  else print("FAIL " .. name); failures = failures + 1 end
end

local calls, relays = 0, 0
local lifecycle = {
  on_tick = function(now, controls)
    calls = calls + 1
    local ok = controls.set_launch_options(3321460,
      'WINEDLLOVERRIDES="steam_api64=n,b" %command%')
    return { success = ok, now = now }
  end,
}
local injector = {
  set_launch_options = function(_, appid, options)
    relays = relays + 1
    return appid == 3321460 and options:find("WINEDLLOVERRIDES", 1, true) ~= nil
  end,
}
local runner = plugintick.new(lifecycle, { interval = 5 })
check("L1 first due tick reaches the plugin lifecycle",
  runner:run(10, injector).success == true and calls == 1 and relays == 1)
check("L2 sub-interval loop ticks do not poll persistent jobs",
  runner:run(12, injector) == nil and calls == 1)
check("L3 the next multi-second deadline runs exactly once",
  runner:run(15, injector).success == true and calls == 2 and relays == 2)

local absent = plugintick.new(nil, { interval = 5 })
check("L4 settings-only Lumen has no plugin lifecycle work",
  absent:run(20, injector) == nil)

local failing = plugintick.new({ on_tick = function() error("boom") end },
  { interval = 5 })
local failed = failing:run(20, injector)
check("L5 a plugin tick failure is isolated from Lumen's loop",
  failed.success == false and failed.error:find("boom", 1, true) ~= nil)

local unavailable = plugintick.new(lifecycle, { interval = 5 })
local no_control = unavailable:run(20, {})
check("L6 missing SharedJS control reports false instead of throwing",
  no_control.success == false)

local guard_updates, ui_updates = 0, 0
local guard_snapshot, ui_snapshot
local guarded = plugintick.new({
  on_tick = function(_, controls)
    return {
      success = controls.is_app_busy(3321460) == true,
      jobs = {
        ["3321460"] = { phase = "waiting_install" },
        ["990080"] = { phase = "failed" },
        ["480"] = { phase = "cancelling", transaction = "txn.current" },
        ["481"] = { phase = "failed", fixStarted = true },
      },
      uiJobs = {
        ["3321460"] = {
          appid = 3321460, phase = "applying", stage = "downloading",
          gameName = "Crimson Desert", progress = 42,
        },
      },
    }
  end,
}, { interval = 5 })
local guard_injector = {
  is_app_busy = function(_, appid) return appid == 3321460 end,
  update_auto_fix_guard = function(_, jobs)
    guard_updates = guard_updates + 1
    guard_snapshot = jobs
    return true
  end,
  update_auto_fix_ui = function(_, jobs)
    ui_updates = ui_updates + 1
    ui_snapshot = jobs
    return true
  end,
}
local guarded_result = guarded:run(30, guard_injector)
check("L7 the lifecycle can reject Steam post-install activity",
  guarded_result.success == true)
check("L8 only cancellable automatic work reaches the guard",
  guard_updates == 1 and type(guard_snapshot["3321460"]) == "table"
    and guard_snapshot["3321460"].cancelOnPlay == true
    and guard_snapshot["3321460"].rollback ~= true
    and guard_snapshot["480"].cancelOnPlay == true
    and guard_snapshot["480"].rollback == true
    and guard_snapshot["481"].cancelOnPlay == true
    and guard_snapshot["481"].rollback == true
    and guard_snapshot["990080"] == nil)
check("L9 compact progress reaches the visible Lumen UI",
  ui_updates == 1 and type(ui_snapshot) == "table"
    and type(ui_snapshot["3321460"]) == "table"
    and ui_snapshot["3321460"].progress == 42
    and ui_snapshot["3321460"].gameName == "Crimson Desert")
check("L10 active work uses a short cancellation cadence without idle overhead",
  guarded:run(30.2, guard_injector) == nil
    and guarded:run(30.25, guard_injector) ~= nil)

local failed_cleanup = plugintick.new({
  on_tick = function()
    return {
      success = true,
      jobs = { ["480"] = { phase = "failed", fixStarted = true } },
      uiJobs = { ["480"] = { phase = "failed" } },
    }
  end,
}, { interval = 5 })
check("L11 unresolved side effects keep the bounded cancellation cadence",
  failed_cleanup:run(40, guard_injector) ~= nil
    and failed_cleanup:run(40.2, guard_injector) == nil
    and failed_cleanup:run(40.25, guard_injector) ~= nil)

if failures > 0 then os.exit(1) end
print("ALL LUA.TOOLS AUTO FIX LIFECYCLE CHECKS PASSED")
