local util = require("probabilistic.util")
local mt = require("probabilistic.mathtracing")
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
				-- TODO: denote that we're not accumulating probabilities or evaluating factors here?
				self.trace:traceUpdate(true)
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


-- An MCMC kernel that performs fixed-structure gaussian drift
-- by JIT-compiling all proposal/probability calculations
-- into machine code
local CompiledGaussianDriftKernel = {}

-- 'bandwidthMap' stores a map from type identifiers to gaussian drift bandwidths
-- The type identifers are assumed to be used in the ERP 'annotation' fields
-- 'defaultBandwidth' is the bandwidth to use if an ERP has no type annotation
function CompiledGaussianDriftKernel:new(bandwidthMap, defaultBandwidth)
	local newobj = 
	{
		bandwidthMap = bandwidthMap,
		defaultBandwidth = defaultBandwidth,

		structuralVars = {},
		stepfn = nil,
		additionalParams = {},

		proposalsMade = 0,
		proposalsAccepted = 0
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function CompiledGaussianDriftKernel:usesMathtracing()
	return true
end

function CompiledGaussianDriftKernel:assumeControl(currTrace)
	-- Translate trace into internal state
	local currState = CompiledTraceState:new(currTrace)

	-- Check for structure change/need recompile
	-- TODO: Implement caching of compiled traces?
	if self:needsRecompile(currTrace) then
		self:compile(currTrace)
	end

	return currState
end

function CompiledGaussianDriftKernel:releaseControl(currState)
	-- Make a new copy of the trace, since we might be modifying it
	local newTrace = currState.trace:deepcopy()

	-- Copy the var values and logprob back into the trace
	newTrace.logprob = currState.logprob
	local nonStructVars = newTrace:freeVarNames(false, true)
	for i,n in ipairs(nonStructVars) do
		newTrace:setVarProp(n, "val", currState.varVals[i-1])
	end
	return newTrace
end

function CompiledGaussianDriftKernel:next(currState)
	-- Create a new state to transition to
	local newState = CompiledTraceState:new(currState.trace, currState)

	-- Prepare the additional arguments expected by the step function
	-- We assume that the values for these arguments have been added to this
	-- object under the correct names.
	local additionalArgs = util.map(function(param) return self[param] end, self.additionalParams)

	-- Call the step function to advance the state
	local newlp, accepted = self.stepfn(newState.varVals, currState.logprob, unpack(additionalArgs))
	newState.logprob = newlp

	-- Update analytics and continue
	self.proposalsMade = self.proposalsMade + 1
	accepted = util.int2bool(accepted)
	if accepted then
		self.proposalsAccepted = self.proposalsAccepted + 1
	end
	return newState
end

function CompiledGaussianDriftKernel:needsRecompile(currTrace)
	if not self.compiledLogProbFn then
		return true
	end
	-- Check if every variable from the current
	-- trace is in our last-encountered structure and vice-versa,
	-- and that those variables have the same value
	local svarnames = currTrace:freeVarNames(true, false)
	-- Direction 1: Is every struct. var in the current trace also in
	-- our last-encountered structure?
	for i,n in ipairs(svarnames) do
		if not self.structuralVars[n] then
			return true
		end
	end
	-- Direction 2: Is every var in our last encountered structure
	-- also in the current trace?
	for n,v in pairs(self.structuralVars) do
		if not currTrace:hasVar(n) then
			return true
		end
	end
	-- We have the same set of variables. Are their values also the same?
	for n,v in pairs(self.structuralVars) do
		if v.val ~= currTrace:getVarProp(n, "val") then
			return true
		end
	end
	-- We're good; no recompile needed
	return false
end

-- Callable object that, when passed to IRNode.traverse,
-- collects all non-random variable nodes
local FindNonRandomVariablesVisitor =
{
	__call =
	function(self, node)
		if node.isRandomVariable ~= nil and not node.isRandomVariable then
			table.insert(self.vars, node)
		end
	end
}

function FindNonRandomVariablesVisitor:new()
	local newobj =
	{
		vars = {}
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function CompiledGaussianDriftKernel:compile(currTrace)

	-- Get the proposal bandwidth of each nonstructural
	local nonStructVars = currTrace:freeVarNames(false, true)
	local numVars = table.getn(nonStructVars)
	local bandwidths = terralib.new(double[numVars])
	for i,n in ipairs(nonStructVars) do
		local ann = currTrace:getVarProp(n, "annotation")
		bandwidths[i-1] = self.bandwidthMap[ann] or self.defaultBandwidth
	end

	-- Save current logprob value, as we're about to clobber it
	local savedLP = currTrace.logprob

	-- Turn on mathtracing and run traceupdate to
	-- generate IR for the log probability expression
	mt.setNumberType(double)
	mt.on()
	currTrace:traceUpdate(true)
	mt.off()

	-- Look for all non-random variables in the log prob expression
	-- These will become additional parameters to our specialized step function
	local visitor = FindNonRandomVariablesVisitor:new()
	mt.IRTraverse(currTrace.logprob, visitor)
	self.additionalParams = util.map(function(v) return v.name end, visitor.vars)

	-- Generate a specialized logprob function that accepts each of these
	-- as an additional argument
	local fnargs = util.copytable(visitor.vars)
	table.insert(fnargs, mt.makeVar("vars", "double*", false))
	local fnname = string.format("logprob%s", tostring(symbol()))
	local fn = mt.makeFunction(fnname, "double", fnargs, {currTrace.logprob})
	local C = terralib.includecstring(string.format("#include <math.h>\n\n%s", fn:emitCode()))

	-- Generate a specialized step function that accepts each of these
	-- as an additional argument
	self.stepfn = self:genStepFunction(numVars, visitor.vars, C[fnname], bandwidths)

	-- Restore original logprob value
	currTrace.logprob = savedLP
end


-- Terra version of erp.lua's "gaussian_sample"
local cmath = terralib.includec("math.h")
local cstdlib = terralib.includecstring [[
	#include <stdlib.h>
	#define FLT_RAND_MAX 0.999999
	double random() { return ((double)(rand()) / RAND_MAX)*FLT_RAND_MAX; }
]]
local terra gaussian_sample(mu : double, sigma: double) : double
	var u : double
	var v : double
	var x : double
	var y : double
	var q : double
	repeat
		u = 1 - cstdlib.random()
		v = 1.7156 * (cstdlib.random() - 0.5)
		x = u - 0.449871
		y = cmath.fabs(v) + 0.386595
		q = x*x + y*(0.196*y - 0.25472*x)
	until not(q >= 0.27597 and (q > 0.27846 or v*v > -4 * u * u * cmath.log(u)))
	return mu + sigma*v/u
end

function CompiledGaussianDriftKernel:genStepFunction(numVars, nonRandVars, lpfn, bandwidths)
	-- Additional argument list
	local arglist = util.map(function(v) return symbol(v.type) end, nonRandVars)

	-- The overall function expression
	return 
		terra(vals: &double, currLP: double, [arglist])
			-- Pick a random variable
			var i = [int](cstdlib.random() * [numVars])
			var v = vals[i]

			-- Perturb
			var newv = gaussian_sample(v, [bandwidths][i])
			vals[i] = newv

			-- Accept/reject
			var newLP = [lpfn](vals, [arglist])
			if cmath.log(cstdlib.random()) < newLP - currLP then
				return newLP, true
			else
				vals[i] = v
				return currLP, false
			end
		end
end

function CompiledGaussianDriftKernel:stats()
	print(string.format("Acceptance ratio: %g (%u/%u)", self.proposalsAccepted/self.proposalsMade,
														self.proposalsAccepted, self.proposalsMade))
end


-- Sample from a fixed-structure probabilistic computation for some
-- number of iterations using compiled Gaussian drift MH
local function fixedStructureDriftMH(computation, numsamps, bandwidthMap, defaultBandwidth, lag, verbose)
	lag = (lag == nil) and 1 or lag
	return inf.mcmc(computation,
					CompiledGaussianDriftKernel:new(bandwidthMap, defaultBandwidth),
					numsamps, lag, verbose)
end


-- Module exports
return
{
	fixedStructureDriftMH = fixedStructureDriftMH	
}