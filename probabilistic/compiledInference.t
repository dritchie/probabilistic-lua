local util = require("probabilistic.util")
local mt = terralib.require("probabilistic.mathtracing")
local inf = require("probabilistic.inference")


-- Internal sampler state for compiled kernels
local CompiledTraceState = 
{
	properties = 
	{
		-- Construct the return value of the computation only
		-- if/when it is requested.
		returnValue =
		function(self)
			if not self.retval then
				local nonStructNames = self.trace:freeVarNames(false, true)
				for i,n in ipairs(nonStructNames) do
					self.trace:setVarProp(n, "val", self.varVals[i-1])
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
	}
}

function CompiledTraceState:__index(key)
	local v = CompiledTraceState[key]
	if v ~= nil then
		return v
	else
		local propfn = CompiledTraceState.properties[key]
		if propfn then
			return propfn(self)
		else
			return nil
		end
	end
end

function CompiledTraceState:new(trace, other)
	local newobj = nil
	if other then
		newobj = 
		{
			trace = trace,
			logprob = other.logprob,
			numVars = other.numVars,
			varVals = terralib.new(double[other.numVars], other.varVals)
		}
	else
		local nonStructNames = trace:freeVarNames(false, true)
		local numNonStruct = table.getn(nonStructNames)
		newobj = 
		{
			trace = trace,
			logprob = trace.logprob,
			numVars = numNonStruct,
			varVals = terralib.new(double[numNonStruct])
		}
		for i,n in ipairs(nonStructNames) do
			newobj.varVals[i-1] = trace:getVarProp(n, "val")
		end
	end
	setmetatable(newobj, self)
	return newobj
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
	local currState = CompiledTraceState:new(currTrace)

	-- Check for structure change/need recompile
	self:compile(currTrace)

	return currState
end

function CompiledGaussianDriftKernel:releaseControl(currState)
	-- Make a new copy of the trace, since we might be modifying it
	local newTrace = currState.trace:deepcopy()

	-- Copy the var values back into the trace
	local nonStructVars = newTrace:freeVarNames(false, true)
	for i,n in ipairs(nonStructVars) do
		newTrace:setVarProp(n, "val", currState.varVals[i-1])
	end
	-- Run a full trace update to push these new values through
	-- the computation
	newTrace:traceUpdate(true)
	return newTrace
end

function CompiledGaussianDriftKernel:next(currState, hyperparams)
	-- Create a new state to transition to
	local newState = CompiledTraceState:new(currState.trace, currState)

	-- Call the step function to advance the state
	local accepted = false
	newState.logprob, accepted = self.currStepFn(newState, hyperparams)

	-- Update analytics and continue
	self.proposalsMade = self.proposalsMade + 1
	accepted = util.int2bool(accepted)
	if accepted then
		self.proposalsAccepted = self.proposalsAccepted + 1
	end
	return newState
end

function CompiledGaussianDriftKernel:compile(currTrace)
	local sigs = currTrace:structuralSignatures()
	-- Look for an already-compiled trace in the cache
	local fn = self.compileCache:lookup(sigs)
	if fn then
		self.currStepFn = fn
	else
		self:doCompile(currTrace)
		self.compileCache:add(sigs, self.currStepFn)
	end
	self.currStructuralSigs = sigs
end

function CompiledGaussianDriftKernel:doCompile(currTrace)

	-- Get the proposal bandwidth of each nonstructural
	local nonStructVars = currTrace:freeVarNames(false, true)
	local numVars = table.getn(nonStructVars)
	local bandwidths = terralib.new(double[numVars])
	for i,n in ipairs(nonStructVars) do
		local ann = currTrace:getVarProp(n, "annotation")
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

	-- Generate a specialized step function
	self.currStepFn = self:genStepFunction(numVars, paramVars, fn, bandwidths)
end

-- Terra version of erp.lua's "gaussian_sample"
local cmath = terralib.includec("math.h")
local cstdlib = terralib.includecstring [[
	#include <stdlib.h>
	#define FLT_RAND_MAX 0.999999
	double random() { return ((double)(rand()) / RAND_MAX)*FLT_RAND_MAX; }
]]
--local random = cstdlib.random
local random = terralib.cast({} -> double, math.random)
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
			var newLP = [lpfn](vals, [arglist])
			if cmath.log(random()) < newLP - currLP then
				return newLP, true
			else
				vals[i] = v
				return currLP, false
			end
		end

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