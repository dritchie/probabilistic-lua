local trace = require "probabilistic.trace"
local control = require "probabilistic.control"

module(..., package.seeall)

-- Code for computing log probabilities should be converted to Terra functions

-- Abstract base class for all ERPs
local RandomPrimitive = {}

function RandomPrimitive:new()
	local newobj = {}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function RandomPrimitive:sample_impl(params)
	error("ERP subclasses must implement sample_impl!")
end

function RandomPrimitive:logprob(val, params)
	error("ERP subclasses must implement logprob!")
end

function RandomPrimitive:sample(params, isStructural, conditionedValue)
	-- Assumes sample is called from one function higher (flip, gaussian, etc.)
	return trace.lookupVariableValue(self, params, isStructural, 2, conditionedValue)
end

function RandomPrimitive:proposal(currval, params)
	-- Subclasses can override to do more efficient proposals
	return self:sample_impl(params)
end

function RandomPrimitive:logProposalProb(currval, propval, params)
	-- Subclasses can override to do more efficient proposals
	return self:logprob(propval, params)
end

-------------------

local FlipRandomPrimitive = RandomPrimitive:new()

function FlipRandomPrimitive:sample_impl(params)
	local randval = math.random()
	return (randval < params[1]) and 1 or 0
end

function FlipRandomPrimitive:logprob(val, params)
	local p = params[1]
	local prob = (val ~= 0) and p or 1.0-p
	return math.log(prob)
end

function FlipRandomPrimitive:proposal(currval, params)
	return (currval == 0) and 1 or 0
end

function FlipRandomPrimitive:logProposalProb(currval, propval, params)
	return 0.0
end

local flipInst = FlipRandomPrimitive:new()
function flip(p, isStructural, conditionedValue)
	p = (p == nil) and 0.5 or p
	return flipInst:sample({p}, isStructural, conditionedValue)
end

-------------------

local MultinomialRandomPrimitive = RandomPrimitive:new()

function multinomial_sample(theta)
	local result = 1
	local x = math.random() * util.sum(theta)
	local probAccum = 0.00000001
	local k = table.getn(theta)
	while result < k and x > probAccum do
		probAccum = probAccum + theta[result]
		result = result + 1
	end
	return result - 1
end

function multinomial_logprob(n, theta)
	if n < 1 or n > table.getn(theta) then
		return -math.huge
	else
		n = math.ceil(n)
		return math.log(theta[n]/util.sum(theta))
	end
end

function MultinomialRandomPrimitive:sample_impl(params)
	return multinomial_sample(params)
end

function MultinomialRandomPrimitive:logprob(val, params)
	return multinomial_logprob(val, params)
end

-- Multinomial with currval projected out
function MultinomialRandomPrimitive:proposal(currval, params)
	local newparams = util.copytable(params)
	newparams[currval] = 0
	return multinomial_sample(newparams)
end

-- Multinomial with currval projected out
function MultinomialRandomPrimitive:logProposalProb(currval, propval, params)
	local newparams = util.copytable(params)
	newparams[currval] = 0
	return multinomial_logprob(propval, newparams)
end

local multinomialInst = MultinomialRandomPrimitive:new()
function multinomial(theta, isStructural, conditionedValue)
	return multinomialInst:sample(theta, isStructural, conditionedValue)
end

function multinomialDraw(items, probs, isStructural)
	return items[multinomial(probs, isStructural)]
end

function uniformDraw(items, isStructural)
	local n = table.getn(items)
	local invn = 1/n
	local probs = {}
	for i=1,n do
		table.insert(probs, invn)
	end
	return items[multinomial(probs, isStructural)]
end

-------------------