local util = require("probabilistic.util")

local IR = {}

-------------------------------
--  Terra/C type conversions --
-------------------------------

IR.terra2c = 
{
	int8 = "char",
	int16 = "short",
	int32 = "int",
	int64 = "long long",
	uint = "unsigned int",
	uint8 = "unsigned char",
	uint16 = "unsigned short",
	uint32 = "unsigned int",
	uint64 = "unsigned long long"
}

function IR.terraTypeToCType(type)
	local typestr = tostring(type)
	local trans = IR.terra2c[typestr]
	return trans or typestr
end


-----------------------------------------------------------
--  Intermediate representation - Arithmetic expressions --
-----------------------------------------------------------

IR.Node = {}

function IR.Node:new(name)
	local newobj =
	{
		name = name,
		inputs = {}
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.Node:childNodes()
	return self.inputs
end


IR.ConstantNode = IR.Node:new()

function IR.ConstantNode:new(name)
	return IR.Node.new(self, name)
end

function IR.ConstantNode:__tostring(tablevel)
	return util.tabify(string.format("IR.ConstantNode: %s", tostring(self.name)), tablevel)
end

function IR.ConstantNode:emitCode()
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



-- If val is already an IR.Node subclass instance,
-- then we're good
-- Otherwise, turn val into a constant expression
-- (but barf on tables; we can't handle those)
function IR.nodify(val)
	if util.inheritsFrom(val, IR.Node) then
		return val
	elseif type(val) == "table" then
		error("mathtracing: Cannot use tables as constant expressions.")
	else
		return IR.ConstantNode:new(val)
	end
end



function IR.traverse(rootNode, visitor)
	local fringe = {rootNode}
	local visited = {}
	while table.getn(fringe) > 0 do
		local top = table.remove(fringe)
		if not visited[top] then
			visited[top] = true
			visitor(top)
			util.appendarray(fringe, top:childNodes())
		end
	end
end



IR.UnaryOpNode = IR.Node:new()

function IR.UnaryOpNode:new(name, arg)
	local newobj = IR.Node.new(self, name)
	table.insert(newobj.inputs, IR.nodify(arg))
	return newobj
end

function IR.UnaryOpNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.UnaryOpNode: %s\n%s",
		self.name, self.inputs[1]:__tostring(tablevel+1)), tablevel)
end

function IR.UnaryOpNode:emitCode()
	return string.format("%s(%s)", self.name, self.inputs[1]:emitCode())
end


IR.BinaryOpNode = IR.Node:new()

function IR.BinaryOpNode:new(name, arg1, arg2)
	local newobj = IR.Node.new(self, name)
	table.insert(newobj.inputs, IR.nodify(arg1))
	table.insert(newobj.inputs, IR.nodify(arg2))
	return newobj
end

function IR.BinaryOpNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.BinaryOpNode: %s\n%s\n%s",
		self.name, self.inputs[1]:__tostring(tablevel+1), self.inputs[2]:__tostring(tablevel+1)), tablevel)
end

function IR.BinaryOpNode:emitCode()
	return string.format("(%s) %s (%s)",
		self.inputs[1]:emitCode(), self.name, self.inputs[2]:emitCode())
end

IR.UnaryPrimFuncNode = IR.Node:new()

function IR.UnaryPrimFuncNode:new(name, arg)
	local newobj = IR.Node.new(self, name)
	table.insert(newobj.inputs, IR.nodify(arg))
	return newobj
end

function IR.UnaryPrimFuncNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.UnaryPrimFuncNode: %s\n%s",
		self.name, self.inputs[1]:__tostring(tablevel+1)), tablevel)
end

function IR.UnaryPrimFuncNode:emitCode()
	return string.format("%s(%s)", self.name, self.inputs[1]:emitCode())
end


IR.BinaryPrimFuncNode = IR.Node:new()

function IR.BinaryPrimFuncNode:new(name, arg)
	local newobj = IR.Node.new(self, name)
	table.insert(newobj.inputs, IR.nodify(arg1))
	table.insert(newobj.inputs, IR.nodify(arg2))
	return newobj
end

function IR.BinaryPrimFuncNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.BinaryPrimFuncNode: %s\n%s\n%s",
		self.name, self.inputs[1]:__tostring(tablevel+1), self.inputs[2]:__tostring(tablevel+1)), tablevel)
end

function IR.BinaryPrimFuncNode:emitCode()
	return string.format("%s((%s), %(s))",
		self.name, self.inputs[1]:emitCode(), self.inputs[2]:emitCode())
end

IR.CompiledFuncNode = IR.Node:new()

function IR.CompiledFuncNode:new(name, arglist)
	local newobj = IR.Node.new(self, name)
	for i,a in ipairs(arglist) do
		arglist[i] = IR.nodify(a)
	end
	newobj.inputs = arglist
	return newobj
end

-- TODO: Define __tostring and emitCode for IR.CompiledFuncNode!


-- These refer to variables that are either inputs to the overall trace function
-- or intermediates created during CSE
IR.VarNode = IR.Node:new()

-- 'type' should be a Terra type
function IR.VarNode:new(name, type, isRandomVariable)
	local newobj = IR.Node.new(self, name)
	newobj.type = type
	newobj.isRandomVariable = isRandomVariable
	return newobj
end

function IR.VarNode:__tostring(tablevel)
	return util.tabify(string.format("IR.VarNode: %s %s", tostring(self.type), self.name), tablevel)
end

function IR.VarNode:emitCode()
	return self.name
end


-----------------------------------------------------
--  Intermediate representation - Other statements --
-----------------------------------------------------


-- These'll be used to store intermediates created during CSE
IR.VarDefinition = {}

