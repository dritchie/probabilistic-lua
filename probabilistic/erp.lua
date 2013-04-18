local trace = require "probabilistic.trace"

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
	p = p or 0.5
	return flipInst:sample({p}, isStructural, conditionedValue)
end

-------------------