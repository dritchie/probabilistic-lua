local dirOfThisFile = (...):match("(.-)[^%.]+$")
local util = require(dirOfThisFile .. "util")

module(..., package.seeall)


-----------------------------------------------------------
--  Intermediate representation - Arithmetic expressions --
-----------------------------------------------------------

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

-- TODO: Define __tostring and emitCode for IRCppFuncNode??


-- These refer to variables that are either inputs to the overall trace function
-- or intermediates created during CSE
local IRVarNode = IRNode:new()

function IRVarNode:new(name, type)
	local newobj = IRNode.new(self, name)
	newobj.type = type
	return newobj
end

function IRVarNode:__tostring(tablevel)
	return tabify(string.format("IRVarNode: %s %s", self.type, self.name), tablevel)
end

function IRVarNode:emitCode()
	return self.name
end


-----------------------------------------------------
--  Intermediate representation - Other statements --
-----------------------------------------------------


-- These'll be used to store intermediates created during CSE
local IRVarDefinition = {}

-- 'lhs' is an IRVarNode
-- 'rhs' is an IRNode or a constant
function IRVarDefinition:new(lhs, rhs, type)
	local newobj =
	{
		lhs = lhs,
		rhs = IRNode.nodify(rhs),
		type = type
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IRVarDefinition:__tostring(tablevel)
	tablevel = tablevel or 0
	return tabify(string.format("IRVarDefinition: %s %s\n%s",
		self.type, self.lhs, self.rhs:__tostring(tablevel+1)), tablevel)
end

function IRVarDefinition:emitCode()
	return string.format("%s %s = (%s);", self.type, self.lhs:emitCode(), self.rhs:emitCode())
end


-- A return statement for returning from functions
local IRReturnStatement = {}

function IRReturnStatement:new(exp)
	local newobj = 
	{
		exp = exp
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IRReturnStatement:__tostring(tablevel)
	return tabify(string.format("IRReturnStatement:\n%s", self.exp:__tostring(tablevel+1)), tablevel)
end

function IRReturnStatement:emitCode()
	return string.format("return %s;", self.exp:emitCode())
end


-- A list of IR statements can be wrapped into a function
local IRFunctionDefinition = {}

-- 'args' is a list of IRVarNodes representing numeric variables
-- 'bodylist' is a list of IR statements (expression nodes, assignments, etc.)
-- The return value of the function is the last item in 'bodylist' and is assumed to
--   be a numeric-valued expression
function IRFunctionDefinition:new(name, rettype, args, bodylist)
	local newobj =
	{
		name = name,
		rettype = self.rettype,
		args = args,
		bodylist = bodylist
	}
	local n = table.getn(newobj.bodylist)
	newobj.bodylist[n] = IRReturnStatement:new(newobj.bodylist[n])
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IRFunctionDefinition:__tostring(tablevel)
	tablevel = tablevel or 0
	local str = tabify(string.format("IRFunctionDefinition: %s %s\n",
		self.type, self.name), tablevel)
	str = str .. tabify("args:\n", tablevel+1)
	for i,a in ipairs(self.args) do
		str = str .. string.format("%s\n", a:__tostring(tablevel+2))
	end
	str = str .. tabify("body:\n", tablevel+1)
	for i,b in ipairs(self.bodylist) do
		str = str .. string.format("%s\n", b:__tostring(tablevel+2))
	end

	return str
end

function IRFunctionDefinition:emitCode()
	local str = string.format("%s %s(", self.rettype, self.name)
	local numargs = table.getn(self.args)
	for i,a in ipairs(self.args) do
		local postfix = i == numargs and "" or ", "
		str = string.format("%s%s %s%s", str, a.type, a:emitCode(), postfix)
	end
	str = string.format("%s)\n{\n", str)
	local bodysize = table.getn(self.bodylist)
	for i,b in ipairs(self.bodylist) do
		str = string.format("%s    %s\n", str, b:emitCode())
	end
	str = string.format("%s\n}\n", str)
	return str
end



-------------------------------------------------------
-- Lifted math operators and replacement math module --
-------------------------------------------------------


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


------------------------------------
-- Publicly visible functionality --
------------------------------------

-- Toggling mathtracing mode --
local gmath = nil
local _on = false
function on()
	_on = true
	gmath = math
	_G["math"] = irmath
end
function off()
	_on = false
	_G["math"] = gmath
end
function isOn()
	return _on
end


-- What's the fundamental number type we're using?
-- Can be "double" or "stan::agrad::var"
local numtype = "double"
function numberType()
	return numtype
end
function setNumberType(newnumtype)
	numtype = newnumtype
end


-- Client code needs to be able to create free variables
function makeVar(name, type)
	return IRVarNode:new(name, type)
end
-- ...and for the time being, create functions
function makeFunction(name, rettype, args, bodylist)
	return IRFunctionDefinition:new(name, rettype, args, bodylist)
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
