local trace = require "probabilistic.trace"
local util = require "util"

module(..., package.seeall)


-- Compute the discrete distribution over the given computation
-- Only appropriate for computations that return a discrete value
-- (Variadic arguments are arguments to the sampling function)
function distrib(computation, samplingFn, ...)
	local hist = {}
	local samps = samplingFn(computation, ...)
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
	local samps = samplingFn(computation, ...)
	return mean(util.map(function(s) return s.sample end, samps))
end

-- Maximum a posteriori inference (returns the highest probability sample)
function MAP(computation, samplingFn, ...)
	local samps = samplingFn(computation, ...)
	local maxelem = {sample = nil, logprob = -math.huge}
	for i,s in ipairs(samps) do
		if s.logprob > maxelem.logprob then
			maxelem = s
		end
	end
	return maxelem.sample
end

-- Rejection sample a result from computation that satisfies all
-- conditioning expressions
function rejectionSample(computation)
	local tr = trace.newTrace(computation)
	return tr.returnValue
end


-- MCMC transition kernel that takes random walks by tweaking a
-- single variable at a time
local RandomWalkKernel = {}

function RandomWalkKernel:new(structural, nonstructural)
	structural = (structural == nil) and true or structural
	nonstructural = (nonstructural == nil) and true or structural
	local newobj = {
		structural = structural,
		nonstructural = nonstructural,
		proposalsMade = 0,
		proposalsAccepted = 0
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function RandomWalkKernel:next(currTrace)
	self.proposalsMade = self.proposalsMade + 1
	local name = util.randomChoice(currTrace:freeVarNames(self.structural, self.nonstructural))

	-- If we have no free random variables, then just run the computation
	-- and generate another sample (this may not actually be deterministic,
	-- in the case of nested query)
	if not name then
		currTrace:traceUpdate()
		return currTrace
	-- Otherwise, make a proposal for a randomly-chosen variable, probabilistically
	-- accept it
	else
		local nextTrace, fwdPropLP, rvsPropLP = currTrace:proposeChange(name)
		fwdPropLP = fwdPropLP - math.log(table.getn(currTrace:freeVarNames(self.structural, self.nonstructural)))
		rvsPropLP = rvsPropLP - math.log(table.getn(nextTrace:freeVarNames(self.structural, self.nonstructural)))
		local acceptThresh = nextTrace.logprob - currTrace.logprob + rvsPropLP - fwdPropLP
		if nextTrace.conditionsSatisfied and math.log(math.random()) < acceptThresh then
			self.proposalsAccepted = self.proposalsAccepted + 1
			return nextTrace
		else
			return currTrace
		end
	end
end

function RandomWalkKernel:stats()
	print(string.format("Acceptance ratio: %g (%u/%u)", self.proposalsAccepted/self.proposalsMade,
														self.proposalsAccepted, self.proposalsMade))
end


-- Do MCMC for 'numsamps' iterations using a given transition kernel
function mcmc(computation, kernel, numsamps, lag, verbose)
	lag = (lag == nil) and 1 or lag
	local currentTrace = trace.newTrace(computation)
	local samps = {}
	local iters = numsamps * lag
	for i=1,iters do
		currentTrace = kernel:next(currentTrace)
		if i % lag == 0 then
			table.insert(samps, {sample = currentTrace.returnValue, logprob = currentTrace.logprob})
		end
	end
	if verbose then
		kernel:stats()
	end
	return samps
end


-- Sample from a probabilistic computation for some
-- number of iterations using single-variable-proposal
-- Metropolis-Hastings 
function traceMH(computation, numsamps, lag, verbose)
	lag = (lag == nil) and 1 or lag
	return mcmc(computation, RandomWalkKernel:new(), numsamps, lag, verbose)
end