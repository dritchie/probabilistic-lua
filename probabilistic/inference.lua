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
	nonstructural = (nonstructural == nil) and true or nonstructural
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


-- Abstraction for the linear interpolation of two execution traces
local LARJInterpolationTrace = {
	properties = {
		logprob = function(self) return (1-self.alpha)*self.trace1.logprob + self.alpha*self.trace2.logprob end,
		conditionsSatisfied = function(self) return self.trace1.conditionsSatisfied and self.trace2.conditionsSatisfied end,
		returnValue = function(self) return trace2.returnValue end
	}
}

function LARJInterpolationTrace:__index(key)
	local v = LARJInterpolationTrace[key]
	return v ~= nil and v or LARJInterpolationTrace.properties[key](self)
end

function LARJInterpolationTrace:new(trace1, trace2, alpha)
	alpha = alpha or 0
	local newobj = {
		trace1 = trace1,
		trace2 = trace2,
		alpha = alpha
	}
	setmetatable(newobj, self)
	return newobj
end

function LARJInterpolationTrace:freeVarNames(structural, nonstructural)
	structural = (structural == nil) and true or structural
	nonstructural = (nonstructural == nil) and true or nonstructural
	local fv1 = self.trace1:freeVarNames(structural, nonstructural)
	local fv2 = self.trace2:freeVarNames(structural, nonstructural)
	local set = {}
	for i,name in ipairs(fv1) do
		set[name] = true
	end
	for i,name in ipairs(fv2) do
		set[name] = true
	end
	return util.keys(set)
end

function LARJInterpolationTrace:proposeChange(varname)
	local var1 = self.trace1:getRecord(varname)
	local var2 = self.trace2:getRecord(varname)
	local nextTrace = LARJInterpolationTrace:new(var1 and self.trace1:deepcopy() or self.trace1,
												 var2 and self.trace2:deepcopy() or self.trace2,
												 self.alpha)
	var1 = nextTrace.trace1:getRecord(varname)
	var2 = nextTrace.trace2:getRecord(varname)
	local var = var1 or var2
	assert(not var.structural) 	-- We're only suposed to be making changes to non-structurals here
	local propval = var.erp:proposal(var.val, var.params)
	local fwdPropLP = var.erp:logProposalProb(var.val, propval, var.params)
	local rvsPropLP = var.erp:logProposalProb(propval, var.val, var.params)
	if var1 then
		var.val = propval
		var1.logprob = var1.erp:logprob(var1.val, var1.params)
		nextTrace.trace1:traceUpdate()
	end
	if var2 then
		var2.val = propval
		var2.logprob = var2.erp:logprob(var2.val, var2.params)
		nextTrace.trace2:traceUpdate()
	end
	return nextTrace, fwdPropLP, rvsPropLP
end


-- MCMC transition kernel that does reversible jumps using the LARJ algorithm
local LARJKernel = {}

