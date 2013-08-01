local util = require("probabilistic.util")
local mt = terralib.require("probabilistic.mathtracing")
local cmath = terralib.require("probabilistic.cmath")
local trace = require("probabilistic.trace")
local inf = require("probabilistic.inference")
local prof = require("probabilistic.profiling")
local hmc = terralib.require("probabilistic.hmc")
local ffi = require("ffi")


-- Internal sampler state for compiled trace
local CompiledTraceState = {}

local function computeReturnValueOnDemand(self)
	if not self.retval then
		local nonStructNames = self.trace:freeVarNames(false, true)
		for i,n in ipairs(nonStructNames) do
			self.trace:getRecord(n):setProp("val", self.varVals[i-1])
		end
		-- We don't need to evaluate expensive factors just to reconstruct
		-- the return value
		self.trace:toggleFactorEval(false)
		self.trace:traceUpdate(true)
		self.trace:toggleFactorEval(true)
		self.retval = self.trace.returnValue
	end
	return self.retval
end

function CompiledTraceState:new(trace, other)
	local newobj = nil
	if other then
		newobj = 
		{
			trace = trace,
			numVars = other.numVars,
			varVals = terralib.new(double[other.numVars], other.varVals)
		}
	else
		local nonStructNames = trace:freeVarNames(false, true)
		local numNonStruct = table.getn(nonStructNames)
		newobj = 
		{
			trace = trace,
			numVars = numNonStruct,
			varVals = terralib.new(double[numNonStruct])
		}
		for i,n in ipairs(nonStructNames) do
			newobj.varVals[i-1] = trace:getRecord(n):getProp("val")
		end
	end
	setmetatable(newobj, self)
	return newobj
end

-- Internal sampler state for normal (single) compiled traces
local SingleCompiledTraceState = {}
setmetatable(SingleCompiledTraceState, {__index = CompiledTraceState})

util.addReadonlyProperty(SingleCompiledTraceState, "returnValue", computeReturnValueOnDemand)

function SingleCompiledTraceState:new(trace, other)
	local newobj = CompiledTraceState.new(self, trace, other)
	if other then
		newobj.logprob = other.logprob
	else
		newobj.logprob = trace.logprob
	end
	return newobj
end

function SingleCompiledTraceState:setLogprob(lpdata)
	self.logprob = lpdata.logprob
	if type(self.logprob) ~= "number" then
		self.logprob = hmc.getValue(self.logprob)
	end
end

-- Make the trace know how to convert itself into a compiled state
function trace.RandomExecutionTrace:newCompiledState(other)
	return SingleCompiledTraceState:new(self, other)
end

-- Make the trace know how to generate the IR for its logprob expression(s)
function trace.RandomExecutionTrace:traceLogprobExp()
	self:traceUpdate(true)
	return self.logprob
end

-- The state may need to do some extra work to the compiled logprob function
function SingleCompiledTraceState:finalizeLogprobFn(lpfn, paramVars)
	local arglist = util.map(function(v) return v.value end, paramVars)
	local realnum = mt.realNumberType()
	local struct LPData { logprob: realnum }
	local terra lpWrapper(vals: &realnum, [arglist])
		var lpd: LPData
		lpd.logprob = lpfn(vals, [arglist])
		return lpd
	end
	return lpWrapper, paramVars
end


-- Internal sampler state for LARJ annealing compiled traces
LARJInterpolationCompiledTraceState = {}
setmetatable(LARJInterpolationCompiledTraceState, {__index = CompiledTraceState})

util.addReadonlyProperty(LARJInterpolationCompiledTraceState, "returnValue", computeReturnValueOnDemand)
util.addReadonlyProperty(LARJInterpolationCompiledTraceState, "logprob",
	function(self)
		local a = self.trace.alpha:getValue()
		return (1-a)*self.logprob1 + a*self.logprob2
	end
)

function LARJInterpolationCompiledTraceState:new(trace, other)
	local newobj = CompiledTraceState.new(self, trace, other)
	if other then
		newobj.logprob1 = other.logprob1
		newobj.logprob2 = other.logprob2
	else
		newobj.logprob1 = trace.trace1.logprob
		newobj.logprob2 = trace.trace2.logprob
	end
	return newobj
