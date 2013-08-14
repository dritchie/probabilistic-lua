
local pr = require("probabilistic")
local util = require("probabilistic.util")
local random = require("probabilistic.random")
util.openpackage(pr)


-- Here, we test different transdimensional inference algorithms and
--    verify that they give the correct expected value for a simple distribution.


local dims = {2, 4}
local means = {-1.0, 0.5, -0.2, 0.7}
local sds = {0.1, 1.2, 0.5, 0.3}
local uniformPrior_min = -1.0
local uniformPrior_max = 1.0
-- local gaussianFactor_meanPriorMean = 0.0
-- local gaussianFactor_meanPriorSD = 2.0
-- local gaussianFactor_sdPriorMin = 0.1
-- local gaussianFactor_sdPriorMax = 2.0

local function generate()
	local dim = uniformDraw(dims, {isStructural=true})
	local accum = 0.0
	for i=1,dim do
		local mean = means[i]
		local sd = sds[i]
		local x = uniform({uniformPrior_min, uniformPrior_max})
		factor(random.gaussian_logprob(x, mean, sd))
		-- local x = gaussian({mean, sd})
		accum = accum + x
	end
	return accum
end



local groundTruthParams = 
{
	numsamps = 1000,
	lag = 10,
	runs = 5,
	burnin = 100,
	jumpFreq = 0.25
}
local testParams = 
{
	numsamps = 1000,
	lag = 10,
	runs = 5,
	burnin = 100,
	jumpFreq = 0.25
}

function estimateExpectation(name, computation, sampler, params)
	local estimates = replicate(params.runs, function() return expectation(computation, sampler, params) end)
	local est = util.sumtable(estimates) / #estimates
	print(string.format("%s: %g", name, est))
end

-- The following numbers (in comments) are all for the case where we have gaussian
-- priors and no factors.

-- I think the analytical ground truth is
--   (1/2)(-1.0 + 0.5) + (1/2)(-1.0 + 0.5 + -0.2 + 0.7)
--    = (1/2)(-0.5) + (1/2)(0)
--    = -0.25 

math.randomseed(os.time())

local verbose=false

print("GROUND TRUTH:\n---------------")

-- Plain old reversible jump MH estimates it around -0.238
estimateExpectation("RJMH", generate, LARJTraceMH, util.jointables(groundTruthParams, {verbose=verbose}))

print("\nESTIMATES:\n---------------")

-- Reversible jump LMC gives us about -0.236
--estimateExpectation("RJLMC", generate, LARJLMC, util.jointables(testParams, {verbose=verbose}))

-- LARJ LMC gives us about -0.26
estimateExpectation("LARJLMC", generate, LARJLMC, util.jointables(testParams, {annealIntervals=100, globalTempMult=0.99, verbose=verbose}))

-- T3 gives us about -0.263
--estimateExpectation("T3HMC", generate, T3HMC, util.jointables(testParams, {numT3Steps=100, T3StepSize=0.05, globalTempMult=0.99, verbose=verbose}))