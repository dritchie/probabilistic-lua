local trace = require("probabilistic.trace")
local util = require("probabilistic.util")
local mt = util.guardedTerraRequire("probabilistic.mathtracing")
local erp = require("probabilistic.erp")


-- Compute the discrete distribution over the given computation
-- Only appropriate for computations that return a discrete value
-- (Variadic arguments are arguments to the sampling function)
local function distrib(computation, samplingFn, params)
	local hist = {}
	local samps = samplingFn(computation, params)
	for i,s in ipairs(samps) do
		local prevval = hist[s.returnValue] or 0
		hist[s.returnValue] = prevval + 1
	end
	local numsamps = table.getn(samps)
	for s,n in pairs(hist) do
		hist[s] = hist[s] / numsamps
	end
	return hist
end

-- Compute the mean of a set of values
local function mean(values)
	local m = values[1]
	local n = table.getn(values)
	for i=2,n do
		m = m + values[i]
	end
	return m / n
end

-- Compute the expected value of a computation
-- Only appropraite for computations whose return value is a number or overloads + and /
local function expectation(computation, samplingFn, params)
	local samps = samplingFn(computation, params)
	return mean(util.map(function(s) return s.returnValue end, samps))
end

-- Maximum a posteriori inference (returns the highest probability sample)
local function MAP(computation, samplingFn, params)
	local samps = samplingFn(computation, params)
	local maxelem = {sample = nil, logprob = -math.huge}
	for i,s in ipairs(samps) do
		if s.logprob > maxelem.logprob then
			maxelem = s
		end
	end
	return maxelem.returnValue
end

-- Rejection sample a result from computation that satisfies all
-- conditioning expressions
local function rejectionSample(computation)
	local tr = trace.newTrace(computation)
	return tr.returnValue
end


-- A log probability hyperparameter for an MCMC kernel
-- A table of these may be passed to any kernel:next() (see HyperParamTable)
-- Certain kernels may expect/require certain hyperparameters
-- For JITed traces, hyperparameters used anywhere in the logprob
-- calculation *must* be provided via kernel:next() for the kernel
--   to know their values.
local HyperParam = {}

