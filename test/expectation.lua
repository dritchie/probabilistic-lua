
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
local targetSum = -0.25
local targetSumSD = 0.01

local function gaussianPrior()
	local dim = uniformDraw(dims, {isStructural=true})
	local accum = 0.0
	for i=1,dim do
		local mean = means[i]
		local sd = sds[i]
		local x = gaussian({mean, sd})
		accum = accum + x
	end
	return accum
end

local function uniformPriorGaussianFactor()
	local dim = uniformDraw(dims, {isStructural=true})
	local accum = 0.0
	for i=1,dim do
		local mean = means[i]
		local sd = sds[i]
		local x = uniform({uniformPrior_min, uniformPrior_max})
		factor(random.gaussian_logprob(x, mean, sd))
		accum = accum + x
	end
	return accum
end

local function uniformPriorTargetSumFactor()
	local dim = uniformDraw(dims, {isStructural=true})
	local accum = 0.0
	for i=1,dim do
		local x = uniform({uniformPrior_min, uniformPrior_max})
		accum = accum + x
	end
	local distFromTarget = accum - targetSum
	factor(-distFromTarget*distFromTarget/targetSumSD)
	return accum
end


-- Which test are we doing?
local generate = uniformPriorTargetSumFactor


local groundTruthParams = 
{
	numsamps = 1000,
	lag = 1,
	runs = 1,
	burnin = 100,
	jumpFreq = 0.25
}
local testParams = 
{
	numsamps = 1000,
	lag = 1,
	runs = 1,
	burnin = 100,
	jumpFreq = 0.25
}

function estimateExpectation(name, computation, sampler, params)
	local estimates = replicate(params.runs, function() return expectation(computation, sampler, params) end)
	local est = util.sumtable(estimates) / #estimates
	print(string.format("%s: %g", name, est))
end



math.randomseed(os.time())

local verbose=true

print("GROUND TRUTH:\n---------------")

--estimateExpectation("RJMH", generate, LARJTraceMH, util.jointables(groundTruthParams, {verbose=verbose}))


print("\nESTIMATES:\n---------------")

--estimateExpectation("RJLMC", generate, LARJLMC, util.jointables(testParams, {verbose=verbose}))

--estimateExpectation("LARJLMC", generate, LARJLMC, util.jointables(testParams, {annealIntervals=100, globalTempMult=0.99, verbose=verbose}))

estimateExpectation("T3HMC", generate, T3HMC, util.jointables(testParams, {numT3Steps=100, T3StepSize=0.005, globalTempMult=0.99, verbose=verbose}))