end

function LARJInterpolationCompiledTraceState:setLogprob(lpdata)
	self.logprob1 = lpdata.logprob1
	self.logprob2 = lpdata.logprob2
	if type(self.logprob1) ~= "number" then
		self.logprob1 = hmc.getValue(self.logprob1)
		self.logprob2 = hmc.getValue(self.logprob2)
	end
end

-- Make the trace know how to convert itself into a compiled state
function inf.LARJInterpolationTrace:newCompiledState(other)
	return LARJInterpolationCompiledTraceState:new(self, other)
end

-- Make the trace know how to generate the IR for its logprob expression(s)
function inf.LARJInterpolationTrace:traceLogprobExp()
	self:traceUpdate(true)
	return self.trace1.logprob, self.trace2.logprob
end

-- The state may need to do some extra work to the compiled logprob function
function LARJInterpolationCompiledTraceState:finalizeLogprobFn(lpfn, paramVars)
	local realnum = mt.realNumberType()
	local arglist = util.map(function(v) return v.value end, paramVars)
	local lpAlpha = self.trace.alpha:getIRNode()
	table.insert(paramVars, lpAlpha)
	local arglistWithAlpha = util.map(function(v) return v.value end, paramVars)
	local struct LPData { logprob: realnum, logprob1: realnum, logprob2: realnum }
	local terra lpWrapper(vals: &realnum, [arglistWithAlpha])
		var lpd : LPData
		lpd.logprob1, lpd.logprob2 = lpfn(vals, [arglist])
		lpd.logprob = (1.0 - [lpAlpha.value])*lpd.logprob1 + [lpAlpha.value]*lpd.logprob2
		return lpd
	end
	return lpWrapper, paramVars
end



-- A cache for compiled traces
local CompiledTraceCache = {}

