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

local function sampleMAP(samps)
	local maxelem = {returnValue = nil, logprob = -math.huge}
	for i,s in ipairs(samps) do
		if s.logprob > maxelem.logprob then
			maxelem = s
		end
	end
	return maxelem.returnValue
end

-- Maximum a posteriori inference (returns the highest probability sample)
local function MAP(computation, samplingFn, params)
	local samps = samplingFn(computation, params)
	return sampleMAP(samps)
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
	burnin = 0,
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

function RandomWalkKernel:tellLARJStatus(alpha, oldVarNames, newVarNames)
	-- Default is to do nothing
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
	self.nonStructNames = currTrace:freeVarNames(false, true)
	self.varChoiceProbs = {}
	for i=1,#self.nonStructNames do
		self.varChoiceProbs[i] = 1.0
	end
	return currTrace
end

function GaussianDriftKernel:releaseControl(currTrace)
	return currTrace
end

function GaussianDriftKernel:next(currTrace)
	self.proposalsMade = self.proposalsMade + 1
	local newTrace = currTrace:deepcopy()

	-- If we have no free random variables, then just run the computation
	-- and generate another sample (this may not actually be deterministic,
	-- in the case of nested query)
	if #self.nonStructNames == 0 then
		newTrace:traceUpdate(true)
		return newTrace
	-- Otherwise, make a proposal for a randomly-chosen variable, probabilistically accept it
	else
		-- Choose a variable to perturb based on a vector of per-variable
		-- probabilities.
		local varIndex = random.multinomial_sample(unpack(self.varChoiceProbs))
		local name = self.nonStructNames[varIndex]

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

function GaussianDriftKernel:tellLARJStatus(alpha, oldVarNames, newVarNames)
	-- Make it less likely to propose to change certain variables based on alpha
	local oldVarSet = util.listToSet(oldVarNames)
	local newVarSet = util.listToSet(newVarNames)
	local oldScale = (1.0-alpha)
	local newScale = alpha
	for i,n in ipairs(self.nonStructNames) do
		if oldVarSet[n] then
			self.varChoiceProbs[i] = oldScale
		elseif newVarSet[n] then
			self.varChoiceProbs[i] = newScale
		else
			self.varChoiceProbs[i] = 1.0
		end
	end
	util.normalize(self.varChoiceProbs)
end



-- MCMC transition kernel that probabilistically selects between multiple sub-kernels
local MultiKernel = {}

-- No default parameters

