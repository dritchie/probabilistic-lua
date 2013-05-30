local dirOfThisFile = (...):match("(.-)[^%.]+$")
local util = require(dirOfThisFile .. "util")

module(..., package.seeall)


local IRNode = {}

function IRNode:new(name)
	local newobj =
	{
		name = name,
		inputs = {}
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end



local function tabify(str, tablevel)
	tablevel = tablevel or 0
	for i=1,tablevel do str = "    " .. str end
	return str
end



local IRConstantNode = IRNode:new()

function IRConstantNode:new(name)
	return IRNode.new(self, name)
end

function IRConstantNode:__tostring(tablevel)
	return tabify(string.format("IRConstantNode: %s", tostring(self.name)), tablevel)
end

function IRConstantNode:emitCode()
	-- We need to make sure that number constants get turned into code that
	-- a C compiler will treat as a floating point literal and not an integer literal.
	if type(self.name) == "number" then
		if math.floor(self.name) == self.name then
			return string.format("%.1f", self.name)
		else
			return string.format("%g", self.name)
		end
	else
		return tostring(self.name)
	end
end



-- If val is already an IRNode subclass instance,
-- then we're good
-- Otherwise, turn val into a constant expression
-- (but barf on tables; we can't handle those)
function IRNode.nodify(val)
	if getmetatable(getmetatable(val)) == IRNode then
		return val
	elseif type(val) == "table" then
		error("mathtracing: Cannot use tables as constant expressions.")
	else
		return IRConstantNode:new(val)
	end
end



local IRUnaryOpNode = IRNode:new()

function IRUnaryOpNode:new(name, arg)
	local newobj = IRNode.new(self, name)
	table.insert(newobj.inputs, IRNode.nodify(arg))
	return newobj
end

function IRUnaryOpNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return tabify(string.format("IRUnaryOpNode: %s\n%s",
		self.name, self.inputs[1]:__tostring(tablevel+1)), tablevel)
end

function IRUnaryOpNode:emitCode()
	return string.format("%s(%s)", self.name, self.inputs[1]:emitCode())
end


local IRBinaryOpNode = IRNode:new()

function IRBinaryOpNode:new(name, arg1, arg2)
	local newobj = IRNode.new(self, name)
	table.insert(newobj.inputs, IRNode.nodify(arg1))
	table.insert(newobj.inputs, IRNode.nodify(arg2))
	return newobj
end

function IRBinaryOpNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return tabify(string.format("IRBinaryOpNode: %s\n%s\n%s",
		self.name, self.inputs[1]:__tostring(tablevel+1), self.inputs[2]:__tostring(tablevel+1)), tablevel)
end

function IRBinaryOpNode:emitCode()
	return string.format("(%s) %s (%s)",
		self.inputs[1]:emitCode(), self.name, self.inputs[2]:emitCode())
end

local IRUnaryPrimFuncNode = IRNode:new()

function IRUnaryPrimFuncNode:new(name, arg)
	local newobj = IRNode.new(self, name)
	table.insert(newobj.inputs, IRNode.nodify(arg))
	return newobj
end

function IRUnaryPrimFuncNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return tabify(string.format("IRUnaryPrimFuncNode: %s\n%s",
		self.name, self.inputs[1]:__tostring(tablevel+1)), tablevel)
end

function IRUnaryPrimFuncNode:emitCode()
	return string.format("%s(%s)", self.name, self.inputs[1]:emitCode())
end


local IRBinaryPrimFuncNode = IRNode:new()

function IRBinaryPrimFuncNode:new(name, arg)
	local newobj = IRNode.new(self, name)
	table.insert(newobj.inputs, IRNode.nodify(arg1))
	table.insert(newobj.inputs, IRNode.nodify(arg2))
	return newobj
end

function IRBinaryPrimFuncNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return tabify(string.format("IRBinaryPrimFuncNode: %s\n%s\n%s",
		self.name, self.inputs[1]:__tostring(tablevel+1), self.inputs[2]:__tostring(tablevel+1)), tablevel)
end

function IRBinaryPrimFuncNode:emitCode()
	return string.format("%s((%s), %(s))",
		self.name, self.inputs[1]:emitCode(), self.inputs[2]:emitCode())
end

local IRCppFuncNode = IRNode:new()

function IRCppFuncNode:new(name, arglist)
	local newobj = IRNode.new(self, name)
	for i,a in ipairs(arglist) do
		arglist[i] = IRNode.nodify(a)
	end
	newobj.inputs = arglist
	return newobj
end

-- TODO: Define __tostring and emitCode for IRCppFuncNode


-- These refer to variables that are either inputs to the overall trace function
-- or intermediates created during CSE
local IRVarNode = IRNode:new()

function IRVarNode:new(name)
	return IRNode.new(self, name)
end

function IRVarNode:__tostring(tablevel)
	return tabify(string.format("IRVarNode: %s", self.name), tablevel)
end

function IRVarNode:emitCode()
	return self.name
end


-- These'll be used to store intermediates created during CSE
local IRAssignmentNode = IRNode:new()

function IRAssignmentNode:new(lhs, rhs)
	local newobj = IRNode.new(self, lhs)
	table.insert(newobj.inputs, IRNode.nodify(rhs))
	return newobj
end

function IRAssignmentNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return tabify(string.format("IRAssignmentNode: %s\n%s",
		self.name, self.inputs[1]:__tostring(tablevel+1)), tablevel)
end

function IRAssignmentNode:emitCode()
	-- TODO: Replace 'double' with 'stan::agrad::var'
	return string.format("double %s = (%s)", self.name, self.inputs[1]:emitCode())
end



---------------------------------------------------------------
--     Lifted math operators and replacement math module     --
---------------------------------------------------------------

local function wrapUnaryMathFunc(origfn, wrapfn)
	local function wrapper(arg)
		if type(arg) == "number" then
			return origfn(arg)
		else
			return wrapfn(arg)
		end
	end
	return wrapper
end

local function wrapBinaryMathFunc(origfn, wrapfn)
	local function wrapper(arg1, arg2)
		if type(arg1) == "number" and type(arg2) == "number" then
			return origfn(arg)
		else
			return wrapfn(arg)
		end
	end
	return wrapper
end

local function addUnaryOps(tabl, oplist)
	for i,op in ipairs(oplist) do
		local luaname = op[1]
		local cname = op[2]
		tabl[luaname] =
		function(n)
			return IRUnaryOpNode:new(cname, n)
		end
	end
end

local function addBinaryOps(tabl, oplist)
	for i,op in ipairs(oplist) do
		local luaname = op[1]
		local cname = op[2]
		tabl[luaname] =
		function(n1, n2)
			return IRBinaryOpNode:new(cname, n1, n2)
		end
	end
end

local function addUnaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luaname = fn[1]
		local cname = fn[2]
		tabl[luaname] =
		function(n)
			return IRUnaryPrimFuncNode:new(cname, n)
		end
	end
end

local function addBinaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luaname = fn[1]
		local cname = fn[2]
		tabl[luaname] =
		function(n1, n2)
			return IRBinaryPrimFuncNode:new(cname, n1, n2)
		end
	end
end

local function addWrappedUnaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luaname = fn[1]
		local cname = fn[2]
		local origfn = fn[3]
		tabl[luaname] = wrapUnaryMathFunc(origfn,
			function(n)
				return IRUnaryPrimFuncNode:new(cname, n)
			end
		)
	end
end

local function addWrappedBinaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luaname = fn[1]
		local cname = fn[2]
		local origfn = fn[3]
		tabl[luaname] = wrapBinaryMathFunc(origfn,
			function(n1, n2)
				return IRBinaryPrimFuncNode:new(cname, n1, n2)
			end
		)
	end
end

-- Operators --
local operators = {}
addBinaryOps(operators, {
	{"__add", "+"},
	{"__sub", "-"},
	{"__mul", "*"},
	{"__div", "/"}
})
addUnaryOps(operators, {
	{"__unm", "-"}
})
addBinaryFuncs(operators, {
	{"__mod", "fmod"},
	{"__pow", "pow"}
})
-- We can't 'inherit' overloaded operators, so
-- we have to stuff the operators into every 'class' metatable
util.copytablemembers(operators, IRConstantNode)
util.copytablemembers(operators, IRVarNode)
util.copytablemembers(operators, IRUnaryOpNode)
util.copytablemembers(operators, IRBinaryOpNode)
util.copytablemembers(operators, IRUnaryPrimFuncNode)
util.copytablemembers(operators, IRBinaryPrimFuncNode)
util.copytablemembers(operators, IRAssignmentNode)
util.copytablemembers(operators, IRCppFuncNode)

-- Math functions --
local irmath = 
{
	huge = math.huge,
	pi = math.pi
}
addWrappedUnaryFuncs(irmath, {
	{"abs", "abs", math.abs},
	{"acos", "acos", math.acos},
	{"asin", "asin", math.asin},
	{"atan", "atan", math.atan},
	{"atan2", "atan2", math.atan2},
	{"ceil", "ceil", math.ceil},
	{"cos", "cos", math.cos},
	{"cosh", "cosh", math.cosh},
	-- "deg" has no direct c analog
	{"exp", "exp", math.exp},
	{"floor", "floor", math.floor},
	-- "frexp" has no direct c analog
	-- "huge" will be traced out as a constant
	-- "ldexp" has no direct c analog
	{"log", "log", math.log},
	{"log10", "log10", math.log10},
	-- stan::agrad::var does not overload "max" and "min", so we won't either
	-- "modf" has no direct c analog
	-- "pi" will be traced out as a constant
	-- "rad" has no direct c analog
	-- "random" and "randomseed" should never be called in a probabilistic program!
	{"sin", "sin", math.sin},
	{"sinh", "sinh", math.sinh},
	{"sqrt", "sqrt", math.sqrt},
	{"tan", "tan", math.tan},
	{"tanh", "tanh", math.tanh}
})
addWrappedBinaryFuncs(irmath, {
	{"fmod", "fmod", math.fmod},
	{"pow", "pow", math.pow}
})


-- Setting/unsetting mathtracing mode --

local gmath = nil
function on()
	gmath = math
	_G["math"] = irmath
end

function off()
	_G["math"] = gmath
end



-- --- TEST ---

-- on()

-- local function dist(point1, point2)
-- 	local xdiff = point1[1] - point2[1]
-- 	local ydiff = point1[2] - point2[2]
-- 	return math.sqrt(xdiff*xdiff + ydiff*ydiff)
-- end

-- local p1 = {IRVarNode:new("x1"), IRVarNode:new("y1")}
-- --local p2 = {IRVarNode:new("x2"), IRVarNode:new("y2")}
-- -- local p1 = {0, 0}
-- local p2 = {1, math.pi}
-- print(dist(p1, p2):emitCode())
-- --print(dist(p1, p2))