function CompiledTraceCache:new(size)
	size = size or 10
	local newobj = 
	{
		maxSize = size,
		currSize = 0,
		cache = {}
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function CompiledTraceCache:lookup(signatures)
	for i,s in ipairs(signatures) do
		local entry = self.cache[s]
		if entry then
			return entry.fn
		end
	end
	return nil
end

function CompiledTraceCache:add(signatures, fn)
	local n = table.getn(signatures)
	if self.currSize + n > self.maxSize then
		for i=1,n do
			self:evictLRU()
		end
	end
	local entry = 
	{
		fn = fn,
		timestamp = os.clock()
	}
	for i,s in ipairs(signatures) do
		self.cache[s] = entry
	end
	self.currSize = self.currSize + n
end

function CompiledTraceCache:evictLRU()
	local earliestTime = math.huge
	local earliestSig = nil
	for s,e in pairs(self.cache) do
		if e.timestamp < earliestTime then
			earliestTime = e.timestamp
			earliestSig = s
		end
	end
	self.cache[earliestSig] = nil
	self.currSize = self.currSize-1
end


-- Abstract base class for fixed-dimension MCMC kernels that perform inference
-- by compiling traces
local CompiledKernel = {}

-- Default parameter values
inf.KernelParams.cacheSize = 10

function CompiledKernel:new(cacheSize)
	local newobj = 
	{
		-- Current compiled stuff as well as cached compiled results
		currStructuralSigs = {},
		currStepFn = nil,
		compileCache = CompiledTraceCache:new(cacheSize),

		-- Stuff for abstracting the log prob function
		currHyperParams = nil,
		currLpData = nil,

		-- Analytics
		proposalsMade = 0,
		proposalsAccepted = 0
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function CompiledKernel:assumeControl(currTrace)
	-- Translate trace into internal state
	prof.startTimer("TraceToStateConversion")
	local currState = currTrace:newCompiledState()
	prof.stopTimer("TraceToStateConversion")

	-- Check for structure change/need recompile
	self:compile(currState)

	return currState
end

function CompiledKernel:releaseControl(currState)
	-- Make a new copy of the trace, since we might be modifying it
	local newTrace = currState.trace:deepcopy()

	-- Copy the var values back into the trace
	local nonStructVars = newTrace:freeVarNames(false, true)
	for i,n in ipairs(nonStructVars) do
		newTrace:getRecord(n):setProp("val", currState.varVals[i-1])
	end
	-- Run a full trace update to push these new values through
	-- the computation
	newTrace:traceUpdate(true)
	return newTrace
end

function CompiledKernel:next(currState, hyperparams)
	-- Create a new state to transition to
	local newState = currState.trace:newCompiledState(currState)

	-- Call the step function to advance the state
	local accepted = self.currStepFn(newState, hyperparams)
	self.proposalsMade = self.proposalsMade + 1
	if accepted then
		newState:setLogprob(self.currLpData)
		self.proposalsAccepted = self.proposalsAccepted + 1
	end
	return newState
end

function CompiledKernel:compile(currState)
	local currTrace = currState.trace
	local sigs = currTrace:structuralSignatures()
	-- Look for an already-compiled trace in the cache
	prof.startTimer("CacheLookup")
	local fn = self.compileCache:lookup(sigs)
	prof.stopTimer("CacheLookup")
	if fn then
		self.currStepFn = fn
	else
		self:doCompile(currState)
		self.compileCache:add(sigs, self.currStepFn)
	end
	self.currStructuralSigs = sigs
end

function CompiledKernel:compileLogProbFunction(currState, realNumType)
	-- Turn on mathtracing and run traceupdate to
	-- generate IR for the log probability expression
	-- Compile the log prob expression into a function and also get the
	-- list of additional parameters expected by this function.
	mt.setRealNumberType(realNumType)
	local fn = nil
	local paramVars = nil
	fn, paramVars = mt.compileLogProbTrace(currState.trace)
	prof.startTimer("LogProbCompile")
	fn, paramVars = currState:finalizeLogprobFn(fn, paramVars)
	fn:compile()

	-- Wrap the logprob function to abstract away the use of hyperparameters
	-- and a structured return type
	local LPData = fn.definitions[1]:gettype().returns[1]
	local terra derefLPData(lpdptr: &LPData)
		return @lpdptr
	end
	local function setCurrLpData(lpdtr)
		self.currLpData = derefLPData(lpdtr)
	end
	local function genLpFnCall(vals)
		if #paramVars == 0 then
			return `fn(vals)
		else
			local gchpReturnType = {}
			for i=1,#paramVars do table.insert(gchpReturnType, double) end
			local function getCurrHyperParams()
				return unpack(self.currHyperParams)
			end
			getCurrHyperParams = terralib.cast({} -> gchpReturnType, getCurrHyperParams)
			return `fn(vals, getCurrHyperParams())
		end
	end
	local fnwrapper = terra(vals: &realNumType)
		var lpd = [genLpFnCall(vals)]
		setCurrLpData(&lpd)
		var lp = lpd.logprob
		return lp
	end
	prof.stopTimer("LogProbCompile")

	return fnwrapper, paramVars
end

function CompiledKernel:setCurrHyperParams(paramVars, hyperparams)
	self.currHyperParams = {}
	for i,pvar in ipairs(paramVars) do
		table.insert(self.currHyperParams, hyperparams[pvar:name()]:getValue())
	end
end

function CompiledKernel:wrapStepFunction(stepfn, paramVars)
	-- A Lua wrapper around the Terra function that calls it with the appropriate
	-- additional hyperparameters
	return function(state, hyperparams)
		if hyperparams then
			self:setCurrHyperParams(paramVars, hyperparams)
		end
		local retval = stepfn(state.varVals, state.logprob)
		self.currHyperParams = nil
		return retval
	end
end

function CompiledKernel:stats()
	print(string.format("Acceptance ratio: %g (%u/%u)", self.proposalsAccepted/self.proposalsMade,
														self.proposalsAccepted, self.proposalsMade))
end

function CompiledKernel:tellLARJStatus(alpha, oldVarNames, newVarNames)
	-- Default is to do nothing
end


-- An MCMC kernel that performs continuious gaussian drift
-- by JIT-compiling all proposal/probability calculations
-- into machine code
local CompiledGaussianDriftKernel = {}
setmetatable(CompiledGaussianDriftKernel, {__index = CompiledKernel})

-- Default parameter values
inf.KernelParams.bandwidthMap = {}
inf.KernelParams.defaultBandwidth = 0.1

-- 'bandwidthMap' stores a map from type identifiers to gaussian drift bandwidths
-- The type identifers are assumed to be used in the ERP 'annotation' fields
-- 'defaultBandwidth' is the bandwidth to use if an ERP has no type annotation
function CompiledGaussianDriftKernel:new(bandwidthMap, defaultBandwidth, cacheSize)
	local newobj = CompiledKernel.new(self, cacheSize)

	newobj.bandwidthMap = bandwidthMap
	newobj.defaultBandwidth = defaultBandwidth

	return newobj
end

function CompiledGaussianDriftKernel:doCompile(currState)
	local currTrace = currState.trace

	-- Get the proposal bandwidth of each nonstructural
	local nonStructVars = currTrace:freeVarNames(false, true)
	local numVars = table.getn(nonStructVars)
	local bandwidths = terralib.new(double[numVars])
	for i,n in ipairs(nonStructVars) do
		local ann = currTrace:getRecord(n):getProp("annotation")
		bandwidths[i-1] = self.bandwidthMap[ann] or self.defaultBandwidth
	end

	-- Compile the log prob function
	local lpfn
	local paramVars
	lpfn, paramVars = self:compileLogProbFunction(currState, double)

	-- Generate a specialized step function
	prof.startTimer("StepFunctionCompile")
	self.currStepFn = self:wrapStepFunction(self:genStepFunction(numVars, lpfn, bandwidths), paramVars)
	prof.stopTimer("StepFunctionCompile")
end

-- Terra version of erp.lua's "gaussian_sample"
local cstdlib = terralib.includecstring [[
	#include <stdlib.h>
	#define FLT_RAND_MAX 0.999999
	double random_() { return ((double)(rand()) / RAND_MAX)*FLT_RAND_MAX; }
]]
local random = cstdlib.random_
--local random = terralib.cast({} -> double, math.random)
local terra gaussian_sample(mu : double, sigma: double) : double
	var u : double
	var v : double
	var x : double
	var y : double
	var q : double
	repeat
		u = 1 - random()
		v = 1.7156 * (random() - 0.5)
		x = u - 0.449871
		y = cmath.fabs(v) + 0.386595
		q = x*x + y*(0.196*y - 0.25472*x)
	until not(q >= 0.27597 and (q > 0.27846 or v*v > -4 * u * u * cmath.log(u)))
	return mu + sigma*v/u
end

function CompiledGaussianDriftKernel:genStepFunction(numVars, lpfn, bandwidths)
	-- The compiled Terra function
	local step = 
		terra(vals: &double, currLP: double)
			-- Pick a random variable
			var i = [int](random() * [numVars])
			var v = vals[i]

			var bw : double = bandwidths[i]
			var newv = gaussian_sample(v, bw)
			vals[i] = newv

			-- Accept/reject
			var newLP = lpfn(vals)
			if cmath.log(random()) < newLP - currLP then
				return true
			else
				vals[i] = v
				return false
			end
		end

	-- Compile it right now (for more accurate profiling info)
	step:compile()

	return step
end


-- An MCMC kernel that performs Hamiltonian Monte Carlo
-- using the No-U-Turn sampler implementation provided by the
-- stan MCMC library (on compiled traces)
local CompiledHMCKernel = {}
setmetatable(CompiledHMCKernel, {__index = CompiledKernel})

-- No default parameters needed

function CompiledHMCKernel:new(cacheSize)
	local newobj = CompiledKernel.new(self, cacheSize)

	newobj.sampler = hmc.newSampler()
	ffi.gc(newobj.sampler, function(self) hmc.deleteSampler(self) end)

	return newobj
end

function CompiledHMCKernel:doCompile(currState)
	local currTrace = currState.trace

	-- Compile the log prob function
	local lpfn
	local paramVars
	lpfn, paramVars = self:compileLogProbFunction(currState, hmc.num)
	self.lpfn = lpfn 	-- We *MUST* anchor this function like this or it'll get GC'ed!!!
	hmc.setLogprobFunction(self.sampler, lpfn.definitions[1]:getpointer())

	-- Generate a specialized step function
	prof.startTimer("StepFunctionCompile")
	local normalStepFn = self:wrapStepFunction(self:genStepFunction(), paramVars)
	self.currStepFn = function(state, hyperparams)
		if not self.initialized then
			self.initialized = true
			self:setCurrHyperParams(paramVars, hyperparams)
			hmc.setVariableValues(self.sampler, state.numVars, state.varVals)
		end
		return normalStepFn(state, hyperparams)
	end
	prof.stopTimer("StepFunctionCompile")

	self.initialized = false
end

function CompiledHMCKernel:genStepFunction()
	-- The compiled Terra function
	local step = 
		terra(vals: &double, currLP: double)
			var accepted = hmc.nextSample([self.sampler], vals)
			return [bool](accepted)
		end

	-- Compile it right now (for more accurate profiling info)
	step:compile()

	return step
end


-- (This is not really a 'compiled' kernel, but it uses Terra code, so it makes
--  more sense to put it here than in inference.lua)
-- MCMC kernel that does HMC for fixed-structure collections of continuous
-- random variables.
local HMCKernel = {}

-- No default parameters needed

function HMCKernel:new()
	local newobj = 
	{
		proposalsMade = 0,
		proposalsAccepted = 0,
		sampler = hmc.newSampler()
	}
	ffi.gc(newobj.sampler, function(self) hmc.deleteSampler(self) end)

	setmetatable(newobj, self)
	self.__index = self

	newobj.lpfn = newobj:makeLogProbFn()
	hmc.setLogprobFunction(newobj.sampler, newobj.lpfn.definitions[1]:getpointer())

	return newobj
end

function HMCKernel:assumeControl(currTrace)

	self.currentTrace = currTrace:deepcopy()

	local nonStructNames = self.currentTrace:freeVarNames(false, true)
	local numVars = #nonStructNames
	self.numVars = numVars
	self.nonStructNames = nonStructNames
	self.varVals = terralib.new(double[numVars])
	for i,n in pairs(nonStructNames) do
		self.varVals[i-1] = self.currentTrace:getRecord(n):getProp("val")
	end

	self.setNonStructValues = function(aTrace, varVals)
		for i,n in ipairs(nonStructNames) do
			aTrace:getRecord(n):setProp("val", varVals[i-1])
		end
	end

	hmc.setVariableValues(self.sampler, numVars, self.varVals)

	self.currentTrace = currTrace
	return self.currentTrace
end

function HMCKernel:releaseControl(currState)
	return currState
end

function HMCKernel:next(currState, hyperparams)

	-- We need to do this, or else the sampler's "current logprob"
	-- will be stale since it was calculated using the previous annealing alpha,
	-- not the current one.
	if self.annealing then
		hmc.recomputeLogProb(self.sampler)
	end

	-- -- For some reason, adaptation during annealing drives the step
	-- -- size toward a very small value. Turning it off for now.
	-- if self.annealing then
	-- 	hmc.toggleStepSizeAdaptation(self.sampler, 0)
	-- else
	-- 	hmc.toggleStepSizeAdaptation(self.sampler, 1)
	-- end

	self.currentTrace = currState:deepcopy()
	local accepted = util.int2bool(hmc.nextSample(self.sampler, self.varVals))
	self.proposalsMade = self.proposalsMade + 1
	if accepted then
		self.proposalsAccepted = self.proposalsAccepted + 1
	end

	-- Run traceUpdate once more to flush the dual numbers out of the trace
	-- and update valid return values / log probs
	-- This also makes sure that the values in the trace reflect the correct
	-- (most recently accepted) state, and not simply the state from the last
	-- time the log prob function was called.
	self.setNonStructValues(self.currentTrace, self.varVals)
	self.currentTrace:flushLogProbs()

	return self.currentTrace
end

function HMCKernel:makeLogProbFn()
	local this = self
	local function lpfn(varVals)
		-- Copy dual number values into the trace, run traceupdate
		local aTrace = this.currentTrace
		this.setNonStructValues(aTrace, varVals)
		hmc.toggleLuaAD(true)
		aTrace:flushLogProbs()
		-- We return the inner implementation of the dual num, because
		-- Lua functions called from Terra cannot return aggregates by value
		local retval = aTrace.logprob.impl
		hmc.toggleLuaAD(false)
		return retval
	end

	lpfn = terralib.cast({&hmc.num} -> {&uint8}, lpfn)
	return terra(varVals: &hmc.num)
		var impl = lpfn(varVals)
		return hmc.num { impl }
	end
end

function HMCKernel:stats()
	print(string.format("Acceptance ratio: %g (%u/%u)", self.proposalsAccepted/self.proposalsMade,
													self.proposalsAccepted, self.proposalsMade))
end

function HMCKernel:tellLARJStatus(alpha, oldVarNames, newVarNames)
	-- We need to adjust the mass of certain variables based on alpha.
	local oldVarSet = util.listToSet(oldVarNames)
	local newVarSet = util.listToSet(newVarNames)
	local invmasses = terralib.new(double[self.numVars], 1.0)
	local oldScale = (1.0-alpha)
	local newScale = alpha
	for i,n in ipairs(self.nonStructNames) do
		if oldVarSet[n] then
			invmasses[i-1] = oldScale
		elseif newVarSet[n] then
			invmasses[i-1] = newScale
		end
	end
	hmc.setVariableInvMasses(self.sampler, invmasses)

	-- -- DEBUG: print gradients
	-- if #newVarNames > 0 then
	-- 	hmc.togglePrintGradients(self.sampler, 1)
	-- else
	-- 	hmc.togglePrintGradients(self.sampler, 0)
	-- end
end




-- Sample from a fixed-structure probabilistic computation for some
-- number of iterations using compiled Gaussian drift MH
local function driftMH_JIT(computation, params)
	params = inf.KernelParams:new(params)
	return inf.mcmc(computation,
					CompiledGaussianDriftKernel:new(params.bandwidthMap, params.defaultBandwidth, params.cacheSize),
					params)
end

-- Sample from a probabilistic computation using LARJMCMC, with an
-- inner kernel that runs compiled Gaussian drift MH
local function LARJDriftMH_JIT(computation, params)
	params = inf.KernelParams:new(params)
	return inf.mcmc(computation,
					inf.LARJKernel:new(
						CompiledGaussianDriftKernel:new(params.bandwidthMap, params.defaultBandwidth, params.cacheSize),
						params.annealSteps, params.jumpFreq),
					params)
end

-- Sample from a fixed-structure probabilistic computation
-- using HMC
local function HMC_JIT(computation, params)
	params = inf.KernelParams:new(params)
	return inf.mcmc(computation,
					CompiledHMCKernel:new(params.cacheSize),
					params)
end

-- Sample from a probabilistic computation using LARJMCMC, with an
-- inner kernel that runs compiled HMC.
local function LARJHMC_JIT(computation, params)
	params = inf.KernelParams:new(params)
	return inf.mcmc(computation,
					inf.LARJKernel:new(
						CompiledHMCKernel:new(params.cacheSize),
						params.annealSteps, params.jumpFreq),
					params)
end

local function HMC(computation, params)
	params = inf.KernelParams:new(params)
	return inf.mcmc(computation,
					HMCKernel:new(),
					params)
end

local function LARJHMC(computation, params)
	params = inf.KernelParams:new(params)
	return inf.mcmc(computation,
					inf.LARJKernel:new(
						HMCKernel:new(),
						params.annealSteps, params.jumpFreq),
					params)
end

-- Module exports
return
{
	driftMH_JIT = driftMH_JIT,
	LARJDriftMH_JIT = LARJDriftMH_JIT,
	HMC_JIT = HMC_JIT,
	LARJHMC_JIT = LARJHMC_JIT,
	HMC = HMC,
	LARJHMC = LARJHMC
}



