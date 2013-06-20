local util = require("probabilistic.util")
local mt = terralib.require("probabilistic.mathtracing")
local cmath = terralib.require("probabilistic.cmath")
local trace = require("probabilistic.trace")
local inf = require("probabilistic.inference")
local prof = require("probabilistic.profiling")


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


-- An MCMC kernel that performs continuious gaussian drift
-- by JIT-compiling all proposal/probability calculations
-- into machine code
-- NOTE: This is a fixed-dimensionality inference kernel (it will not make
--    structural changes)
local CompiledGaussianDriftKernel = {}

-- Default parameter values
inf.KernelParams.bandwidthMap = {}
inf.KernelParams.defaultBandwidth = 0.1
inf.KernelParams.cacheSize = 10

-- 'bandwidthMap' stores a map from type identifiers to gaussian drift bandwidths
-- The type identifers are assumed to be used in the ERP 'annotation' fields
-- 'defaultBandwidth' is the bandwidth to use if an ERP has no type annotation
function CompiledGaussianDriftKernel:new(bandwidthMap, defaultBandwidth, cacheSize)
	local newobj = 
	{
		-- Proposal bandwidth stuff
		bandwidthMap = bandwidthMap,
		defaultBandwidth = defaultBandwidth,

		-- Current compiled stuff as well as cached compiled results
		currStructuralSigs = {},
		currStepFn = nil,
		compileCache = CompiledTraceCache:new(cacheSize),

		-- Analytics
		proposalsMade = 0,
		proposalsAccepted = 0
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function CompiledGaussianDriftKernel:assumeControl(currTrace)
	-- Translate trace into internal state
	prof.startTimer("TraceToStateConversion")
	local currState = currTrace:newCompiledState()
	prof.stopTimer("TraceToStateConversion")

	-- Check for structure change/need recompile
	self:compile(currState)

	return currState
end

function CompiledGaussianDriftKernel:releaseControl(currState)
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

function CompiledGaussianDriftKernel:next(currState, hyperparams)
	-- Create a new state to transition to
	local newState = currState.trace:newCompiledState(currState)

	-- Call the step function to advance the state
	local accepted = false
	local newLPdata = nil
	accepted, newLPdata = self.currStepFn(newState, hyperparams)
	self.proposalsMade = self.proposalsMade + 1
	accepted = util.int2bool(accepted)
	if accepted then
		newState:setLogprob(newLPdata)
		self.proposalsAccepted = self.proposalsAccepted + 1
	end
	return newState
end

function CompiledGaussianDriftKernel:compile(currState)
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

	-- Turn on mathtracing and run traceupdate to
	-- generate IR for the log probability expression
	-- Compile the log prob expression into a function and also get the
	-- list of additional parameters expected by this function.
	mt.setRealNumberType(double)
	local fn = nil
	local paramVars = nil
	fn, paramVars = mt.compileLogProbTrace(currTrace)
	prof.startTimer("LogProbCompile")
	fn, paramVars = currState:finalizeLogprobFn(fn, paramVars)
	fn:compile()
	prof.stopTimer("LogProbCompile")

	-- Generate a specialized step function
	prof.startTimer("StepFunctionCompile")
	self.currStepFn = self:genStepFunction(numVars, paramVars, fn, bandwidths)
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

local C = terralib.includec("stdio.h")
function CompiledGaussianDriftKernel:genStepFunction(numVars, paramVars, lpfn, bandwidths)
	-- Additional argument list
	local arglist = util.map(function(v) return v.value end, paramVars)

	-- The compiled Terra function
	local step = 
		terra(vals: &double, currLP: double, [arglist])
			-- Pick a random variable
			var i = [int](random() * [numVars])
			var v = vals[i]

			-- Perturb
			var newv = gaussian_sample(v, [bandwidths][i])
			vals[i] = newv

			-- Accept/reject
			var lpdata = [lpfn](vals, [arglist])
			if cmath.log(random()) < lpdata.logprob - currLP then
				return true, lpdata
			else
				vals[i] = v
				return false, lpdata
			end
		end

	-- Compile it right now (for more accurate profiling info)
	step:compile()

	-- A Lua wrapper around the Terra function that calls it with the appropriate
	-- additional hyperparameters
	return function(state, hyperparams)
		local additionalArgs = {}
		if hyperparams then
			additionalArgs = util.map(function(pvar) return hyperparams[pvar:name()]:getValue() end, paramVars)
		end
		return step(state.varVals, state.logprob, unpack(additionalArgs))
	end
end

function CompiledGaussianDriftKernel:stats()
	print(string.format("Acceptance ratio: %g (%u/%u)", self.proposalsAccepted/self.proposalsMade,
														self.proposalsAccepted, self.proposalsMade))
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

-- Module exports
return
{
	driftMH_JIT = driftMH_JIT,
	LARJDriftMH_JIT = LARJDriftMH_JIT
}