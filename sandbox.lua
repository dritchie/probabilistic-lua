
pr = require("probabilistic")
util = require("probabilistic.util")
random = require("probabilistic.random")
util.openpackage(pr)

local function circleOfDots(numDots, fweight)

	-- helpers
	local function norm(v)
		return math.sqrt(v.x*v.x + v.y*v.y)
	end
	local function dist(p1, p2)
		local xdiff = p1.x - p2.x
		local ydiff = p1.y - p2.y
		return math.sqrt(xdiff*xdiff + ydiff*ydiff)
	end
	local function angDP(p1, p2, p3)
		local v1 = { x = p1.x - p2.x, y = p1.y - p2.y}
		local v2 = { x = p3.x - p2.x, y = p3.y - p2.y}
		return (v1.x*v2.x + v1.y*v2.y) / (norm(v1)*norm(v2))
	end

	-- params
	local gmean = 0
	local gsd = 2
	local targetdist = 0.5
	local distsd = 0.1
	local targetdp = -1.0
	local dpsd = 0.1
	local targetcx = 1
	local targetcy = 1
	local csd = 0.1

	-- prior
	local points = {}
	for i=1,numDots do
		table.insert(points, { x = gaussian({gmean, gsd}), y = gaussian({gmean, gsd}) })
	end

	-- -- distance between pairs factors
	-- for i=0,numDots-1 do
	-- 	local j = ((i+1) % numDots) + 1
	-- 	local d = dist(points[i+1], points[j])
	-- 	local f = random.gaussian_logprob(d, targetdist, distsd)
	-- 	factor(fweight*f)
	-- end

	-- -- angle between triples factors
	-- for i=0,numDots-1 do
	-- 	local j = ((i+1) % numDots)+1
	-- 	local k = ((i+2) % numDots)+1
	-- 	local dp = angDP(points[i+1], points[j], points[k])
	-- 	local f = random.gaussian_logprob(dp, targetdp, dpsd)
	-- 	factor(fweight*f)
	-- end

	-- centroid
	local cx = 0
	local cy = 0
	for i,p in ipairs(points) do
		cx = cx + p.x
		cy = cy + p.y
	end
	cx = cx / numDots
	cy = cy / numDots
	local f = random.gaussian_logprob(cx, targetcx, csd)
	factor(fweight*f)
	f = random.gaussian_logprob(cy, targetcy, csd)
	factor(fweight*f)

	return points
end

local function makeFixedDimensionProgram(numDots, fweight)
	return function()
		return circleOfDots(numDots, fweight)
	end
end

local function makeTransdimensionalProgram(dims, fweight)
	return function()
		local numDots = uniformDraw(dims, {isStructural=true})
		return circleOfDots(numDots, fweight)
	end
end

-----------

local function genCachePerfGraph(filename, maxDim, minCacheSize, cacheStep, startSamps, endSamps, sampStep, fweightStart, fweightEnd, fweightMul)
	print("Generating statistics for cache performance graph...")
	local outfile = io.open(filename, "w")
	outfile:write("sampler type,num samples,factor weight,% traces not in cache,wall clock time\n")
	local dims = {}
	for i=minCacheSize,maxDim do table.insert(dims, i) end
	for numsamps=startSamps, endSamps, sampStep do
		local fweight = fweightStart
		while fweight > fweightEnd do
			local computation = makeTransdimensionalProgram(dims, fweight)
			-- Run the uncompiled sampler
			io.write(string.format("numsamps: %d, fweight: %g, uncompiled                 \r", numsamps, fweight))
			local t1 = os.clock()
			LARJDriftMH(computation, {numsamps=numsamps, defaultBandwidth=0.25})
			local t2 = os.clock()
			outfile:write(string.format("Uncompiled,%d,%g,N/A,%g\n", numsamps, fweight, t2-t1))
			-- Run the compiled sampler for different cache sizes
			for cacheSize=maxDim, minCacheSize, -cacheStep do
				io.write(string.format("numsamps: %d, fweight: %g, cacheSize: %d\r", numsamps, fweight, cacheSize))
				local percentNotInCache = (maxDim-cacheSize) / maxDim
				local t1 = os.clock()
				LARJDriftMH_JIT(computation, {numsamps=numsamps, defaultBandwidth=0.25, cacheSize=cacheSize})
				local t2 = os.clock()
				outfile:write(string.format("Compiled,%d,%g,%g,%g\n", numsamps, fweight, percentNotInCache, t2-t1))
			end
			fweight = fweight * fweightMul
		end
	end
	io.write("\n")
	outfile:close()
end

local function genAnnealingPerfGraph(filename, numsamples, dims, annealStepsStart, annealStepsEnd, annealStepsMul)
	print("Generating statistics for annealing performance graph...")
	local outfile = io.open(filename, "w")
	outfile:write("sampler type,num anneal steps,wall clock time\n")
	local computation = makeTransdimensionalProgram(dims, 0.5)
	local cacheSize = 2*table.getn(dims)	-- Enough cache to store all possible traces
	local annealSteps = annealStepsStart
	while annealSteps < annealStepsEnd do
		io.write(string.format("annealing steps: %d\r", annealSteps))
		-- Run the uncompiled sampler
		local t1 = os.clock()
		LARJDriftMH(computation, {numsamps=numsamples, defaultBandwidth=0.25, annealSteps=annealSteps})
		local t2 = os.clock()
		outfile:write(string.format("Uncompiled,%d,%g\n", annealSteps, t2 - t1))
		-- Run the compiled sampler
		local t1 = os.clock()
		LARJDriftMH_JIT(computation, {numsamps=numsamples, defaultBandwidth=0.25, annealSteps=annealSteps, cacheSize=cacheSize})
		local t2 = os.clock()
		outfile:write(string.format("Compiled,%d,%g\n", annealSteps, t2 - t1))
		annealSteps = annealSteps * annealStepsMul
	end
	io.write("\n")
	outfile:close()