function HyperParam:new(name, value)
	assert(type(value) == "number")
	local newobj = 
	{
		name = name,
		value = value
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function HyperParam:setValue(newval)
	self.value = newval
end

function HyperParam:getValue()
	if mt and mt.isOn() then
		if not self.__value then
			self.__value = mt.makeParameterNode(double, self.name)
		end
		return self.__value
	else
		return self.value
	end
end


local HyperParamTable = {}

function HyperParamTable:new()
	local newobj = {}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function HyperParamTable:add(hyperparam)
	self[hyperparam.name] = hyperparam
end

function HyperParamTable:remove(hyperparam)
	self[hyperparam.name] = nil
end

function HyperParamTable:copy()
	local newtable = HyperParamTable:new()
	util.copytablemembers(self, newtable)
	return newtable
end


-- Basic parameters required by a kernel to function
-- These get passed into the 'mcmc' function
-- Different Kernels can add 'default' parameter values
--    by adding them to the KernelParams table, which is the
--    metatable of all KernelParams instances.
local KernelParams =
{
	-- Set up the default parameters expected by *any* MCMC algorithm
	numsamps = 1000,
	lag = 1,
	verbose = false
}

function KernelParams:new(paramtable)
	paramtable = paramtable or {}
	setmetatable(paramtable, self)
	self.__index = self
	return paramtable
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

function RandomWalkKernel:assumeControl(currTrace)
	return currTrace
end

function RandomWalkKernel:next(currTrace, hyperparams)
	self.proposalsMade = self.proposalsMade + 1
	local name = util.randomChoice(currTrace:freeVarNames(self.structural, self.nonstructural))

	-- If we have no free random variables, then just run the computation
	-- and generate another sample (this may not actually be deterministic,
	-- in the case of nested query)
	if not name then
		local newTrace = currTrace:deepcopy()
		newTrace:traceUpdate(not self.structural)
		return newTrace
	-- Otherwise, make a proposal for a randomly-chosen variable, probabilistically
	-- accept it
	else
		local nextTrace, fwdPropLP, rvsPropLP = currTrace:proposeChange(name, not self.structural)
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

function RandomWalkKernel:releaseControl(currTrace)
	return currTrace
end

function RandomWalkKernel:stats()
	print(string.format("Acceptance ratio: %g (%u/%u)", self.proposalsAccepted/self.proposalsMade,
														self.proposalsAccepted, self.proposalsMade))
end


-- MCMC Transition kernel that takes random walks for contiuous variables
-- by perform single-variable gaussian drift
-- NOTE: This is a fixed-dimensionality inference kernel (it will not make
--    structural changes)
local GaussianDriftKernel = {}

-- Default parameter values
KernelParams.bandwidthMap = {}
KernelParams.defaultBandwidth = 0.1

function GaussianDriftKernel:new(bandwidthMap, defaultBandwidth)
	local newobj = 
	{
		bandwidthMap = bandwidthMap,
		defaultBandwidth = defaultBandwidth,
		proposalsMade = 0,
		proposalsAccepted = 0
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function GaussianDriftKernel:assumeControl(currTrace)
	return currTrace
end

function GaussianDriftKernel:releaseControl(currTrace)
	return currTrace
end

function GaussianDriftKernel:next(currTrace)
	self.proposalsMade = self.proposalsMade + 1
	local newTrace = currTrace:deepcopy()
	local name = util.randomChoice(newTrace:freeVarNames(false, true))

	-- If we have no free random variables, then just run the computation
	-- and generate another sample (this may not actually be deterministic,
	-- in the case of nested query)
	if not name then
		newTrace:traceUpdate(true)
		return newTrace
	-- Otherwise, make a proposal for a randomly-chosen variable, probabilistically
	-- accept it
	else
		local ann = currTrace:getVarProp(name, "annotation")
		local v = currTrace:getVarProp(name, "val")
		local newv = erp.gaussian(v, self.bandwidthMap[ann] or self.defaultBandwidth)
		newTrace:setVarProp(name, "val", newv)
		newTrace:setVarProp(name, "logprob", newTrace:getVarProp(name, "erp"):logprob(newv, newTrace:getVarProp(name, "params")))
		newTrace:traceUpdate(true)
		local acceptThresh = newTrace.logprob - currTrace.logprob
		if newTrace.conditionsSatisfied and math.log(math.random()) < acceptThresh then
			self.proposalsAccepted = self.proposalsAccepted + 1
			return newTrace
		else
			return currTrace
		end
	end
end

function GaussianDriftKernel:stats()
	print(string.format("Acceptance ratio: %g (%u/%u)", self.proposalsAccepted/self.proposalsMade,
														self.proposalsAccepted, self.proposalsMade))
end



-- Abstraction for the linear interpolation of two execution traces
local LARJInterpolationTrace = {
	properties = {
		logprob = function(self)
			local a = self.alpha:getValue()
			return (1-a)*self.trace1.logprob + a*self.trace2.logprob
		end,
		conditionsSatisfied = function(self) return self.trace1.conditionsSatisfied and self.trace2.conditionsSatisfied end,
		returnValue = function(self) return trace2.returnValue end
	}
}

function LARJInterpolationTrace:__index(key)
	local v = LARJInterpolationTrace[key]
	return v ~= nil and v or LARJInterpolationTrace.properties[key](self)
end

function LARJInterpolationTrace:new(trace1, trace2, alpha)
	alpha = alpha or HyperParam:new("larjAnnealAlpha", 0)
	local newobj = {
		trace1 = trace1,
		trace2 = trace2,
		alpha = alpha,
	}
	setmetatable(newobj, self)
	return newobj
end

function LARJInterpolationTrace:freeVarNames(structural, nonstructural)
	structural = (structural == nil) and true or structural
	nonstructural = (nonstructural == nil) and true or nonstructural
	local fv1 = self.trace1:freeVarNames(structural, nonstructural)
	local fv2 = self.trace2:freeVarNames(structural, nonstructural)
	local fvall = {}
	local seenset = {}
	local biggestn = math.max(table.getn(fv1), table.getn(fv2))
	for i=1,biggestn do
		local n1 = fv1[i]
		local n2 = fv2[i]
		if not n1 then
			if not seenset[n2] then table.insert(fvall, n2) end
		elseif not n2 then
			if not seenset[n1] then table.insert(fvall, n1) end
		elseif n1 < n2 then
			if not seenset[n1] then table.insert(fvall, n1) end
			if not seenset[n2] then table.insert(fvall, n2) end
		elseif n1 > n2 then
			if not seenset[n2] then table.insert(fvall, n2) end
			if not seenset[n1] then table.insert(fvall, n1) end
		else
			if not seenset[n1] then table.insert(fvall, n1) end
		end
		if n1 then seenset[n1] = true end
		if n2 then seenset[n2] = true end
	end
	return fvall
end

function LARJInterpolationTrace:hasVar(name)
	return self.trace1:hasVar(name) or self.trace2:hasVar()
end

function LARJInterpolationTrace:getVarProp(name, prop)
	local var1 = self.trace1.vars[name]
	if var1 then
		return var1[prop]
	else
		local var2 = self.trace2.vars[name]
		if var2 then
			return var2[prop]
		else
			return nil
		end
	end
end

function LARJInterpolationTrace:setVarProp(name, prop, val)
	local var1 = self.trace1.vars[name]
	local var2 = self.trace2.vars[name]
	if var1 then
		var1[prop] = val
	end
	if var2 then
		var2[prop] = val
	end
end

function LARJInterpolationTrace:deepcopy()
	return LARJInterpolationTrace:new(self.trace1:deepcopy(), self.trace2:deepcopy(), self.alpha)
end

function LARJInterpolationTrace:structuralSignatures()
	local sig1 = self.trace1:structuralSignatures()[1]
	local sig2 = self.trace2:structuralSignatures()[1]
	return {string.format("%s,%s", sig1, sig2), string.format("%s,%s", sig2, sig1)}
end

function LARJInterpolationTrace:toggleFactorEval(switch)
	self.trace1:toggleFactorEval(switch)
	self.trace2:toggleFactorEval(switch)
end

function LARJInterpolationTrace:setLogProb(newlp)
	local a = self.alpha:getValue()
	self.trace1:setLogProb((1-a)*newlp)
	self.trace2:setLogProb(a*newlp)
end

function LARJInterpolationTrace:traceUpdate(structureIsFixed)
	self.trace1:traceUpdate(structureIsFixed)
	self.trace2:traceUpdate(structureIsFixed)
end

function LARJInterpolationTrace:proposeChange(varname, structureIsFixed)
	assert(structureIsFixed)
	local nextTrace = self:deepcopy()
	local var1 = nextTrace.trace1.vars[varname]
	local var2 = nextTrace.trace2.vars[varname]
	local var = var1 or var2
	assert(not var.structural) 	-- We're only suposed to be making changes to non-structurals here
	local propval = var.erp:proposal(var.val, var.params)
	local fwdPropLP = var.erp:logProposalProb(var.val, propval, var.params)
	local rvsPropLP = var.erp:logProposalProb(propval, var.val, var.params)
	if var1 then
		var1.val = propval
		var1.logprob = var1.erp:logprob(var1.val, var1.params)
		nextTrace.trace1:traceUpdate(structureIsFixed)
	end
	if var2 then
		var2.val = propval
		var2.logprob = var2.erp:logprob(var2.val, var2.params)
		nextTrace.trace2:traceUpdate(structureIsFixed)
	end
	return nextTrace, fwdPropLP, rvsPropLP
end


-- MCMC transition kernel that does reversible jumps using the LARJ algorithm
local LARJKernel = {}

-- Default parameter values
KernelParams.annealSteps = 0
KernelParams.jumpFreq = nil

function LARJKernel:new(diffusionKernel, annealSteps, jumpFreq)
	local newobj = {
		diffusionKernel = diffusionKernel,
		annealSteps = annealSteps,
		jumpFreq = jumpFreq,

		currentNumStruct = 0,
		currentNumNonStruct = 0,
		isDiffusing = false,

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

function LARJKernel:updateCurrentTraceData(currTrace)
	self.currentNumStruct = table.getn(currTrace:freeVarNames(true, false))
	self.currentNumNonStruct = table.getn(currTrace:freeVarNames(false, true))
end

function LARJKernel:assumeControl(currTrace)
	self:updateCurrentTraceData(currTrace)
	self.isDiffusing = false
	return currTrace
end

function LARJKernel:next(currState, hyperparams)
	if not self.isDiffusing then
		self:updateCurrentTraceData(currState)
		-- If we have no free random variables, then just run the computation
		-- and generate another sample (this may not actually be deterministic,
		-- in the case of nested query)
		if self.currentNumStruct + self.currentNumNonStruct == 0 then
			local newTrace = currState:deepcopy()
			newTrace:traceUpdate()
			return newTrace
		end
	end
	-- Decide whether to jump or diffuse
	local structChoiceProb = self.jumpFreq or self.currentNumStruct/(self.currentNumStruct+self.currentNumNonStruct)
	if math.random() < structChoiceProb then
		-- Make a structural proposal
		if self.isDiffusing then
			local currTrace = self.diffusionKernel:releaseControl(currState)
			currTrace = self:assumeControl(currTrace)
			return self:jumpStep(currTrace)
		else
			return self:jumpStep(currState)
		end
	else
		-- Make a nonstructural proposal
		if not self.isDiffusing then
			local currTrace = self:releaseControl(currState)
			currState = self.diffusionKernel:assumeControl(currTrace)
			self.isDiffusing = true
		end
		local prevAccepted = self.diffusionKernel.proposalsAccepted
		local nextState = self.diffusionKernel:next(currState)
		self.diffusionProposalsMade = self.diffusionProposalsMade + 1
		self.diffusionProposalsAccepted = self.diffusionProposalsAccepted + self.diffusionKernel.proposalsAccepted - prevAccepted
		return nextState
	end
end

function LARJKernel:jumpStep(currTrace)
	self.jumpProposalsMade = self.jumpProposalsMade + 1
	local oldStructTrace = currTrace:deepcopy()
	local newStructTrace = currTrace:deepcopy()

	-- Randomly choose a structural variable to change
	local structVars = newStructTrace:freeVarNames(true, false)
	local name = util.randomChoice(structVars)
	local var = newStructTrace.vars[name]
	local origval = var.val
	local propval = var.erp:proposal(var.val, var.params)
	local fwdPropLP = var.erp:logProposalProb(var.val, propval, var.params)
	var.val = propval
	var.logprob = var.erp:logprob(var.val, var.params)
	newStructTrace:traceUpdate()
	local oldNumVars = table.getn(oldStructTrace:freeVarNames(true, true))
	local newNumVars = table.getn(newStructTrace:freeVarNames(true, true))
	fwdPropLP = fwdPropLP + newStructTrace.newlogprob - math.log(oldNumVars)

	-- We only actually do annealing if we have any non-structural variables and we're
	-- doing more than zero annealing steps
	local annealingLpRatio = 0
	if table.getn(oldStructTrace:freeVarNames(false, true)) + table.getn(newStructTrace:freeVarNames(false, true)) ~= 0
		and self.annealSteps > 0 then
		local lerpTrace = LARJInterpolationTrace:new(oldStructTrace, newStructTrace)
		local hyperparams = HyperParamTable:new()
		hyperparams:add(lerpTrace.alpha)
		local prevAccepted = self.diffusionKernel.proposalsAccepted

		lerpTrace = self:releaseControl(lerpTrace)
		local lerpState = self.diffusionKernel:assumeControl(lerpTrace)
		self.isDiffusing = true

		for aStep=0,self.annealSteps-1 do
			lerpTrace.alpha:setValue(aStep/(self.annealSteps-1))
			annealingLpRatio = annealingLpRatio + lerpState.logprob
			lerpState = self.diffusionKernel:next(lerpState, hyperparams)
			annealingLpRatio = annealingLpRatio - lerpState.logprob
		end

		lerpTrace = self.diffusionKernel:releaseControl(lerpState)
		lerpTrace = self:assumeControl(lerpTrace)

		self.annealingProposalsMade = self.annealingProposalsMade + self.annealSteps
		self.annealingProposalsAccepted = self.annealingProposalsAccepted + self.diffusionKernel.proposalsAccepted - prevAccepted
		oldStructTrace = lerpTrace.trace1
		newStructTrace = lerpTrace.trace2
	end

	-- Finalize accept/reject decision
	var = newStructTrace.vars[name]
	local rvsPropLP = var.erp:logProposalProb(propval, origval, var.params) + oldStructTrace:lpDiff(newStructTrace) - math.log(newNumVars)
	local acceptanceProb = newStructTrace.logprob - currTrace.logprob + rvsPropLP - fwdPropLP + annealingLpRatio
	if newStructTrace.conditionsSatisfied and math.log(math.random()) < acceptanceProb then
		self.jumpProposalsAccepted = self.jumpProposalsAccepted + 1
		return newStructTrace
	else
		return currTrace
	end
end

function LARJKernel:releaseControl(currTrace)
	return currTrace
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
local function mcmc(computation, kernel, kernelparams)
	local currentTrace = trace.newTrace(computation)
	local samps = {}
	local iters = kernelparams.numsamps * kernelparams.lag
	local currentState = kernel:assumeControl(currentTrace)
	for i=1,iters do
		currentState = kernel:next(currentState)
		if i % kernelparams.lag == 0 then
			table.insert(samps, currentState)
		end
	end
	currentTrace = kernel:releaseControl(currentState)
	if kernelparams.verbose then
		kernel:stats()
	end
	return samps
end


-- Sample from a probabilistic computation for some
-- number of iterations using single-variable-proposal
-- Metropolis-Hastings 
local function traceMH(computation, params)
	params = KernelParams:new(params)
	return mcmc(computation, RandomWalkKernel:new(), params)
end

-- Sample from a (fixed-dimension) probabilistic computation
-- using gaussian drift MH
local function driftMH(computation, params)
	params = KernelParams:new(params)
	return mcmc(computation, GaussianDriftKernel:new(params.bandwidthMap, params.defaultBandwidth),
				params)
end

-- Sample from a probabilistic computation using locally
-- annealed reversible jump mcmc
local function LARJTraceMH(computation, params)
	params = KernelParams:new(params)
	return mcmc(computation,
				LARJKernel:new(RandomWalkKernel:new(false, true), params.annealSteps, params.jumpFreq),
				params)
end

-- Sample from a probabilistic computation using LARJMCMC
-- with gaussian drift as the inner diffusion kernel
local function LARJDriftMH(computation, params)
	params = KernelParams:new(params)
	return mcmc(computation,
				LARJKernel:new(
					GaussianDriftKernel:new(params.bandwidthMap, params.defaultBandwidth),
					params.annealSteps, params.jumpFreq),
				params)
end


-- exports
return
{
	distrib = distrib,
	mean = mean,
	expectation = expectation,
	MAP = MAP,
	rejectionSample = rejectionSample,
	KernelParams = KernelParams,
	RandomWalkKernel = RandomWalkKernel,
	LARJKernel = LARJKernel,
	mcmc = mcmc,
	traceMH = traceMH,
	driftMH = driftMH,
	LARJTraceMH = LARJTraceMH,
	LARJDriftMH = LARJDriftMH
}
