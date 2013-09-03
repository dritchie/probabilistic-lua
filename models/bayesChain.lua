local pr = require("probabilistic")
local util = require("probabilistic.util")
util.openpackage(pr)

local random = require("probabilistic.random")
local Vector = require("models.vector")

-- A multinomial prior whose logprobs can be tempered
-- The temperature is stored as the first parameter
local temperedMultinomial =
makeERP(function(temp, ...)	-- Sampling fn
			--print(select("#", ...))
			return random.multinomial_sample(...)
		end,
		function(val, temp, ...) -- Logprob fn
			return temp*random.multinomial_logprob(val, ...)
		end,
		function(currval, temp, ...) -- Proposal fn
			local newparams = util.copytable({...})
			newparams[currval] = 0
			return random.multinomial_sample(unpack(newparams))
		end,
		function(currval, propval, temp, ...) -- Log proposal prob fn
			local newparams = util.copytable({...})
			newparams[currval] = 0
			return random.multinomial_logprob(propval, unpack(newparams))
		end)
local function temperedMultinomialDraw(items, probs, temp)
	local p = util.copytable(probs)
	table.insert(p, 1, temp)
	return items[temperedMultinomial(p)]
end


-- A discrete, linear Bayes Net.
-- The variable domain is the same size as the number of variables.
-- The joint distribution is bimodal, where the two modes are:
--    1, 2, 3, ... , N  and
--    N, N-1, ...  , 1
-- The first variable's prior is strongly bimodal on 1 or N.
-- The rest of the variables are essentially deterministic conditioned
--   on their parents.
-- Theoretically, the first variable locks down the whole system, so an
--   annealing schedule that goes 1-to-N should be able to do better than
--   a global schedule.
local numVariables = 10
local couplingStrength = 0.45
local function buildVarTables()
	local tables = {}

	-- Table for var 1 is a 1d (prior) table
	local modemass = couplingStrength*2
	local v1table = replicate(numVariables, function() return (1.0-modemass)/(numVariables-2) end)
	v1table[1] = couplingStrength
	v1table[numVariables] = couplingStrength
	table.insert(tables, v1table)

	-- Tables for other vars condition on parents (2d tables)
	for i=2,numVariables do
		-- All CPDs uniform except for those when parent
		-- takes on value i-1 or N-(i-1)
		local vtable = replicate(numVariables, function() return replicate(numVariables, function() return 1.0/numVariables end) end)
		local itable = replicate(numVariables, function() return (1.0-modemass)/(numVariables-1) end)
		itable[i] = modemass
		local nminusitable = replicate(numVariables, function() return (1.0-modemass)/(numVariables-1) end)
		nminusitable[numVariables-i+1] = modemass
		vtable[i-1] = itable
		vtable[numVariables-(i-1)+1] = nminusitable
		table.insert(tables, vtable)
	end

	return tables
end
local varTables = buildVarTables()
local domain = {}; for i=1,numVariables do table.insert(domain, i) end
local defaultTemps = replicate(numVariables, function () return 1.0 end)
local function bayesChain(temps)
	temps = temps or defaultTemps
	local vals = {}
	table.insert(vals, temperedMultinomialDraw(domain, varTables[1], temps[1]))
	for i=2,numVariables do
		local parent = vals[i-1]
		local cpd = varTables[i][parent]
		table.insert(vals, temperedMultinomialDraw(domain, cpd, temps[i]))
	end
	return Vector:new(vals)
end

local function scheduleGen_global(annealStep, maxAnnealStep)
	local a = annealStep/maxAnnealStep
	local val = 2.0*math.abs(a - 0.5)
	return replicate(numVariables, function() return val end)
end

local function scheduleGen_left_to_right(annealStep, maxAnnealStep)
	local val = 2 * (math.abs(0.5 - (annealStep)/(maxAnnealStep))) * numVariables
	local decimal = val % 1
	local schedule = {}
	for i=1,val do
		schedule[i] = 1
	end
	if (val - decimal + 1 <= numVariables) then schedule[val - decimal + 1] = decimal end
	for i=val-decimal+2,numVariables do
		schedule[i] = 0
	end
	-- print("-----")
	-- for i,v in ipairs(schedule) do print(v) end
	return schedule
end



return
{
	bayesChain = bayesChain,
	scheduleGen_global = scheduleGen_global,
	scheduleGen_left_to_right = scheduleGen_left_to_right
}



