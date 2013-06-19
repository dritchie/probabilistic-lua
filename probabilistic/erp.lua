local trace = require("probabilistic.trace")
local util = require("probabilistic.util")
local random = require("probabilistic.random")


local RandomPrimitive =
{
	-- This is the actual, publically-exposed sampling function that user code calls
	__call =
	function(self, paramTable, modifierTable)
		-- We pass '0' ass the 4th arg because alls to this function, as well
		-- as 'lookupVariableValue,' are tail calls
		return trace.lookupVariableValue(self, paramTable,
			modifierTable and modifierTable.isStructural or nil,
			0,
			modifierTable and modifierTable.conditionedValue or nil,
			modifierTable and modifierTable.annotation or nil)
	end
}

-- The last two can be nil, in which case the raw sampler and proposer are used.
function RandomPrimitive:new(samplingFn, logprobFn, proposalFn, logProposalProbFn)
	assert(samplingFn)
	assert(logprobFn)
	local newobj =
	{
		samplingFn = samplingFn,
		logprobFn = logprobFn,
		proposalFn = proposalFn or
		function(currval, ...)
			return samplingFn(...)
		end,
		logProposalProbFn = logProposalProbFn or
		function(currval, propval, ...)
			return logprobFn(propval, ...)
		end
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

local function makeERP(samplingFn, logprobFn, proposalFn, logProposalProbFn)
	return RandomPrimitive:new(samplingFn, logprobFn, proposalFn, logProposalProbFn)
end

function RandomPrimitive:sample(params)
	return self.samplingFn(unpack(params))
end

function RandomPrimitive:logprob(val, params)
	return self.logprobFn(val, unpack(params))
end

function RandomPrimitive:proposal(currval, params)
	return self.proposalFn(currval, unpack(params))
end

function RandomPrimitive:logProposalProb(currval, propval, params)
	return self.logProposalProbFn(currval, propval, unpack(params))
end


-- Make ERPs for common random number types, export them --

local erp = {}

erp.flip =
makeERP(random.flip_sample,
		random.flip_logprob,
		function(currval, p) return (currval == 0) and 1 or 0 end,
		function(currval, propval, p) return 0 end)

erp.uniform =
makeERP(random.uniform_sample,
		random.uniform_logprob)

erp.multinomial = 
makeERP(random.multinomial_sample,
		random.multinomial_logprob,
		function(currval, ...)
			local newparams = util.copytable({...})
			newparams[currval] = 0
			return random.multinomial_sample(unpack(newparams))
		end,
		function(currval, propval, ...)
			local newparams = util.copytable({...})
			newparams[currval] = 0
			return random.multinomial_logprob(propval, unpack(newparams))
		end)

function erp.multinomialDraw(items, probs, modifierTable)
	return items[multinomial(probs, modifierTable)]
end

function erp.uniformDraw(items, modifierTable)
	local n = table.getn(items)
	local invn = 1/n
	local probs = {}
	for i=1,n do
		table.insert(probs, invn)
	end
	return items[multinomial(probs, modifierTable)]
end

erp.gaussian = 
makeERP(random.gaussian_sample,
		random.gaussian_logprob,
		function(currval, mu, sigma)
			return random.gaussian_sample(currval, sigma)
		end,
		function(currval, propval, mu, sigma)
			return random.gaussian_logprob(propval, currval, sigma)
		end)

erp.gamma =
makeERP(random.gamma_sample,
		random.gamma_logprob)

erp.beta =
makeERP(random.beta_sample,
		random.beta_logprob)

erp.binomial =
makeERP(random.binomial_sample,
		random.binomial_logprob)

erp.poisson =
makeERP(random.poisson_sample,
		random.poisson_logprob)

erp.dirichlet =
makeERP(random.dirichlet_sample,
		random.dirichlet_logprob)

return erp

