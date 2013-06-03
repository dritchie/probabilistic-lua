local util = require("util")
local mt = require("mathtracing")
local inf = require("inference")


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
		compiledLogProbFn = nil
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function CompiledGaussianDriftKernel:next(currTrace)
	
	-- Check for structure change/need recompile
	if self:needsRecompile(currTrace) then
		self:compile(currTrace)
	end

	-- Get the nonstructurals, extract their values and bandwidths
	local nonStructVars = currTrace.freeVarNames(false, true)
	local numVars = table.getn(nonStructVars)
	local valArray = terralib.new(double[numVars])
	local bwArray = terralib.new(double[numVars])
	for i,n in nonStructVars do
		local rec = currTrace.getRecord(n)
		valArray[i-1] = rec.val
		bwArray[i-1] = self.bandwidthMap[rec.annotation] or self.defaultBandwidth
	end

	-- Call the step function
	local newlp, accepted =
		CompiledGaussianDriftKernel.step(numVars, valArray, bwArray, currTrace.logprob,
			self.compiledLogProbFn.definitions[1]:getpointer())
	self.proposalsMade = self.proposalsMade + 1
	if accepted then
		self.proposalsAccepted = self.proposalsAccepted + 1
	end

	-- Copy values back into the trace
	for i=1,numVars do
		currTrace.getRecord(nonStructVars[i]).val = valArray[i-1]
	end
	currTrace.logprob = newlp

	return currTrace
end

function CompiledGaussianDriftKernel:needsRecompile(currTrace)
	if not self.compiledLogProbFn then
		return true
	end
	-- Check if every variable from the current
	-- trace is in our last-encountered structure and vice-versa
	local svarnames = currTrace.freeVarNames(true, false)
	-- Direction 1: Is every struct. var in the current trace also in
	-- our last-encountered structure?
	for i,n in svarnames do
		if not self.structuralVars[n] then
			return true
		end
	end
	-- Direction 2: Is every var in our last encountered structure
	-- also in the current trace?
	for n,v in self.structuralVars do
		if not currTrace.getRecord(n) then
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
	currTrace.traceUpdate(true)
	mt.off()
	local nonStructVars = currTrace.freeVarNames(false, true)
	local argArray = mt.makeVar("vars", "double*")
	local fn = mt.makeFunction("logprob", "double", {argArray}, {currTrace.logprob})
	local C = terralib.includecstring(
		string.format("#include <math.h>\n\n%s", fn:emitCode()))
	self.compiledLogProbFn = C.logprob
	currTrace.logprob = savedLP
end

-- Terra version of erp.lua's "gaussian_sample"
local cmath = terralib.includec("math.h")
local cstdlib = terralib.includecstring [[
	#include <stdlib.h>
	double random() { return (double)(rand()) / RAND_MAX; }
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

-- Performs the MH step by perturbing a randomly-selected variable
-- Returns the new log probability
-- Also returns true if the proposal was accepted 
terra CompiledGaussianDriftKernel.step(numVars : int, vals : &double, bandwidths: &double,
									   currLP: double, lpfn: &double -> double) : {double, bool}
	-- Pick a random variable
	var i = [int](cstdlib.random() / numVars)
	var v = vals[i]

	-- Perturb
	var newv = gaussian_sample(v, bandwidths[i])
	vals[i] = newv

	-- Accept/reject
	var newLP = lpfn(vals)
	if cstdlib.random() > newLP / currLP then
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
function fixedStructureDriftMH(computation, bandwidthMap, defaultBandwidth, numsamps, lag, verbose)
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