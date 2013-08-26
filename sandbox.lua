
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
local numSites = 10
local prior = 0.5
local affinity = 5.0
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
local function scheduleGen_ising_global(annealStep, maxAnnealStep)
	local a = annealStep/maxAnnealStep
	local val = 2.0*math.abs(a - 0.5)
	--local val = (2.0*a - 1); val = val*val
	return replicate(numSites-1, function() return val end)
end

-- Generates a schedule that lowers site temperatures to 0 from left to right,
-- then raises them back to 1 from right to left
local function scheduleGen_ising_local_left_to_right(annealStep, maxAnnealStep)
	local val = 2 * (math.abs(0.5 - (annealStep)/(maxAnnealStep))) * (numSites-1)
	local decimal = val % 1
	local schedule = {}
	for i=1,val do
		schedule[i] = 1
	end
	if (val - decimal + 1 < numSites) then schedule[val - decimal + 1] = decimal end
	for i=val-decimal+2,numSites-1 do
		schedule[i] = 0
	end
	return schedule
end

--------------------------------


-- Which experiment to run
----------------------------
-- local program = gmm
-- local scheduleGen = scheduleGen_gmm
local program = ising
-- local scheduleGen = scheduleGen_ising_global


print("------------------")

math.randomseed(os.time())

local numsamps = 1000
local lag = 1
local verbose = true

-- local annealIntervals = 200
-- local annealStepsPerInterval = numSites
local annealIntervals = 1000
local annealStepsPerInterval = 1
local temperedTransitionsFreq = 1.0


-----------------------------------------------------------------

-- -- Normal inference
-- print("NORMAL INFERENCE")
-- local samps_normal = util.map(function(s) return s.returnValue end,
-- 	traceMH(program, {numsamps=numsamps, lag=lag, verbose=verbose}))
-- local aca_normal = autoCorrelationArea(samps_normal)
-- print(string.format("Autocorrelation area of samples: %g", aca_normal))

-- print("------------------")

-- -- Globally tempered inference
-- print("GLOBALLY TEMPERED INFERENCE")
-- local samps_globally_tempered = util.map(function(s) return s.returnValue end,
-- 	TemperedTraceMH(program, {scheduleGenerator=scheduleGen_ising_global, temperedTransitionsFreq=temperedTransitionsFreq,
-- 	 annealIntervals=annealIntervals, numsamps=numsamps, lag=lag, verbose=verbose}))
-- local aca_globally_tempered = autoCorrelationArea(samps_globally_tempered)
-- print(string.format("Autocorrelation area of samples: %g", aca_globally_tempered))

-- print("------------------")

-- -- Locally tempered inference
-- print("LOCALLY TEMPERED INFERENCE")
-- local samps_locally_tempered = util.map(function(s) return s.returnValue end,
-- 	TemperedTraceMH(program, {scheduleGenerator=scheduleGen_ising_local_left_to_right, temperedTransitionsFreq=temperedTransitionsFreq,
-- 	 annealIntervals=annealIntervals, numsamps=numsamps, lag=lag, verbose=verbose}))
-- local aca_locally_tempered = autoCorrelationArea(samps_locally_tempered)
-- print(string.format("Autocorrelation area of samples: %g", aca_locally_tempered))


-----------------------------------------------------------------

-- Autocorrelation over multiple runs experiment
local runs = 10
local acf_normal = {}
local acf_global = {}
local acf_local = {}

for i=1,runs do
	print(i)
	local samps_normal = util.map(function(s) return s.returnValue end,
		traceMH(program, {numsamps=numsamps, lag=lag}))
	acf_normal[i] = autocorrelation(samps_normal)

	local samps_globally_tempered = util.map(function(s) return s.returnValue end,
		TemperedTraceMH(program, {scheduleGenerator=scheduleGen_ising_global, temperedTransitionsFreq=temperedTransitionsFreq,
		 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
	acf_global[i] = autocorrelation(samps_globally_tempered)

	local samps_locally_tempered = util.map(function(s) return s.returnValue end,
		TemperedTraceMH(program, {scheduleGenerator=scheduleGen_ising_local_left_to_right, temperedTransitionsFreq=temperedTransitionsFreq,
		 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
	acf_local[i] = autocorrelation(samps_locally_tempered)
end

local acf_normal_file = io.open("acf_normal.csv", "w")
local acf_global_file = io.open("acf_global.csv", "w")
local acf_local_file = io.open("acf_local.csv", "w")
for i=1,numsamps do
	acf_normal_file:write(table.concat(util.map(function(s) return s[i] end, acf_normal), ",") .. "\n")
	acf_global_file:write(table.concat(util.map(function(s) return s[i] end, acf_global), ",") .. "\n")
	acf_local_file:write(table.concat(util.map(function(s) return s[i] end, acf_local), ",") .. "\n")
end
acf_normal_file:close()
acf_global_file:close()
acf_local_file:close()


-----------------------------------------------------------------


-- -- Autocorrelation area over # of sites experiment
-- runs = 10
-- local minSites = 10
-- local maxSites = 100
-- local sitesStepSize = 10
-- local aca_normal = {}
-- local aca_global = {}
-- local aca_local = {}

-- local aca_normal_file = io.open("aca_normal.csv", "w")
-- local aca_global_file = io.open("aca_global.csv", "w")
-- local aca_local_file = io.open("aca_local.csv", "w")

-- for i=minSites,maxSites,sitesStepSize do
-- 	print(i)
-- 	numSites = i
-- 	annealStepsPerInterval = numSites
-- 	aca_normal[i] = {}
-- 	aca_global[i] = {}
-- 	aca_local[i] = {}
-- 	for j=1,runs do
-- 		local samps_normal = util.map(function(s) return s.returnValue end,
-- 			traceMH(program, {numsamps=numsamps, lag=lag}))
-- 		aca_normal[i][j] = autoCorrelationArea(samps_normal)
-- 		local samps_global = util.map(function(s) return s.returnValue end,
-- 			TemperedTraceMH(program, {scheduleGenerator=scheduleGen_ising_global, temperedTransitionsFreq=temperedTransitionsFreq,
-- 			 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
-- 		aca_global[i][j] = autoCorrelationArea(samps_global)

-- 		local samps_local = util.map(function(s) return s.returnValue end,
-- 			TemperedTraceMH(program, {scheduleGenerator=scheduleGen_ising_local_left_to_right, temperedTransitionsFreq=temperedTransitionsFreq,
-- 			 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
-- 		aca_local[i][j] = autoCorrelationArea(samps_local)
-- 	end
-- 	aca_normal_file:write(table.concat(aca_normal[i], ",") .. "\n")
-- 	aca_global_file:write(table.concat(aca_global[i], ",") .. "\n")
-- 	aca_local_file:write(table.concat(aca_local[i], ",") .. "\n")
-- end
-- aca_normal_file:close()
-- aca_global_file:close()
-- aca_local_file:close()



-----------------------------------------------------------------


-- Render the graphs
--util.wait("Rscript plot.r")