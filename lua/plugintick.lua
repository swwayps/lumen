local plugintick = {}

function plugintick.new(lifecycle, opts)
  opts = opts or {}
  local instance = {
    lifecycle = lifecycle,
    interval = math.max(1, tonumber(opts.interval) or 5),
    active_interval = math.max(1, tonumber(opts.active_interval) or 1),
    next_run = 0,
  }

  function instance:run(now, injector)
    now = tonumber(now) or 0
    if type(self.lifecycle) ~= "table"
        or type(self.lifecycle.on_tick) ~= "function" then return nil end
    if now < self.next_run then return nil end
    self.next_run = now + self.interval
    local controls = {
      set_launch_options = function(appid, options)
        if type(injector) ~= "table"
            or type(injector.set_launch_options) ~= "function" then return false end
        local ok, result = pcall(injector.set_launch_options,
          injector, appid, options)
        return ok and result == true
      end,
      is_app_busy = function(appid)
        if type(injector) ~= "table"
            or type(injector.is_app_busy) ~= "function" then return false end
        local ok, result = pcall(injector.is_app_busy, injector, appid)
        return ok and result == true
      end,
    }
    local ok, result = pcall(self.lifecycle.on_tick, now, controls)
    if not ok then return { success = false, error = tostring(result) } end
    if type(result) == "table" and type(result.jobs) == "table"
        and type(injector) == "table" then
      local blocking = {}
      for appid, job in pairs(result.jobs) do
        local phase = type(job) == "table" and job.phase or nil
        if phase == "waiting_install" or phase == "needs_login" or phase == "applying"
            or phase == "finalizing" then
          blocking[tostring(appid)] = { phase = phase, blocking = true }
        elseif phase == "failed" then
          blocking[tostring(appid)] = { phase = phase, cancel = true }
        end
      end
      if type(injector.update_auto_fix_guard) == "function" then
        pcall(injector.update_auto_fix_guard, injector, blocking)
      end
      if type(injector.update_auto_fix_ui) == "function" then
        pcall(injector.update_auto_fix_ui, injector,
          type(result.uiJobs) == "table" and result.uiJobs or {})
      end
      for _, job in pairs(type(result.uiJobs) == "table" and result.uiJobs or {}) do
        if type(job) == "table"
            and (job.phase == "applying" or job.phase == "finalizing") then
          self.next_run = now + self.active_interval
          break
        end
      end
    end
    return result
  end

  return instance
end

return plugintick