function LARJKernel:new(diffusionKernel, annealSteps, jumpFreq)
	local newobj = {
		diffusionKernel = diffusionKernel,
		annealSteps = annealSteps,
		jumpFreq = jumpFreq,
		jumpProposalsMade = 0,
		jumpProposalsAccepted = 0,
		diffusionProposalsMade = 0,
		diffusionProposalsAccepted = 0,
		annealingProposalsMade = 0,
		annealingProposalsAccepted = 0
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function LARJKernel:next(currTrace)
	local numStruct = table.getn(currTrace:freeVarNames(true, false))
	local numNonStruct = table.getn(currTrace:freeVarNames(false, true))

	-- If we have no free random variables, then just run the computation
	-- and generate another sample (this may not actually be deterministic,
	-- in the case of nested query)
	if numStruct + numNonStruct == 0 then
		currTrace:traceUpdate()
		return currTrace
	end
	-- Decide whether to jump or diffuse
	local structChoiceProp = self.jumpFreq or numStruct/(numStruct+numNonStruct)
	if math.random() < structChoiceProp then
		-- Make a structural proposal
		return self:jumpStep(currTrace)
	else
		-- Make a nonstructural proposal
		local prevAccepted = self.diffusionKernel.proposalsAccepted
		local nextTrace = self.diffusionKernel:next(currTrace)
		self.diffusionProposalsMade = self.diffusionProposalsMade + 1
		self.diffusionProposalsAccepted = self.diffusionProposalsAccepted + self.diffusionKernel.proposalsAccepted - prevAccepted
		return nextTrace
	end
end

function LARJKernel:jumpStep(currTrace)
	self.jumpProposalsMade = self.jumpProposalsMade + 1
	local oldStructTrace = currTrace:deepcopy()
	local newStructTrace = currTrace:deepcopy()

	-- Randomly choose a structural variable to change
	local structVars = newStructTrace:freeVarNames(true, false)
	local name = util.randomChoice(structVars)
	local var = newStructTrace:getRecord(name)
	local origval = var.val
	local propval = var.erp:proposal(var.val, var.params)
	local fwdPropLP = var.erp:logProposalProb(var.val, propval, var.params)
	var.val = propval
	var.logprob = var.erp:logprob(var.val, var.params)
	newStructTrace:traceUpdate()
	local oldNumVars = table.getn(structVars)
	local newNumVars = table.getn(newStructTrace:freeVarNames(true, false))
	fwdPropLP = fwdPropLP + newStructTrace.newlogprob - math.log(oldNumVars)

	-- We only actually do annealing if we have any non-structural variables and we're
	-- doing more than zero annealing steps
	local annealingLpRatio = 0
	if table.getn(oldStructTrace:freeVarNames(false, true)) + table.getn(newStructTrace:freeVarNames(false, true)) ~= 0
		and self.annealSteps > 0 then
		local lerpTrace = LARJInterpolationTrace:new(oldStructTrace, newStructTrace)
		local prevAccepted = self.diffusionKernel.proposalsAccepted
		for aStep=1,self.annealSteps do
			lerpTrace.alpha = aStep/(self.annealSteps-1)
			annealingLpRatio = annealingLpRatio + lerpTrace.logprob
			lerpTrace = self.diffusionKernel:next(lerpTrace)
			annealingLpRatio = annealingLpRatio - lerpTrace.logprob
		end
		self.annealingProposalsMade = self.annealingProposalsMade + self.annealSteps
		self.annealingProposalsAccepted = self.annealingProposalsAccepted + self.diffusionKernel.proposalsAccepted - prevAccepted
		oldStructTrace = lerpTrace.trace1
		newStructTrace = lerpTrace.trace2
	end

	-- Finalize accept/reject decision
	var = newStructTrace:getRecord(name)
	local rvsPropLP = var.erp:logProposalProb(propval, origval, var.params) + oldStructTrace:lpDiff(newStructTrace) - math.log(newNumVars)
	local acceptanceProb = newStructTrace.logprob - currTrace.logprob + rvsPropLP - fwdPropLP + annealingLpRatio
	if newStructTrace.conditionsSatisfied and math.log(math.random()) < acceptanceProb then
		self.jumpProposalsAccepted = self.jumpProposalsAccepted + 1
		return newStructTrace
	else
		return currTrace
	end
end

function LARJKernel:stats()
	local overallProposalsMade = self.jumpProposalsMade + self.diffusionProposalsMade
	local overallProposalsAccepted = self.jumpProposalsAccepted + self.diffusionProposalsAccepted
	if self.diffusionProposalsMade > 0 then
		print(string.format("Diffusion acceptance ratio: %g (%u/%u)", self.diffusionProposalsAccepted/self.diffusionProposalsMade,
																	  self.diffusionProposalsAccepted, self.diffusionProposalsMade))
	end
	if self.jumpProposalsMade > 0 then
		print(string.format("Jump acceptance ratio: %g (%u/%u)", self.jumpProposalsAccepted/self.jumpProposalsMade,
																	  self.jumpProposalsAccepted, self.jumpProposalsMade))
	end
	if self.annealingProposalsMade > 0 then
		print(string.format("Annealing acceptance ratio: %g (%u/%u)", self.annealingProposalsAccepted/self.annealingProposalsMade,
																	  self.annealingProposalsAccepted, self.annealingProposalsMade))
	end
	print(string.format("Overall acceptance ratio: %g (%u/%u)", overallProposalsAccepted/overallProposalsMade,
																overallProposalsAccepted, overallProposalsMade))
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

-- Sample from a probabilistic computation using locally
-- annealing reversible jump mcmc
function LARJMH(computation, numsamps, annealSteps, jumpFreq, lag, verbose)
	lag = (lag == nil) and 1 or lag
	return mcmc(computation,
				LARJKernel:new(RandomWalkKernel:new(false, true), annealSteps, jumpFreq),
				numsamps, lag, verbose)
end