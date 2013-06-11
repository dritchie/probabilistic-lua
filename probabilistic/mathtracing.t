local util = require("probabilistic.util")

local IR = {}

-- TODO: Replace this with a table that overloads math functions appropriately
-- for AD dual number type
local cmath = terralib.includec("math.h")

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
	local pointercapture = string.match(typestr, "&(.+)")
	if pointercapture then
		typestr = pointercapture
	end
	typestr = IR.terra2c[typestr] or typestr
	if pointercapture then
		typestr = string.format("%s*", typestr)
	end
	return typestr
end


-------------------------------------------------
--  Intermediate representation for arithmetic --
-------------------------------------------------

IR.Node = {}

function IR.Node:new(value)
	local newobj =
	{
		value = value,
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

function IR.ConstantNode:new(value)
	return IR.Node.new(self, value)
end

function IR.ConstantNode:__tostring(tablevel)
	return util.tabify(string.format("IR.ConstantNode: %s", tostring(self.value)), tablevel)
end

function IR.ConstantNode:emitCCode()
	-- We need to make sure that number constants get turned into code that
	-- a C compiler will treat as a floating point literal and not an integer literal.
	if type(self.value) == "number" then
		if math.floor(self.value) == self.value then
			return string.format("%.1f", self.value)
		else
			return string.format("%g", self.value)
		end
	else
		return tostring(self.value)
	end
end

function IR.ConstantNode:emitTerraCode()
	-- Again, need to make sure that numbers get treated
	-- as floating point
	if type(self.value) == "number" then
		return `[double]([self.value])
	else
		return `[self.value]
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



IR.BinaryOpNode = IR.Node:new()

function IR.BinaryOpNode:new(value, arg1, arg2)
	local newobj = IR.Node.new(self, value)
	table.insert(newobj.inputs, IR.nodify(arg1))
	table.insert(newobj.inputs, IR.nodify(arg2))
	return newobj
end

function IR.BinaryOpNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.BinaryOpNode: %s\n%s\n%s",
		self.value, self.inputs[1]:__tostring(tablevel+1), self.inputs[2]:__tostring(tablevel+1)), tablevel)
end

function IR.BinaryOpNode:emitCCode()
	return string.format("(%s) %s (%s)",
		self.inputs[1]:emitCCode(), self.value, self.inputs[2]:emitCCode())
end

function IR.BinaryOpNode:emitTerraCode()
	local op = terralib.defaultoperator(self.value)
	return op(self.inputs[1]:emitTerraCode(), self.inputs[2]:emitTerraCode())
end


IR.UnaryMathFuncNode = IR.Node:new()

function IR.UnaryMathFuncNode:new(value, arg)
	local newobj = IR.Node.new(self, value)
	table.insert(newobj.inputs, IR.nodify(arg))
	return newobj
end

function IR.UnaryMathFuncNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.UnaryMathFuncNode: %s\n%s",
		self.value, self.inputs[1]:__tostring(tablevel+1)), tablevel)
end

function IR.UnaryMathFuncNode:emitCCode()
	return string.format("%s(%s)", self.value, self.inputs[1]:emitCCode())
end

function IR.UnaryMathFuncNode:emitTerraCode()
	return `[cmath[self.value]]([self.inputs[1]:emitTerraCode()])
end


IR.BinaryMathFuncNode = IR.Node:new()

function IR.BinaryMathFuncNode:new(value, arg)
	local newobj = IR.Node.new(self, value)
	table.insert(newobj.inputs, IR.nodify(arg1))
	table.insert(newobj.inputs, IR.nodify(arg2))
	return newobj
end

function IR.BinaryMathFuncNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.BinaryMathFuncNode: %s\n%s\n%s",
		self.value, self.inputs[1]:__tostring(tablevel+1), self.inputs[2]:__tostring(tablevel+1)), tablevel)
end

function IR.BinaryMathFuncNode:emitCCode()
	return string.format("%s((%s), %(s))",
		self.value, self.inputs[1]:emitCCode(), self.inputs[2]:emitCCode())
end

function IR.BinaryMathFuncNode:emitTerraCode()
	return `[cmath[self.value]]([self.inputs[1]:emitTerraCode()], [self.inputs[2]:emitTerraCode()])
