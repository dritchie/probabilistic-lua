local dump = require "dump"

module(..., package.seeall)

-- Wrapper around a function to memoize its results
local MemoizedFunction = {}

function MemoizedFunction:new(func)
	local newobj = {
		func = func,
		cache = {}
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function MemoizedFunction:__call(...)
	local key = (select("#", ...) > 1) and dump.DataDumper({...}, nil, true) or
										   dump.DataDumper(select(1, ...), nil, true)
	local val = self.cache[key]
	if val == nil then
		val = self.func(...)
		self.cache[key] = val
	end
	return val 
end

function mem(func)
	return MemoizedFunction:new(func)
end