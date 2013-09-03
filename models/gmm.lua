local pr = require("probabilistic")
local util = require("probabilistic.util")
util.openpackage(pr)

local random = require("probabilistic.random")

-- Version of uniform ERP that doesn't actually contribute to the
-- the log probability, so that we can do inference on distributions
-- that don't actually have 'priors'
local uniformNoLP =
makeERP(random.uniform_sample,
		function() return 0.0 end,
		function(currval, ...) return random.uniform_sample(...) end,
		function(currval, propval, ...) return random.uniform_logprob(propval, ...) end)

--------------------------------

-- Simple test of a multimodal gaussian mixture using
-- a single global temperature.
-- In general, the 'temp' parameter could be a vector of temps.
local uniformPriorMin = -7
local uniformPriorMax = 7
local mixtureWeights = {0.2, 0.5, 0.3}
local means = {-5.3, 0.5, 6.9}
local sds = {0.3, 0.1, 0.5}
--local sds = {4.0, 4.0, 4.0}
local function gmm(temp)
	temp = temp or 1.0
	local x = uniformNoLP({uniformPriorMin, uniformPriorMax})
	local ftor = 0.0
	for i,w in ipairs(mixtureWeights) do
		ftor = ftor + w*math.exp(random.gaussian_logprob(x, means[i], sds[i]))
	end
	factor(temp*math.log(ftor))
	return x
end

local function scheduleGen_gmm(annealStep, numAnnealSteps)
	local a = annealStep/numAnnealSteps
	--local val = 2.0*math.abs(a - 0.5)
	local val = (2.0*a - 1); val = val*val
	return val
end

return
{
	gmm = gmm,
	scheduleGen_gmm = scheduleGen_gmm
}