end


IR.CompiledFuncNode = IR.Node:new()

function IR.CompiledFuncNode:new(value, arglist)
	local newobj = IR.Node.new(self, value)
	for i,a in ipairs(arglist) do
		arglist[i] = IR.nodify(a)
	end
	newobj.inputs = arglist
	return newobj
end

-- TODO: Define __tostring and emitCCode for IR.CompiledFuncNode!


-- These refer to variables that are either inputs to the overall trace function
-- or intermediates created during CSE
IR.VarNode = IR.Node:new()

function IR.VarNode:new(symbol)
	local newobj = IR.Node.new(self, symbol)
	return newobj
end

function IR.VarNode:__tostring(tablevel)
	return util.tabify(string.format("IR.VarNode: %s %s", tostring(self.value.type), self.value.displayname), tablevel)
end

function IR.VarNode:emitCCode()
	return self.value.displayname
end

function IR.VarNode:emitTerraCode()
	return self.value
end


IR.ArraySubscriptNode = IR.Node:new()

function IR.ArraySubscriptNode:new(index, indexee)
	local newobj = IR.Node.new(self, index)
	table.insert(newobj.inputs, indexee)
	return newobj
end

function IR.ArraySubscriptNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.ArraySubscriptNode: %s\n%s", self.value, self.inputs[1]:__tostring(tablevel+1)), tablevel)
end

function IR.ArraySubscriptNode:emitCCode()
	return string.format("%s[%d]", self.inputs[1]:emitCCode(), self.value)
end

