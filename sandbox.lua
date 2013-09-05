
local util = require("probabilistic.util")
local gmm = require("models.gmm")
local ising1d = require("models.ising1d")
local ising2d = require("models.ising2d")
local bayesChain = require("models.bayesChain")

math.randomseed(os.time())


local numsamps = 1000
local lag = 1
local verbose = true

local annealIntervals = 100
local annealStepsPerInterval = 20
local temperedTransitionsFreq = 1.0

-----------------------------------------------------------------

-- Running basic experiments

-- local program = ising1d.ising1d
-- local globalSched = ising1d.scheduleGen_ising1d_global
-- local localSched = ising1d.scheduleGen_ising1d_left_to_right
local program = bayesChain.bayesChain
local globalSched = bayesChain.scheduleGen_global
local localSched = bayesChain.scheduleGen_left_to_right

-- Normal inference
print("NORMAL INFERENCE")
local samps_normal = util.map(function(s) return s.returnValue end,
	traceMH(program, {numsamps=numsamps, lag=lag, verbose=verbose}))
local aca_normal = autoCorrelationArea(samps_normal)
print(string.format("Autocorrelation area of samples: %g", aca_normal))

print("------------------")

-- Globally tempered inference
print("GLOBALLY TEMPERED INFERENCE")
local samps_globally_tempered = util.map(function(s) return s.returnValue end,
	TemperedTraceMH(program, {scheduleGenerator=globalSched, temperedTransitionsFreq=temperedTransitionsFreq,
	 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag, verbose=verbose}))
local aca_globally_tempered = autoCorrelationArea(samps_globally_tempered)
print(string.format("Autocorrelation area of samples: %g", aca_globally_tempered))

print("------------------")

-- Locally tempered inference
print("LOCALLY TEMPERED INFERENCE")
local samps_locally_tempered = util.map(function(s) return s.returnValue end,
	TemperedTraceMH(program, {scheduleGenerator=localSched, temperedTransitionsFreq=temperedTransitionsFreq,
	 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag, verbose=verbose}))
local aca_locally_tempered = autoCorrelationArea(samps_locally_tempered)
print(string.format("Autocorrelation area of samples: %g", aca_locally_tempered))


-----------------------------------------------------------------

-- -- Autocorrelation over multiple runs experiment with 1D Ising
-- local program = ising1d.ising1d
-- local runs = 10
-- local acf_normal = {}
-- local acf_global = {}
-- local acf_local = {}

-- for i=1,runs do
-- 	print(i)
-- 	local samps_normal = util.map(function(s) return s.returnValue end,
-- 		traceMH(program, {numsamps=numsamps, lag=lag}))
-- 	acf_normal[i] = autocorrelation(samps_normal)

