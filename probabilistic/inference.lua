local trace = require "probabilistic.trace"
local util = require "util"

module(..., package.seeall)


-- Compute the discrete distribution over the given computation
-- Only appropriate for computations that return a discrete value
-- (Variadic arguments are arguments to the sampling function)
function distrib(computation, samplingFn, ...)
	local hist = {}
	local samps = samplingFn(computation, unpack(arg))
	for i,s in ipairs(samps) do
		local prevval = hist[s.sample] or 0
		hist[s.sample] = prevval + 1
	end
	local numsamps = table.getn(samps)
	for s,n in pairs(hist) do
		hist[s] = hist[s] / numsamps
	end
	return hist
end

-- Compute the mean of a set of values
function mean(values)
	local m = values[1]
	local n = table.getn(values)
	for i=2,n do
		m = m + values[i]
	end
	return m / n
end

-- Compute the expected value of a computation
-- Only appropraite for computations whose return value is a number or overloads + and /
function expectation(computation, samplingFn, ...)
	local samps = samplingFn(computation, unpack(arg))
	return mean(util.map(function(s) return s.sample end, samps))
end

-- -- Maximum a posteriori inference (returns the highest probability sample)
-- function MAP(computation, samplingFn, ...)
-- 	local samps = samplingFn(computation, unpack(arg))
-- 	local maxelem = 