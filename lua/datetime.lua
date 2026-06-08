-- datetime shim: replaces Millennium's native datetime module. The backend
-- uses datetime.unix() to get the current unix timestamp.
local datetime = {}

function datetime.unix()
  return os.time()
end

return datetime
