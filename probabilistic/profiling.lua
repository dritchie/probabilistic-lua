
local util = require("probabilistic.util")

local profilingEnabled = false
local timers = {}

local function toggleProfiling(flag)
	profilingEnabled = flag
end

local function profilingIsEnabled()
	return profilingEnabled
end

local function startTimer(name, excludeFromTotal)
	if profilingEnabled then
		local timer = timers[name]
		if not timer then
			timer = util.Timer:new()
			timers[name] = timer
		end
		timer.excludeFromTotal = excludeFromTotal
		timer:start()
	end
end

local function stopTimer(name)
	if profilingEnabled then
		local timer = timers[name]
		if not timer then
			error("Attempted to stop a timer that does not exist!")
		end
		timer:stop()
	end
end

local function getTimingProfile()
	local timings = util.map(function(timer) return timer:getElapsedTime() end, timers)
	local total = 0
	for name,timer in pairs(timers) do
		if not timer.excludeFromTotal then
			total = total + timer:getElapsedTime()
		end
	end
	timings["TOTAL"] = total
	return timings
end

return
{
	toggleProfiling = toggleProfiling,
	profilingIsEnabled = profilingIsEnabled,
	startTimer = startTimer,
	stopTimer = stopTimer,
	getTimingProfile = getTimingProfile
}