-- 	local samps_globally_tempered = util.map(function(s) return s.returnValue end,
-- 		TemperedTraceMH(program, {scheduleGenerator=ising1d.scheduleGen_ising1d_global, temperedTransitionsFreq=temperedTransitionsFreq,
-- 		 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
-- 	acf_global[i] = autocorrelation(samps_globally_tempered)

-- 	local samps_locally_tempered = util.map(function(s) return s.returnValue end,
-- 		TemperedTraceMH(program, {scheduleGenerator=ising1d.scheduleGen_ising1d_left_to_right, temperedTransitionsFreq=temperedTransitionsFreq,
-- 		 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
-- 	acf_local[i] = autocorrelation(samps_locally_tempered)
-- end

-- local acf_normal_file = io.open("acf_normal.csv", "w")
-- local acf_global_file = io.open("acf_global.csv", "w")
-- local acf_local_file = io.open("acf_local.csv", "w")
-- for i=1,numsamps do
-- 	acf_normal_file:write(table.concat(util.map(function(s) return s[i] end, acf_normal), ",") .. "\n")
-- 	acf_global_file:write(table.concat(util.map(function(s) return s[i] end, acf_global), ",") .. "\n")
-- 	acf_local_file:write(table.concat(util.map(function(s) return s[i] end, acf_local), ",") .. "\n")
-- end
-- acf_normal_file:close()
-- acf_global_file:close()
-- acf_local_file:close()



-- -- Autocorrelation over multiple runs experiment with 2D Ising
-- local program = ising2d.ising2d
-- local runs = 20
-- local acf_normal = {}
-- local acf_global = {}
-- local acf_local = {}

-- for i=1,runs do
-- 	print(i)
-- 	local samps_normal = util.map(function(s) return s.returnValue end,
-- 		traceMH(program, {numsamps=numsamps, lag=lag}))
-- 	acf_normal[i] = autocorrelation(samps_normal)

-- 	local samps_globally_tempered = util.map(function(s) return s.returnValue end,
-- 		TemperedTraceMH(program, {scheduleGenerator=ising2d.scheduleGen_ising2d_global, temperedTransitionsFreq=temperedTransitionsFreq,
-- 		 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
-- 	acf_global[i] = autocorrelation(samps_globally_tempered)

-- 	local samps_locally_tempered = util.map(function(s) return s.returnValue end,
-- 		TemperedTraceMH(program, {scheduleGenerator=ising2d.scheduleGen_ising2d_zigzag, temperedTransitionsFreq=temperedTransitionsFreq,
-- 		 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
-- 	acf_local[i] = autocorrelation(samps_locally_tempered)
-- end

-- local acf_normal_file = io.open("acf_normal.csv", "w")
-- local acf_global_file = io.open("acf_global.csv", "w")
-- local acf_local_file = io.open("acf_local.csv", "w")
-- for i=1,numsamps do
-- 	acf_normal_file:write(table.concat(util.map(function(s) return s[i] end, acf_normal), ",") .. "\n")
-- 	acf_global_file:write(table.concat(util.map(function(s) return s[i] end, acf_global), ",") .. "\n")
-- 	acf_local_file:write(table.concat(util.map(function(s) return s[i] end, acf_local), ",") .. "\n")
-- end
-- acf_normal_file:close()
-- acf_global_file:close()
-- acf_local_file:close()



-- -- Autocorrelation over multiple runs experiment with Bayes Chain
-- local program = bayesChain.bayesChain
-- local runs = 10
-- local acf_normal = {}
-- local acf_global = {}
-- local acf_local = {}

-- for i=1,runs do
-- 	print(i)
-- 	local samps_normal = util.map(function(s) return s.returnValue end,
-- 		traceMH(program, {numsamps=numsamps, lag=lag}))
-- 	acf_normal[i] = autocorrelation(samps_normal)

-- 	local samps_globally_tempered = util.map(function(s) return s.returnValue end,
-- 		TemperedTraceMH(program, {scheduleGenerator=bayesChain.scheduleGen_global, temperedTransitionsFreq=temperedTransitionsFreq,
-- 		 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
-- 	acf_global[i] = autocorrelation(samps_globally_tempered)

-- 	local samps_locally_tempered = util.map(function(s) return s.returnValue end,
-- 		TemperedTraceMH(program, {scheduleGenerator=bayesChain.scheduleGen_left_to_right, temperedTransitionsFreq=temperedTransitionsFreq,
-- 		 annealIntervals=annealIntervals, annealStepsPerInterval=annealStepsPerInterval, numsamps=numsamps, lag=lag}))
-- 	acf_local[i] = autocorrelation(samps_locally_tempered)
-- end

-- local acf_normal_file = io.open("acf_normal.csv", "w")
-- local acf_global_file = io.open("acf_global.csv", "w")
-- local acf_local_file = io.open("acf_local.csv", "w")
-- for i=1,numsamps do
-- 	acf_normal_file:write(table.concat(util.map(function(s) return s[i] end, acf_normal), ",") .. "\n")
-- 	acf_global_file:write(table.concat(util.map(function(s) return s[i] end, acf_global), ",") .. "\n")
-- 	acf_local_file:write(table.concat(util.map(function(s) return s[i] end, acf_local), ",") .. "\n")
-- end
-- acf_normal_file:close()
-- acf_global_file:close()
-- acf_local_file:close()

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

-- -- Autocorrelation area over anneal steps experiment
-- runs = 5
-- local minSteps = 10
-- local maxSteps = 50
-- local stepsStepSize = 5
-- local aca_normal = {}
-- local aca_global = {}
-- local aca_local = {}

-- local aca_normal_file = io.open("aca_normal.csv", "w")
-- local aca_global_file = io.open("aca_global.csv", "w")
-- local aca_local_file = io.open("aca_local.csv", "w")

-- for i=minSteps,maxSteps,stepsStepSize do
-- 	annealStepsPerInterval = i
-- 	aca_normal[i] = {}
-- 	aca_global[i] = {}
-- 	aca_local[i] = {}
-- 	for j=1,runs do
-- 		print(i, j)
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


-- Render the graphs
--util.wait("Rscript plot.r")