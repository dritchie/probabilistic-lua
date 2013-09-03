local pr = require("probabilistic")
local util = require("probabilistic.util")
util.openpackage(pr)

local Vector = require("models.vector")


-- A 1D Ising model
local numSites = 10
-- local numSites = 4
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

-- A 1D Ising model with varying affinities
local possibleAffinities = {1.0, 5.0, 10.0, 20.0}
local affinities = replicate(numSites-1, function() return uniformDraw(possibleAffinities) end)
local function isingVarying(temps)
	temps = temps or defaultTemps
	local siteVals = replicate(numSites, function() if util.int2bool(flip({prior})) then return 1.0 else return -1.0 end end)
	siteVals = Vector:new(siteVals)
	for i=1,numSites-1 do
		factor(temps[i]*affinities[i]*siteVals[i]*siteVals[i+1])
	end
	return siteVals
end



-- Global annealing schedule
-- (i.e. all temperatures adjusted in lockstep)
local function scheduleGen_ising_global(annealStep, maxAnnealStep)
	local a = annealStep/maxAnnealStep
	local val = 2.0*math.abs(a - 0.5)
	--local val = (2.0*a - 1); val = val*val
	return replicate(numSites-1, function() return val end)
end

-- Generates a schedule that lowers site temperatures to 0 from left to right,
-- then raises them back to 1 from right to left
local function scheduleGen_ising_left_to_right(annealStep, maxAnnealStep)
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
	-- print("-----")
	-- for i,v in ipairs(schedule) do print(v) end
	return schedule
end

-- Generates a schedule that lowers site temperatures to 0 from inside out,
-- then raises them back to 1 from outside in.
local function scheduleGen_ising_inside_out(annealStep, maxAnnealStep)
	local val = 2 * (math.abs(0.5 - (annealStep)/(maxAnnealStep))) * math.floor(numSites/2)
	local decimal = val % 1
	local schedule = {}
	for i=1,numSites-1 do
		schedule[i] = 1
	end
	local intVal = val-decimal+1
	local middleLink = math.floor(numSites/2)
	local lowerLink = middleLink - (middleLink - intVal)
	local upperLink = middleLink + (middleLink - intVal)
	if (intVal <= middleLink) then
		schedule[lowerLink] = decimal
		schedule[upperLink] = decimal
	end
	for i=lowerLink+1,middleLink,1 do
		schedule[i] = 0
	end
	for i=upperLink-1,middleLink,-1 do
		schedule[i] = 0
	end
	-- print("-----")
	-- for i,v in ipairs(schedule) do print(v) end
	return schedule
end

-- Annealing schedule that changes annealing speed based on the
-- strength of the affinity (strong links anneal more slowly)
local function scheduleGen_ising_affinity_based(annealStep, maxAnnealStep)
	local maxAffinity = math.max(unpack(possibleAffinities))
	local alpha = annealStep/maxAnnealStep
	local schedule = {}
	for i=1,numSites-1 do
		local aff = affinities[i]
		local multiplier = maxAffinity/aff
		local firstZero = 0.5/multiplier
		local secondZero = 0.5 + (0.5 - firstZero)
		local val = 0.0
		if alpha <= firstZero then
			val = 2.0*math.abs(multiplier*(alpha-firstZero))
		elseif alpha >= secondZero then
			val = 2.0*math.abs(multiplier*(alpha-secondZero))
		end
		schedule[i] = val
	end
	-- print("-----")
	-- for i,v in ipairs(schedule) do print(v) end
	return schedule
end


return
{
	ising1d = ising,
	ising1dVarying = isingVarying,
	scheduleGen_ising1d_global = scheduleGen_ising_global,
	scheduleGen_ising1d_left_to_right = scheduleGen_ising_left_to_right,
	scheduleGen_ising1d_inside_out = scheduleGen_ising_inside_out,
	scheduleGen_ising1d_affinity_based = scheduleGen_ising_affinity_based
}


