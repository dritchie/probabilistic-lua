local trace = require("probabilistic.trace")
local util = require("probabilistic.util")
local mt = util.guardedTerraRequire("probabilistic.mathtracing")
local random = require("probabilistic.random")


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
		return self:getIRNode()
	else
		return self.value
	end
end

function HyperParam:getIRNode()
	if not self.__value then
		self.__value = mt.makeParameterNode(double, self.name)
	end
	return self.__value
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
		local nextTrace = currTrace:deepcopy()
		local rec = nextTrace:getRecord(name)
		local erp = rec:getProp("erp")
		local val = rec:getProp("val")
		local params = rec:getProp("params")
		local propval = erp:proposal(val, params)
		local fwdPropLP = erp:logProposalProb(val, propval, params)
		local rvsPropLP = erp:logProposalProb(propval, val, params)
		rec:setProp("val", propval)
		rec:setProp("logprob", erp:logprob(propval, params))
		nextTrace:traceUpdate(not self.structural)
		if nextTrace.newlogprob ~= 0 or nextTrace.oldlogprob ~= 0 then
			fwdPropLP = fwdPropLP + nextTrace.newlogprob - math.log(table.getn(currTrace:freeVarNames(self.structural, self.nonstructural)))
			rvsPropLP = rvsPropLP + nextTrace.oldlogprob - math.log(table.getn(nextTrace:freeVarNames(self.structural, self.nonstructural)))
		end
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
		local rec = newTrace:getRecord(name)
		local ann = rec:getProp("annotation")
		local v = rec:getProp("val")
		local newv = random.gaussian_sample(v, self.bandwidthMap[ann] or self.defaultBandwidth)
		rec:setProp("val", newv)
		rec:setProp("logprob", rec:getProp("erp"):logprob(newv, rec:getProp("params")))
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
local LARJInterpolationTrace = {}

util.addReadonlyProperty(LARJInterpolationTrace, "logprob",
	function(self)
		local a = self.alpha:getValue()
		return (1-a)*self.trace1.logprob + a*self.trace2.logprob
	end)
util.addReadonlyProperty(LARJInterpolationTrace, "conditionsSatisfied",
	function(self) return self.trace1.conditionsSatisfied and self.trace2.conditionsSatisfied end)
util.addReadonlyProperty(LARJInterpolationTrace, "returnValue",
	function(self) return trace2.returnValue end)

function LARJInterpolationTrace:new(trace1, trace2, alpha)
	alpha = alpha or HyperParam:new("larjAnnealAlpha", 0)
	local newobj = {
		trace1 = trace1,
		trace2 = trace2,
		alpha = alpha,
		-- These next two are expected by the random walk kernel
		newlogprob = 0,
		oldlogprob = 0
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

LARJInterpolationTrace.Record = {}

function LARJInterpolationTrace.Record:new(rec1, rec2)
	local newobj =
	{
		rec1 = rec1,
		rec2 = rec2
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function LARJInterpolationTrace.Record:getProp(propname)
	return self.rec1 and self.rec1:getProp(propname) or
		   self.rec2 and self.rec2:getProp(propname)
end

function LARJInterpolationTrace.Record:setProp(propname, val)
	if self.rec1 then self.rec1:setProp(propname, val) end
	if self.rec2 then self.rec2:setProp(propname, val) end
end

function LARJInterpolationTrace:getRecord(name)
	return LARJInterpolationTrace.Record:new(self.trace1:getRecord(name), self.trace2:getRecord(name))
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

function LARJInterpolationTrace:traceUpdate(structureIsFixed)
	self.trace1:traceUpdate(structureIsFixed)
	self.trace2:traceUpdate(structureIsFixed)
end

function LARJInterpolationTrace:flushLogProbs()
	self.trace1:flushLogProbs()
	self.trace2:flushLogProbs()
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

	-- -- for DEBUG output
	-- local lps = {}
	-- local acceptRejects = {}
	local newLpWithoutAnnealing = newStructTrace.logprob

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
			--local prevacc = self.diffusionKernel.proposalsAccepted -------
			lerpTrace.alpha:setValue(aStep/(self.annealSteps-1))
			--table.insert(lps, lerpState.logprob) -------
			annealingLpRatio = annealingLpRatio + lerpState.logprob
			lerpState = self.diffusionKernel:next(lerpState, hyperparams)
			--table.insert(lps, lerpState.logprob) -------
			annealingLpRatio = annealingLpRatio - lerpState.logprob
			--table.insert(acceptRejects, self.diffusionKernel.proposalsAccepted ~= prevacc) -------
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
	local accepted = newStructTrace.conditionsSatisfied and math.log(math.random()) < acceptanceProb

	-- DEBUG output
	-- if newStructTrace.logprob - currTrace.logprob > 0 then
	-- 	print("---------------")
	-- 	print("newStructTrace.logprob: ", newStructTrace.logprob)
	-- 	print("currTrace.logprob:", currTrace.logprob)
	-- 	print("rvsPropLP:", rvsPropLP)
	-- 	print("fwdPropLP:", fwdPropLP)
	-- 	print(string.format("annealingLpRatio: %g", annealingLpRatio))
	-- 	print(string.format("acceptanceProb: %g", acceptanceProb))
	-- 	print(string.format("lpDiffWithoutAnnealing: %g", newLpWithoutAnnealing - currTrace.logprob))
	-- 	print(string.format("lpDiffWithAnnealing: %g", newStructTrace.logprob - currTrace.logprob))
	-- 	print(string.format("diffAnnealingMade: %g", newStructTrace.logprob - newLpWithoutAnnealing))
	-- end
	--if accepted then
		-- print("==========")
		-- print("Old num nonstructs:", table.getn(oldStructTrace:freeVarNames(false, true)))
		-- print("New num nonstructs:", table.getn(newStructTrace:freeVarNames(false, true)))
		-- print("---annealing run---")
		-- for i=0,table.getn(acceptRejects)-1 do
		-- 	if acceptRejects[i+1] then
		-- 		print(string.format("%g | %g (ACCEPT)", lps[2*i+1], lps[2*i+2]))
		-- 	else
		-- 		print(string.format("%g | %g (REJECT)", lps[2*i+1], lps[2*i+2]))
		-- 	end
		-- end
		-- print("----------")
		-- local totalaccepts = 0
		-- for i,a in ipairs(acceptRejects) do
		-- 	if a then totalaccepts = totalaccepts + 1 end
		-- end
		-- print(string.format("annealing accept ratio: %g", totalaccepts/self.annealSteps))
		-- print(string.format("annealingLpRatio: %g", annealingLpRatio))
		-- if accepted then print("ACCEPT") else print("REJECT") end
	--end

	if accepted then
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
		if kernelparams.verbose then
			io.write(string.format("iteration %d\r", i))
			io.flush()
		end
		currentState = kernel:next(currentState)
		if i % kernelparams.lag == 0 then
			table.insert(samps, currentState)
		end
	end
	currentTrace = kernel:releaseControl(currentState)
	if kernelparams.verbose then
		print("")
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
	LARJInterpolationTrace = LARJInterpolationTrace,
	RandomWalkKernel = RandomWalkKernel,
	LARJKernel = LARJKernel,
	mcmc = mcmc,
	traceMH = traceMH,
	driftMH = driftMH,
	LARJTraceMH = LARJTraceMH,
	LARJDriftMH = LARJDriftMH
}