function IR.ArraySubscriptNode:emitTerraCode()
	return `[self.inputs[1]:emitTerraCode()][ [self.value] ]
end


-- A list of IR statements can be wrapped into a function
IR.FunctionDefinition = {}

-- 'args' is a list of IR.VarNodes representing numeric variables
-- 'body' is an IR expression
-- 'rettype' is a Terra type
function IR.FunctionDefinition:new(name, rettype, args, body)
	local newobj =
	{
		value = name,
		rettype = rettype,
		args = args,
		body = body
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.FunctionDefinition:childNodes()
	return util.joinarrays(args, {body})
end

function IR.FunctionDefinition:__tostring(tablevel)
	tablevel = tablevel or 0
	local str = util.tabify(string.format("IR.FunctionDefinition: %s %s\n",
		tostring(self.type), self.value), tablevel)
	str = str .. util.tabify("args:\n", tablevel+1)
	for i,a in ipairs(self.args) do
		str = str .. string.format("%s\n", a:__tostring(tablevel+2))
	end
	str = str .. util.tabify(string.format("body:\n%s\n", self.body:__tostring(tablevel+2)), tablevel+1)
	return str
end

function IR.FunctionDefinition:emitCCode()
	local str = string.format("%s %s(", tostring(IR.terraTypeToCType(self.rettype)), self.value)
	local numargs = table.getn(self.args)
	for i,a in ipairs(self.args) do
		local postfix = i == numargs and "" or ", "
		str = string.format("%s%s %s%s", str, tostring(IR.terraTypeToCType(a.value.type)), a:emitCCode(), postfix)
	end
	str = string.format("%s)\n{\n    return %s;\n}\n", str, self.body:emitCCode())
	return str
end

function IR.FunctionDefinition:emitTerraCode()
	local arglist = util.map(function(node) return node.value end, self.args)
	return
		terra([arglist])
			return [self.body:emitTerraCode()]
		end
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

local function addBinaryOps(tabl, oplist)
	for i,op in ipairs(oplist) do
		local luavalue = op[1]
		local cvalue = op[2]
		tabl[luavalue] =
		function(n1, n2)
			return IR.BinaryOpNode:new(cvalue, n1, n2)
		end
	end
end

local function addUnaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luavalue = fn[1]
		local cvalue = fn[2]
		tabl[luavalue] =
		function(n)
			return IR.UnaryMathFuncNode:new(cvalue, n)
		end
	end
end

local function addBinaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luavalue = fn[1]
		local cvalue = fn[2]
		tabl[luavalue] =
		function(n1, n2)
			return IR.BinaryMathFuncNode:new(cvalue, n1, n2)
		end
	end
end

local function addWrappedUnaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luavalue = fn[1]
		local cvalue = fn[2]
		local origfn = fn[3]
		tabl[luavalue] = wrapUnaryMathFunc(origfn,
			function(n)
				return IR.UnaryMathFuncNode:new(cvalue, n)
			end
		)
	end
end

local function addWrappedBinaryFuncs(tabl, funclist)
	for i,fn in ipairs(funclist) do
		local luavalue = fn[1]
		local cvalue = fn[2]
		local origfn = fn[3]
		tabl[luavalue] = wrapBinaryMathFunc(origfn,
			function(n1, n2)
				return IR.BinaryMathFuncNode:new(cvalue, n1, n2)
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
addBinaryFuncs(operators, {
	{"__mod", "fmod"},
	{"__pow", "pow"}
})
-- Terra doesn't at the moment support __unm, so here's a hack around that
operators["__unm"] = 
function(n)
	return IR.BinaryOpNode:new("-", 0, n)
end
-- We can't 'inherit' overloaded operators, so
-- we have to stuff the operators into every 'class' metatable
util.copytablemembers(operators, IR.ConstantNode)
util.copytablemembers(operators, IR.VarNode)
util.copytablemembers(operators, IR.BinaryOpNode)
util.copytablemembers(operators, IR.UnaryMathFuncNode)
util.copytablemembers(operators, IR.BinaryMathFuncNode)
util.copytablemembers(operators, IR.ArraySubscriptNode)
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

-- An IR expression which represents the array of random variable
-- values that's the input to a compiled log probability function
local randomVarsNode = nil

-- What's the fundamental number type we're using?
local realnumtype = double
local function realNumberType()
	return realnumtype
end
local function setRealNumberType(newnumtype)
	realnumtype = newnumtype
end

-- Toggling mathtracing mode --
local gmath = nil
local _on = false
local function on()
	_on = true
	randomVarsNode = IR.VarNode:new(symbol(&realnumtype, "vars"))
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

-- Create an IR node corresponding to a random variable with
-- index 'index' in the flat list of trace variables
local function makeRandomVariableNode(index)
	return IR.ArraySubscriptNode:new(index, randomVarsNode)
end

-- Create an IR variable node corresponding to an inference
-- hyperparameter named 'name' with Terra type 'type'
local function makeParameterNode(name, type)
	return IR.VarNode:new(symbol(type, name))
end

-- Find all the varaibles in the IR expression 'expr' that
-- are *not* the random variable array
local function findNonRandomVariables(expr)
	local visitor = 
	{
		vars = {},
		__call =
		function(self, node)
			if util.inheritsFrom(node, IR.VarNode) and node ~= randomVarsNode then
				table.insert(self.vars, node)
			end
		end
	}
	setmetatable(visitor, visitor)
	IR.traverse(expr, visitor)
	return visitor.vars
end

-- Wrap the log probability expression 'expr' in a function defintion
-- Returns a compiled function, followed by all of the parameter
--   variables found in the expression.
local function compileLogProbExpression(expr)
	local nonRandVars = findNonRandomVariables(expr)
	local fnargs = util.copytable(nonRandVars)
	table.insert(fnargs, randomVarsNode)
	local fnname = string.format("logprob%s", tostring(symbol()))
	local fn = IR.FunctionDefinition:new(fnname, realnumtype, fnargs, expr)

	-- Uncomment the next two lines to use C instead of Terra.
	--local C = terralib.includecstring(string.format("#include <math.h>\n\n%s", fn:emitCCode()))
	--return C[fnname], nonRandVars

	return fn:emitTerraCode(), nonRandVars
end


-- exports
return
{
	IR = IR,
	on = on,
	off = off,
	isOn = isOn,
	realNumberType = realNumberType,
	setRealNumberType = setRealNumberType,
	makeRandomVariableNode = makeRandomVariableNode,
	makeParameterNode = makeParameterNode,
	compileLogProbExpression = compileLogProbExpression
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
-- print(dist(p1, p2):emitCCode())
-- --print(dist(p1, p2))