-- 'lhs' is an IR.VarNode
-- 'rhs' is an IR.Node or a constant
-- 'type' is a Terra type
function IR.VarDefinition:new(lhs, rhs, type)
	local newobj =
	{
		lhs = lhs,
		rhs = IR.nodify(rhs),
		type = type
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.VarDefinition:childNodes()
	return {lhs, rhs}
end

function IR.VarDefinition:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.VarDefinition: %s %s\n%s",
		tostring(self.type), self.lhs, self.rhs:__tostring(tablevel+1)), tablevel)
end

function IR.VarDefinition:emitCode()
	return string.format("%s %s = (%s);", IR.terraTypeToCType(self.type), self.lhs:emitCode(), self.rhs:emitCode())
end


-- A return statement for returning from functions
IR.ReturnStatement = {}

function IR.ReturnStatement:new(exp)
	local newobj = 
	{
		exp = IR.nodify(exp)
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.ReturnStatement:childNodes()
	return {exp}
end

function IR.ReturnStatement:__tostring(tablevel)
	return util.tabify(string.format("IR.ReturnStatement:\n%s", self.exp:__tostring(tablevel+1)), tablevel)
end

function IR.ReturnStatement:emitCode()
	return string.format("return %s;", self.exp:emitCode())
end


-- A list of IR statements can be wrapped into a function
IR.FunctionDefinition = {}

-- 'args' is a list of IR.VarNodes representing numeric variables
-- 'bodylist' is a list of IR statements (expression nodes, assignments, etc.)
-- 'rettype' is a Terra type
-- The return value of the function is the last item in 'bodylist' and is assumed to
--   be a numeric-valued expression
function IR.FunctionDefinition:new(name, rettype, args, bodylist)
	local newobj =
	{
		name = name,
		rettype = rettype,
		args = args,
		bodylist = bodylist
	}
	local n = table.getn(newobj.bodylist)
	newobj.bodylist[n] = IR.ReturnStatement:new(newobj.bodylist[n])
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.FunctionDefinition:childNodes()
	return util.joinarrays(args, bodylist)
end

function IR.FunctionDefinition:__tostring(tablevel)
	tablevel = tablevel or 0
	local str = util.tabify(string.format("IR.FunctionDefinition: %s %s\n",
		tostring(self.type), self.name), tablevel)
	str = str .. util.tabify("args:\n", tablevel+1)
	for i,a in ipairs(self.args) do
		str = str .. string.format("%s\n", a:__tostring(tablevel+2))
	end
	str = str .. util.tabify("body:\n", tablevel+1)
	for i,b in ipairs(self.bodylist) do
		str = str .. string.format("%s\n", b:__tostring(tablevel+2))
	end

	return str
end

function IR.FunctionDefinition:emitCode()
	local str = string.format("%s %s(", IR.terraTypeToCType(self.rettype), self.name)
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
			return IR.UnaryOpNode:new(cname, n)
		end
	end
end

local function addBinaryOps(tabl, oplist)
	for i,op in ipairs(oplist) do
		local luaname = op[1]
		local cname = op[2]
		tabl[luaname] =
		function(n1, n2)
			return IR.BinaryOpNode:new(cname, n1, n2)
		end
	end
end

local function addUnaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luaname = fn[1]
		local cname = fn[2]
		tabl[luaname] =
		function(n)
			return IR.UnaryPrimFuncNode:new(cname, n)
		end
	end
end

local function addBinaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luaname = fn[1]
		local cname = fn[2]
		tabl[luaname] =
		function(n1, n2)
			return IR.BinaryPrimFuncNode:new(cname, n1, n2)
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
				return IR.UnaryPrimFuncNode:new(cname, n)
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
				return IR.BinaryPrimFuncNode:new(cname, n1, n2)
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
util.copytablemembers(operators, IR.ConstantNode)
util.copytablemembers(operators, IR.VarNode)
util.copytablemembers(operators, IR.UnaryOpNode)
util.copytablemembers(operators, IR.BinaryOpNode)
util.copytablemembers(operators, IR.UnaryPrimFuncNode)
util.copytablemembers(operators, IR.BinaryPrimFuncNode)
util.copytablemembers(operators, IR.CompiledFuncNode)

-- Math functions --
local irmath = 
{
	deg = math.deg,
	frexp = math.frexp,
	huge = math.huge,
	ldexp = math.ldexp,
	max = math.max,
	min = math.min,
	modf = math.modf,
	pi = math.pi,
	rad = math.rad,
	random = math.random,
	randomseed = math.randomseed
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
local function on()
	_on = true
	gmath = math
	_G["math"] = irmath
end
local function off()
	_on = false
	_G["math"] = gmath
end
local function isOn()
	return _on
end


-- What's the fundamental number type we're using?
local numtype = nil
local function numberType()
	return numtype
end
local function setNumberType(newnumtype)
	numtype = newnumtype
end


-- exports
return
{
	on = on,
	off = off,
	isOn = isOn,
	numberType = numberType,
	setNumberType = setNumberType,
	IR = IR
}



-- --- TEST ---

-- on()

-- local function dist(point1, point2)
-- 	local xdiff = point1[1] - point2[1]
-- 	local ydiff = point1[2] - point2[2]
-- 	return math.sqrt(xdiff*xdiff + ydiff*ydiff)
-- end

-- local p1 = {IR.VarNode:new("x1"), IR.VarNode:new("y1")}
-- --local p2 = {IR.VarNode:new("x2"), IR.VarNode:new("y2")}
-- -- local p1 = {0, 0}
-- local p2 = {1, math.pi}
-- print(dist(p1, p2):emitCode())
-- --print(dist(p1, p2))
