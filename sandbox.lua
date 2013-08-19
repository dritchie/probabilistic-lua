
local pr = require("probabilistic")
local util = require("probabilistic.util")
local random = require("probabilistic.random")
util.openpackage(pr)


-- Version of uniform ERP that doesn't actually contribute to the
-- the log probability, so that we can do inference on distributions
-- that don't actually have 'priors'
local uniformNoLP =
makeERP(random.uniform_sample,
		function() return 0.0 end,
		function(currval, ...) return random.uniform_sample(...) end,
		function(currval, propval, ...) return random.uniform_logprob(propval, ...) end)

--------------------------------

-- Simple test of a multimodal gaussian mixture using
-- a single global temperature.
-- In general, the 'temp' parameter could be a vector of temps.
local uniformPriorMin = -7
local uniformPriorMax = 7
local mixtureWeights = {0.2, 0.5, 0.3}
local means = {-5.3, 0.5, 6.9}
local sds = {0.3, 0.1, 0.5}
--local sds = {4.0, 4.0, 4.0}
local function gmm(temp)
	temp = temp or 1.0
	local x = uniformNoLP({uniformPriorMin, uniformPriorMax})
	local ftor = 0.0
	for i,w in ipairs(mixtureWeights) do
		ftor = ftor + w*math.exp(random.gaussian_logprob(x, means[i], sds[i]))
	end
	factor(temp*math.log(ftor))
	return x
end

local function scheduleGen_gmm(annealStep, numAnnealSteps)
	local a = annealStep/numAnnealSteps
	--local val = 2.0*math.abs(a - 0.5)
	local val = (2.0*a - 1); val = val*val
	return val
end

--------------------------------

-- Simple vector 'class'
local Vector = {}

function Vector:new(valTable)
	setmetatable(valTable, self)
	self.__index = self
	return valTable
end

function Vector:copy()
	return Vector:new(util.copytable(self))
end

-- Assumes v is a Vector; type error otherwise
function Vector:__add(v)
	assert(#self == #v)
	local newVec = self:copy()
	for i,val in ipairs(v) do
		newVec[i] = newVec[i] + val
	end
	return newVec
end

-- Assumes v is a Vector; type error otherwise
function Vector:__sub(v)
	assert(#self == #v)
	local newVec = self:copy()
	for i,val in ipairs(v) do
		newVec[i] = newVec[i] - val
	end
	return newVec
end

-- Assumes s is a number; type error otherwise
function Vector:scalarMult(s)
	local newVec = self:copy()
	for i,val in ipairs(newVec) do
		newVec[i] = val * s
	end
	return newVec
end

-- Assumes v is a Vector; type error otherwise
function Vector:innerProd(v)
	assert(#self == #v)
	local ip = 0.0
	for i,val in ipairs(v) do
		ip = ip + self[i]*val
	end
	return ip
end

-- Assumes n is a Vector or a number; type error otherwise
function Vector:__mul(n)
	if type(n) == "number" then
		return self:scalarMult(n)
	else
		return self:innerProd(n)
	end
end

-- Assumes s is a number; type error otherwise
function Vector:__div(s)
	local newVec = self:copy()
	for i,val in ipairs(newVec) do
		newVec[i] = val / s
	end
	return newVec
end


-- A 1D Ising model
local numSites = 50
local prior = 0.5
local affinity = 20.0
local defaultTemps = replicate(numSites-1, function() return 1.0 end)
local function ising(temps)
	temps = temps or defaultTemps
	local siteVals = replicate(numSites, function() if util.int2bool(flip({prior})) then return 1.0 else return -1.0 end end)
	siteVals = Vector:new(siteVals)
	for i=1,numSites-1 do
		factor(temps[i]*affinity*siteVals[i]*siteVals[i+1])
	end
	return siteVals
end

-- For the time being, just a global annealing schedule
-- (i.e. all temperatures adjusted in lockstep)
local function scheduleGen_ising(annealStep, numAnnealSteps)
	local a = annealStep/numAnnealSteps
	--local val = 2.0*math.abs(a - 0.5)
	local val = (2.0*a - 1); val = val*val
	return replicate(numSites-1, function() return val end)
end

--------------------------------


-- Which experiment to run
----------------------------
-- local program = gmm
-- local scheduleGen = scheduleGen_gmm
local program = ising
local scheduleGen = scheduleGen_ising


print("------------------")

math.randomseed(os.time())

local numsamps = 1000
local lag = 1
local verbose = true

local annealIntervals = 200
local temperedTransitionsFreq = 0.5

-- Normal inference
local samps_normal = util.map(function(s) return s.returnValue end,
	traceMH(program, {numsamps=numsamps, lag=lag, verbose=verbose}))
local aca_normal = autoCorrelationArea(samps_normal)
print("NORMAL INFERENCE")
print(string.format("Autocorrelation area of samples: %g", aca_normal))

print("------------------")

-- Tempered inference
local samps_tempered = util.map(function(s) return s.returnValue end,
	TemperedTraceMH(program, {scheduleGenerator=scheduleGen, temperedTransitionsFreq=temperedTransitionsFreq,
	 annealIntervals=annealIntervals, numsamps=numsamps, lag=lag, verbose=verbose}))
local aca_tempered = autoCorrelationArea(samps_tempered)
print("TEMPERED INFERENCE")
print(string.format("Autocorrelation area of samples: %g", aca_tempered))

