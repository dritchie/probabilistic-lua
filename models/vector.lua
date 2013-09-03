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
end

return Vector
	