end

local function genProfilingStats(filename, numsamples, dims, fweight, cacheSize)
	print("Generating profiling stats...")
	local computation = makeTransdimensionalProgram(dims, fweight)
	local prof = require("probabilistic.profiling")
	prof.toggleProfiling(true)
	LARJDriftMH_JIT(computation, {numsamps=numsamples, defaultBandwidth=0.25, cacheSize=cacheSize})
	prof.toggleProfiling(false)
	local profile = prof.getTimingProfile()
	local outfile = io.open(filename, "w")
	outfile:write("task,wall clock time\n")
	outfile:write(string.format("CacheLookup,%g\n", profile["CacheLookup"]))
	outfile:write(string.format("TraceUpdate,%g\n", profile["NormalTraceUpdate"]))
	outfile:write(string.format("IRGenOverhead,%g\n", profile["IRGeneration"] - profile["NormalTraceUpdate"]))
	outfile:write(string.format("LogProbCompile,%g\n", profile["LogProbCompile"]))
	outfile:write(string.format("TraceToStateConversion,%g\n", profile["TraceToStateConversion"]))
	outfile:write(string.format("StepFunctionCompile,%g\n", profile["StepFunctionCompile"]))
	outfile:close()
end

--genCachePerfGraph("Tableau/cachePerf/cachePerf.csv", 7, 3, 1, 10000, 100000, 10000, 1.0, 0.001, 0.5)
--genAnnealingPerfGraph("Tableau/annealingPerf/annealingPerf.csv", 10000, {3, 4, 5, 6, 7}, 10, 1000, 2)
--genProfilingStats("Tableau/profiling/profiling.csv", 100000, {3, 4, 5, 6, 7, 8, 9, 10}, 0.01, 3)

-------

--local numsamps = 100000
local numsamps = 1000
local annealIntervals = 100
local annealSteps = 20
local minGlobalTemp = 0.1
local dots = 4
local dims = {4, 5, 6, 7, 8}
local fweight = 1.0

local res = nil

local t11 = os.clock()
---- GAUSSIAN DRIFT ----
--res = MAP(makeFixedDimensionProgram(dots,fweight), driftMH, {numsamps=numsamps, verbose=true, defaultBandwidth=0.25})
--res = MAP(makeTransdimensionalProgram(dims,fweight), LARJDriftMH, {numsamps=numsamps, verbose=true, defaultBandwidth=0.25})
--res = MAP(makeTransdimensionalProgram(dims,fweight), LARJDriftMH, {numsamps=numsamps, verbose=true, annealIntervals=annealIntervals, annealStepsPerInterval=annealSteps, minGlobalTemp=minGlobalTemp, jumpFreq=0.01, defaultBandwidth=0.25})

---- HMC ----
--res = MAP(makeFixedDimensionProgram(dots,fweight), HMC, {numsamps=numsamps, verbose=true})
--res = MAP(makeTransdimensionalProgram(dims,fweight), LARJHMC, {numsamps=numsamps, jumpFreq=0.01, verbose=true})
res = MAP(makeTransdimensionalProgram(dims,fweight), LARJHMC, {numsamps=numsamps, annealIntervals=annealIntervals, annealStepsPerInterval=annealSteps, minGlobalTemp=minGlobalTemp, jumpFreq=0.01, verbose=true})
local t12 = os.clock()


local t21 = os.clock()

---- GAUSSIAN DRIFT ----
--res = MAP(makeFixedDimensionProgram(dots,fweight), driftMH_JIT, {numsamps=numsamps, verbose=true, defaultBandwidth=0.25})
--res = MAP(makeTransdimensionalProgram(dims,fweight), LARJDriftMH_JIT, {numsamps=numsamps, verbose=true, defaultBandwidth=0.25})
--res = MAP(makeTransdimensionalProgram(dims,fweight), LARJDriftMH_JIT, {numsamps=numsamps, verbose=true, annealIntervals=annealIntervals, annealStepsPerInterval=annealSteps, minGlobalTemp=minGlobalTemp, defaultBandwidth=0.25})

---- HMC ----
--res = MAP(makeFixedDimensionProgram(dots,fweight), HMC_JIT, {numsamps=numsamps, verbose=true})
local t22 = os.clock()

print(string.format("Uncompiled: %g", (t12 - t11)))
print(string.format("Compiled: %g", (t22 - t21)))


local function saveDotCSV(points, filename)
	local f = io.open(filename, "w")
	f:write("dotnum,x,y\n")
	for i,p in ipairs(points) do
		f:write(string.format("%u,%g,%g\n", i, p.x, p.y))
	end
	f:close()
end

saveDotCSV(res, "Tableau/dotvis/dots.csv")
