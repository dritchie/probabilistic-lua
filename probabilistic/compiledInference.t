local util = require("probabilistic.util")
local mt = require("probabilistic.mathtracing")
local inf = require("probabilistic.inference")


-- Internal sampler state for compiled kernels
local CompiledTraceState = 
{
	properties = 
	{
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
		proposalsMade = 0,
		proposalsAccepted = 0,
		structuralVars = {},
		compiledLogProbFn = nil,
		varBandWidths = nil
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

	-- Get the proposal bandwidth of each nonstructural
	local nonStructVars = currTrace:freeVarNames(false, true)
	self.varBandWidths = terralib.new(double[currState.numVars])
	for i,n in ipairs(nonStructVars) do
		local ann = currTrace:getVarProp(n, "annotation")
		self.varBandWidths[i-1] = self.bandwidthMap[ann] or self.defaultBandwidth
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
	local newState = CompiledTraceState:new(currState.trace, currState)
	local newlp, accepted =
		CompiledGaussianDriftKernel.step(newState.numVars, newState.varVals, self.varBandWidths, currState.logprob,
			self.compiledLogProbFn.definitions[1]:getpointer())
	newState.logprob = newlp
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
	-- trace is in our last-encountered structure and vice-versa
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
	return false
end

function CompiledGaussianDriftKernel:compile(currTrace)
	-- Turn on mathtracing, run traceupdate, and
	-- compile the resulting IR expression into a function
	local savedLP = currTrace.logprob
	mt.setNumberType("double")
	mt.on()
	currTrace:traceUpdate(true)
	mt.off()
	local nonStructVars = currTrace:freeVarNames(false, true)
	local argArray = mt.makeVar("vars", "double*")
	local fnname = string.format("logprob%s", tostring(symbol()))
	local fn = mt.makeFunction(fnname, "double", {argArray}, {currTrace.logprob})
	local C = terralib.includecstring(
		string.format("#include <math.h>\n\n%s", fn:emitCode()))
	self.compiledLogProbFn = C[fnname]
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

--local cstdio = terralib.includec("stdio.h")

-- Performs the MH step by perturbing a randomly-selected variable
-- Returns the new log probability
-- Also returns true if the proposal was accepted 
terra CompiledGaussianDriftKernel.step(numVars : int, vals : &double, bandwidths: &double,
									   currLP: double, lpfn: {&double} -> {double}) : {double, bool}
	-- Pick a random variable
	var i = [int](cstdlib.random() * numVars)
	var v = vals[i]

	-- Perturb
	var newv = gaussian_sample(v, bandwidths[i])
	vals[i] = newv

	-- Accept/reject
	var newLP = lpfn(vals)
	if cmath.log(cstdlib.random()) < newLP - currLP then
		return newLP, true
	else
		vals[i] = v
		return currLP, false
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