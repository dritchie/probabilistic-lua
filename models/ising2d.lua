local pr = require("probabilistic")
local util = require("probabilistic.util")
util.openpackage(pr)

local Vector = require("models.vector")

-- A 2D Ising model
local numSiteRows = 6
local numSiteCols = 6
local prior2d = 0.5
local affinity2d = 20.0
local function replicate2d(numrows, numcols, proc)
	return replicate(numrows, function() return replicate(numcols, proc) end)
end

local function uniformTemps2d(temp)
	temps = {}
	temps["rowtemps"] = replicate2d(numSiteRows, numSiteCols-1, function() return temp end)
	temps["coltemps"] = replicate2d(numSiteRows-1, numSiteCols, function() return temp end)
	return temps
end

local function reshape2d_to_1d(t)
	new = {}
	for k1,v1 in pairs(t) do
		for k2,v2 in pairs(v1) do
			table.insert(new, v2)
		end
	end
	return new
end

local function ising2d(temps)
	temps = temps or uniformTemps2d(1.0)
	local siteVals = replicate2d(numSiteRows, numSiteCols, function() if util.int2bool(flip({prior2d})) then return 1.0 else return -1.0 end end)
	for i=1,numSiteRows do
		for j=1,numSiteCols-1 do
			factor(temps["rowtemps"][i][j]*affinity2d*siteVals[i][j]*siteVals[i][j+1])
		end
	end
	for i=1,numSiteRows-1 do
		for j=1,numSiteCols do
			factor(temps["coltemps"][i][j]*affinity2d*siteVals[i][j]*siteVals[i+1][j])
		end
	end
	return Vector:new(reshape2d_to_1d(siteVals))
end


local function scheduleGen_ising2d_global(annealStep, maxAnnealStep)
	local a = annealStep/maxAnnealStep
	--local val = 2.0*math.abs(a - 0.5)
	local val = (2.0*a - 1); val = val*val
	return uniformTemps2d(val)
end

local function scheduleGen_ising2d_zigzag(annealStep, maxAnnealStep)
	-- This is written in a form that iteratively "withdraws" temperature along a zigzag.
	local val = 2 * (0.5 - (math.abs(0.5 - (annealStep-1) / (maxAnnealStep-1)))) * (numSiteRows * numSiteCols)
	local temps = uniformTemps2d(1.0)
	-- return temps
	for i=1,numSiteRows do
		if (val == 0) then break end
		for j=1,numSiteCols do
			if (val == 0) then break end
			
			local withdrawl = math.min(1, val)
			val = val - withdrawl

			if (j < numSiteCols) then
				local col = j
				if (i % 2 == 0) then col = numSiteCols - col end
				temps["rowtemps"][i][col] = 1 - withdrawl
			end

			if (i > 1) then
				local col = j
				if (i % 2 == 0) then col = numSiteCols + 1 - col end
				temps["coltemps"][i-1][col] = 1 - withdrawl
			end
		end
	end
	return temps
end


return 
{
	ising2d = ising2d,
	scheduleGen_ising2d_global = scheduleGen_ising2d_global,
	scheduleGen_ising2d_zigzag = scheduleGen_ising2d_zigzag
}