function MultiKernel:new(kernels, names, freqs)
	local newobj = 
	{
		kernels = kernels,
		names = names,
		freqs = freqs,
		currKernelIndex = 0
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function MultiKernel:assumeControl(currTrace)
	return currTrace
end

function MultiKernel:next(currState, hyperparms)
	local whichKernel = random.multinomial_sample(unpack(self.freqs))
	if whichKernel ~= self.currKernelIndex then
		if self.currKernelIndex > 0 then
			currState = self.kernels[self.currKernelIndex]:releaseControl(currState)
		end
		currState = self.kernels[whichKernel]:assumeControl(currState)
	end
	self.currKernelIndex = whichKernel
	return self.kernels[whichKernel]:next(currState, hyperparms)
end

function MultiKernel:releaseControl(currState)
	if self.currKernelIndex > 0 then
		currState = self.kernels[self.currKernelIndex]:releaseControl(currState)
	end
	return currState
end

function MultiKernel:stats()
	for i,n in ipairs(self.names) do
		print(string.format("-- Kernel %i (%s) --", i, n))
		self.kernels[i]:stats()
	end
end


-- Abstraction for the linear interpolation of two execution traces
local LARJInterpolationTrace = {}

util.addReadonlyProperty(LARJInterpolationTrace, "logprob",
	function(self)
		local a = self.alpha:getValue()
		local t = self.globalTemp:getValue()
		return t*((1-a)*self.trace1.logprob + a*self.trace2.logprob)
	end)
util.addReadonlyProperty(LARJInterpolationTrace, "conditionsSatisfied",
	function(self) return self.trace1.conditionsSatisfied and self.trace2.conditionsSatisfied end)
util.addReadonlyProperty(LARJInterpolationTrace, "returnValue",
	function(self) return trace2.returnValue end)

function LARJInterpolationTrace:new(trace1, trace2, alpha, globalTemp)
	alpha = alpha or HyperParam:new("larjAnnealAlpha", 0)
	globalTemp = globalTemp or HyperParam:new("larjAnnealGlobalTemp", 1)
	local newobj = {
		trace1 = trace1:deepcopy(),
		trace2 = trace2:deepcopy(),
		alpha = alpha,
		globalTemp = globalTemp,
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
	return LARJInterpolationTrace:new(self.trace1:deepcopy(), self.trace2:deepcopy(), self.alpha, self.globalTemp)
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


-- New LARJ Kernel should do check for 'no free random variables'

-- MCMC transition kernel that does reversible jumps using the LARJ algorithm
local LARJKernel = {}

-- Default parameter values
KernelParams.annealIntervals = 0
KernelParams.annealStepsPerInterval = 1
KernelParams.globalTempMult = 1.0
KernelParams.jumpFreq = 0.1

function LARJKernel:new(diffusionKernel, annealIntervals, annealStepsPerInterval, globalTempMult)
	local newobj = {
		diffusionKernel = diffusionKernel,
		annealIntervals = annealIntervals,
		annealStepsPerInterval = annealStepsPerInterval,
		globalTempMult = globalTempMult,

		proposalsMade = 0,
		proposalsAccepted = 0,
		annealingProposalsMade = 0,
		annealingProposalsAccepted = 0
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function LARJKernel:assumeControl(currTrace)
	return currTrace
end

function LARJKernel:next(currState, hyperparams)

	-- If we have no free structural variables, then just run the computation
	-- and generate another sample (this may not actually be deterministic,
	-- in the case of nested query)
	local structVars = currState:freeVarNames(true, false)
	if #structVars == 0 then
		local newTrace = currState:deepcopy()
		newTrace:traceUpdate(true)
		return newTrace
	end

	self.proposalsMade = self.proposalsMade + 1
	local oldStructTrace = currState:deepcopy()
	local newStructTrace = currState:deepcopy()

	-- Randomly choose a structural variable to change
	local name = util.randomChoice(structVars)
	local var = newStructTrace.vars[name]
	local origval = var.val
	local propval = var.erp:proposal(var.val, var.params)
	local fwdPropLP = var.erp:logProposalProb(var.val, propval, var.params)
	var.val = propval
	var.logprob = var.erp:logprob(var.val, var.params)
	newStructTrace:traceUpdate()
	local oldNumVars = table.getn(oldStructTrace:freeVarNames(true, false))
	local newNumVars = table.getn(newStructTrace:freeVarNames(true, false))
	fwdPropLP = fwdPropLP + newStructTrace.newlogprob - math.log(oldNumVars)

	-- for DEBUG output
	local newLpWithoutAnnealing = newStructTrace.logprob

	-- We only actually do annealing if we have any non-structural variables and we're
	-- doing more than zero annealing steps
	local annealingLpRatio = 0
	if table.getn(oldStructTrace:freeVarNames(false, true)) + table.getn(newStructTrace:freeVarNames(false, true)) ~= 0
		and self.annealIntervals > 0 then
		local lerpTrace = LARJInterpolationTrace:new(oldStructTrace, newStructTrace)
		local hyperparams = HyperParamTable:new()
		hyperparams:add(lerpTrace.alpha)
		local prevProposed = self.diffusionKernel.proposalsMade
		local prevAccepted = self.diffusionKernel.proposalsAccepted

		--print("=== BEGIN ANNEALING ===")
		self.diffusionKernel.annealing = true

		lerpTrace = self:releaseControl(lerpTrace)
		local lerpState = self.diffusionKernel:assumeControl(lerpTrace)

		local oldVars = lerpTrace.trace1:varDiff(lerpTrace.trace2)
		local newVars = lerpTrace.trace2:varDiff(lerpTrace.trace1)

		-- for DEBUG output
		local accepts = {}

		local globalTemp = 1.0
		for aInterval=0,self.annealIntervals-1 do
			local alpha = aInterval/(self.annealIntervals-1)
			if alpha <= 0.5 then
				globalTemp = globalTemp * self.globalTempMult
			else
				globalTemp = globalTemp / self.globalTempMult
			end
			lerpTrace.alpha:setValue(alpha)
			lerpTrace.globalTemp:setValue(globalTemp)
			self.diffusionKernel:tellLARJStatus(alpha, oldVars, newVars)
			for aStep=1,self.annealStepsPerInterval do
				annealingLpRatio = annealingLpRatio + lerpState.logprob
				local pa = self.diffusionKernel.proposalsAccepted
				lerpState = self.diffusionKernel:next(lerpState, hyperparams)
				if self.diffusionKernel.proposalsAccepted ~= pa then
					table.insert(accepts, true)
				else
					table.insert(accepts, false)
				end
				annealingLpRatio = annealingLpRatio - lerpState.logprob
			end

		end

		-- -- DEBUG output
		-- print("=====================")
		-- print(string.format("%d -> %d", #oldStructTrace:freeVarNames(false, true), #newStructTrace:freeVarNames(false, true)))
		-- print("- - - - - - - - - ")
		-- -- for i,v in ipairs(accepts) do
		-- -- 	if v then print(i) end
		-- -- end
		-- local numAccepts = 0
		-- for i,v in ipairs(accepts) do
		-- 	if v then numAccepts = numAccepts + 1 end
		-- end
		-- print(string.format("%g%%\n", numAccepts/#accepts * 100))
		-- -- print("- - - - - - - - - ")
		-- -- for i,n in ipairs(lerpState:freeVarNames(false, true)) do
		-- -- 	print(lerpState:getRecord(n):getProp("val"), lerpState:getRecord(n):getProp("logprob"))
		-- -- end

		lerpTrace = self.diffusionKernel:releaseControl(lerpState)
		lerpTrace = self:assumeControl(lerpTrace)

		self.diffusionKernel.annealing = false
		--print("=== END ANNEALING ===")

		self.annealingProposalsMade = self.annealingProposalsMade + self.annealIntervals*self.annealStepsPerInterval
		self.annealingProposalsAccepted = self.annealingProposalsAccepted + self.diffusionKernel.proposalsAccepted - prevAccepted
		oldStructTrace = lerpTrace.trace1
		newStructTrace = lerpTrace.trace2

		-- Reset the stats on the diffusion kernel (we don't want to corrupt them if we're using this same kernel elsewhere...)
		-- NOTE: This is not a foolproof solution. The diffusion kernel may track other stats that we don't know about and can't
		--   reset...
		self.diffusionKernel.proposalsMade = prevProposed
		self.diffusionKernel.proposalsAccepted = prevAccepted
	end

	-- Finalize accept/reject decision
	var = newStructTrace.vars[name]
	local rvsPropLP = var.erp:logProposalProb(propval, origval, var.params) + oldStructTrace:lpDiff(newStructTrace) - math.log(newNumVars)
	local acceptanceProb = newStructTrace.logprob - currState.logprob + rvsPropLP - fwdPropLP + annealingLpRatio
	local accepted = newStructTrace.conditionsSatisfied and math.log(math.random()) < acceptanceProb

	-- -- DEBUG output
	-- print("---------------")
	-- print("accepted:", accepted)
	-- print("newStructTrace.logprob: ", newStructTrace.logprob)
	-- print("currState.logprob:", currState.logprob)
	-- print("rvsPropLP:", rvsPropLP)
	-- print("log propsal prob:", var.erp:logProposalProb(propval, origval, var.params))
	-- print("lpDiff:", oldStructTrace:lpDiff(newStructTrace))
	-- print("log num vars:", math.log(newNumVars))
	-- print("fwdPropLP:", fwdPropLP)
	-- print(string.format("annealingLpRatio: %g", annealingLpRatio))
	-- print(string.format("acceptanceProb: %g", acceptanceProb))
	-- print(string.format("lpDiffWithoutAnnealing: %g", newLpWithoutAnnealing - currState.logprob))
	-- print(string.format("lpDiffWithAnnealing: %g", newStructTrace.logprob - currState.logprob))
	-- print(string.format("diffAnnealingMade: %g", newStructTrace.logprob - newLpWithoutAnnealing))

	if accepted then
		self.proposalsAccepted = self.proposalsAccepted + 1
		return newStructTrace
	else
		return currState
	end
end

function LARJKernel:releaseControl(currTrace)
	return currTrace
end

function LARJKernel:stats()
	if self.proposalsMade > 0 then
		print(string.format("Jump acceptance ratio: %g (%u/%u)", self.proposalsAccepted/self.proposalsMade,
																	  self.proposalsAccepted, self.proposalsMade))
	end
	if self.annealingProposalsMade > 0 then
		print(string.format("Annealing acceptance ratio: %g (%u/%u)", self.annealingProposalsAccepted/self.annealingProposalsMade,
																	  self.annealingProposalsAccepted, self.annealingProposalsMade))
	end
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
		if i % kernelparams.lag == 0  and i > kernelparams.burnin then
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
-- annealed reversible jump mcmc with some diffusion kernel
local function LARJMCMC(computation, diffusionKernel, params)
	return mcmc(computation,
				MultiKernel:new({
									diffusionKernel,
									LARJKernel:new(diffusionKernel, params.annealIntervals, params.annealStepsPerInterval,
												   params.globalTempMult)
								},
								{"Diffusion", "LARJ"},
								{1.0-params.jumpFreq, params.jumpFreq}),
				params)
end

-- Sample from a probabilistic computation using locally
-- annealed reversible jump mcmc, using random walk trace MH as the diffusion kernel
local function LARJTraceMH(computation, params)
	params = KernelParams:new(params)
	local diffusionKernel = RandomWalkKernel:new(false, true)
	return LARJMCMC(computation, diffusionKernel, params)
end

-- Sample from a probabilistic computation using LARJMCMC
-- with gaussian drift as the inner diffusion kernel
local function LARJDriftMH(computation, params)
	params = KernelParams:new(params)
	local diffusionKernel = GaussianDriftKernel:new(params.bandwidthMap, params.defaultBandwidth)
	return LARJMCMC(computation, diffusionKernel, params)
end


-- exports
return
{
	distrib = distrib,
	mean = mean,
	expectation = expectation,
	sampleMAP = sampleMAP,
	MAP = MAP,
	rejectionSample = rejectionSample,
	KernelParams = KernelParams,
	LARJInterpolationTrace = LARJInterpolationTrace,
	RandomWalkKernel = RandomWalkKernel,
	MultiKernel = MultiKernel,
	LARJKernel = LARJKernel,
	mcmc = mcmc,
	traceMH = traceMH,
	driftMH = driftMH,
	LARJMCMC = LARJMCMC,
	LARJTraceMH = LARJTraceMH,
	LARJDriftMH = LARJDriftMH
}
