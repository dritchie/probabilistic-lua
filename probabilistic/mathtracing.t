local util = require("probabilistic.util")
local cmath = terralib.require("probabilistic.cmath")

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


-------------------------------------------------------
--  Intermediate representation for arithmetic, etc. --
-------------------------------------------------------

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
			util.appendarray(top:childNodes(), fringe)
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
	return op(`([self.inputs[1]:emitTerraCode()]), `([self.inputs[2]:emitTerraCode()]))
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



-- These refer to variables that are either inputs to the overall trace function
-- or intermediates created during CSE
IR.VarNode = IR.Node:new()

function IR.VarNode:new(symbol, isIntermediate)
	assert(symbol.type)		-- C code generation requires we know the type of this variable
	local newobj = IR.Node.new(self, symbol)
	newobj.isIntermediate = isIntermediate
	return newobj
end

function IR.VarNode:__tostring(tablevel)
	return util.tabify(string.format("IR.VarNode: %s %s", tostring(self:type()), self:name()), tablevel)
end

function IR.VarNode:name()
	return self.value.displayname or tostring(self.value)
end

function IR.VarNode:type()
	return self.value.type
end

function IR.VarNode:emitCCode()
	return self:name()
end

function IR.VarNode:emitTerraCode()
	return `[self.value]
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




--- End expressions / begin statements ---


IR.CompiledFuncCall = IR.Node:new()

function IR.CompiledFuncCall:new(fn, arglist)
	local newobj = IR.Node.new(self, fn)
	for i,a in ipairs(arglist) do
		arglist[i] = IR.nodify(a)
	end
	newobj.inputs = arglist
	return newobj
end

function IR.CompiledFuncCall:__tostring(tablevel)
	tablevel = tablevel or 0
	local str = util.tabify(string.format("IR.CompiledFuncCall: %s", self.value.name), tablevel)
	for i,a in ipairs(self.inputs) do
		str = string.format("%s\n%s", str, a:__tostring(tablevel+1))
	end
	return str
end

-- NOTE: This assumes the function is not overloaded (i.e. has a single definition)
function IR.CompiledFuncCall:emitCCode()
	-- Name the function via function pointer
	local fnpointer = self.value.definitions[1]:getpointer()
	local fntype = self.value.definitions[1]:gettype()
	local fnpstr = string.format("%s(*)", IR.terraTypeToCType(fntype.returns[1]))
	if table.getn(fntype.parameters) == 0 then
		fnpstr = string.format("%s(void)", fnpstr)
	else
		fnpstr = string.format("%s(%s", fnpstr, IR.terraTypeToCType(fntype.parameters[1]))
		for i=2,table.getn(fntype.parameters) do
			fnpstr = string.format("%s,%s", fnpstr, IR.terraTypeToCType(fntype.parameters[i]))
		end
		fnpstr = string.format("%s)", fnpstr)
	end
	fnpstr = string.format("((%s)%u)", fnpstr, terralib.cast(uint64, fnpointer))
	-- Then actually call it
	local str = string.format("%s(%s,", fnpstr, self.inputs[1]:emitCCode())
	for i=2,table.getn(self.inputs) do
		str = string.format("%s,%s", str, self.inputs[i]:emitCCode())
	end
	return string.format("%s)", str)
end

function IR.CompiledFuncCall:emitTerraCode()
	return `[self.value]([util.map(function(n) return n:emitTerraCode() end, self.inputs)])
end


-- Take an IR expression and turn it into a statement
-- Useful for e.g. function calls with no return values
IR.Statement = {}

function IR.Statement:new(exp)
	local newobj = 
	{
		exp = exp
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.Statement:childNodes()
	return {self.exp}
end

function IR.Statement:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify("IR.Statement:\n%s", self.exp:__tostring(tablevel+1))
end

function IR.Statement:emitCCode()
	return string.format("%s;", self.exp:emitCCode())
end

function IR.Statement:emitTerraCode()
	return quote
		[self.exp:emitTerraCode()]
	end
end


-- The final statement in a function with return values
IR.ReturnStatement = {}

function IR.ReturnStatement:new(exp)
	local newobj = 
	{
		exp = exp
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.ReturnStatement:childNodes()
	return {self.exp}
end

function IR.ReturnStatement:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.ReturnStatement:\n%s", self.exp:__tostring(tablevel+1)), tablevel)
end

function IR.ReturnStatement:emitCCode()
	return string.format("return %s;", self.exp:emitCCode())
end

function IR.ReturnStatement:emitTerraCode()
	return quote
		return [self.exp:emitTerraCode()]
	end
end


-- A statement assigning expressions to variables
IR.VarAssignmentStatement = {}

function IR.VarAssignmentStatement:new(vars, exps)
	local newobj = 
	{
		vars = vars,
		exps = exps
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.VarAssignmentStatement:childNodes()
	return util.joinarrays(self.vars, self.exps)
end

function IR.VarAssignmentStatement:__tostring(tablevel)
	tablevel = 0 or tablevel
	local str = string.format("IR.VarAssignmentStatement:\n%s", util.tabify("Vars:", tablevel+1))
	for i,v in ipairs(self.vars) do
		str = string.format("%s\n%s", str, v:__tostring(tablevel+2))
	end
	str = string.format("%s\n%s", str, util.tabify("Exps:", tablevel+1))
	for i,e in ipairs(self.exps) do
		str = string.format("%s\n%s", str, e:__tostring(tablevel+2))
	end
	return str
end

function IR.VarAssignmentStatement:emitCCode()
	-- This check will fail for function calls with multiple return values, which
	-- C can't handle.
	assert(table.getn(self.vars) == table.getn(self.exps))
	-- We'll do one line for each, since C can't handle everything in one statment
	local str = ""
	for i,v in ipairs(self.vars) do
		local e = self.exps[i]
		str = string.format("%s%s %s = %s;\n", str, IR.terraTypeToCType(v:type()), v:emitCCode(), e:emitCCode())
	end
	return str
end

function IR.VarAssignmentStatement:emitTerraCode()
	local vars = util.map(function(v) return v.value end, self.vars)
	local exps = util.map(function(e) return e:emitTerraCode() end, self.exps)
	return quote
		var [vars] = [exps]
	end
end


-- Blocks are a list of statements
IR.Block = {}

function IR.Block:new(statements)
	local newobj = 
	{
		statements = statements or {}
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.Block:childNodes()
	return self.statements
end

function IR.Block:__tostring(tablevel)
	tablevel = tablevel or 0
	local str = string.format("IR.Block:")
	for i,s in ipairs(self.statements) do
		str = string.format("%s\n%s", str, s:__tostring(tablevel+1))
	end
	return str
end

function IR.Block:emitCCode()
	local str = ""
	for i,s in ipairs(self.statements) do
		str = string.format("%s%s\n", str, s:emitCCode())
	end
	return str
end

function IR.Block:emitTerraCode()
	return quote
		[util.map(function(s) return s:emitTerraCode() end, self.statements)]
	end
end


-- A list of IR statements can be wrapped into a function
IR.FunctionDefinition = {}

-- 'args' is a list of IR.VarNodes
-- 'body' is a block
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
	return util.joinarrays(self.args, {self.body})
end

function IR.FunctionDefinition:__tostring(tablevel)
	tablevel = tablevel or 0
	local str = util.tabify(string.format("IR.FunctionDefinition: %s %s",
		tostring(self.type), self.value), tablevel)
	str = str .. util.tabify("\nargs:", tablevel+1)
	for i,a in ipairs(self.args) do
		str = str .. string.format("\n%s", a:__tostring(tablevel+2))
	end
	str = str .. util.tabify(string.format("\nbody:\n%s", self.body:__tostring(tablevel+2)), tablevel+1)
	return str
end

function IR.FunctionDefinition:emitCCode()
	local str = string.format("%s %s(", tostring(IR.terraTypeToCType(self.rettype)), self.value)
	local numargs = table.getn(self.args)
	for i,a in ipairs(self.args) do
		local postfix = i == numargs and "" or ", "
		str = string.format("%s%s %s%s", str, tostring(IR.terraTypeToCType(a:type())), a:emitCCode(), postfix)
	end
	str = string.format("%s)\n{\n%s\n}\n", str, util.tabify(self.body:emitCCode(), 1))
	return str
end

function IR.FunctionDefinition:emitTerraCode()
	local arglist = util.map(function(argvar) return argvar.value end, self.args)
	return
		terra([arglist])
			[self.body:emitTerraCode()]
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


---------------
-- Profiling --
---------------

local profilingEnabled = false
local timers = {}

local function toggleProfiling(flag)
	profilingEnabled = flag
end

local function startTimer(name, excludeFromTotal)
	if profilingEnabled then
		local timer = timers[name]
		if not timer then
			timer = util.Timer:new()
			timers[name] = timer
		end
		timer.excludeFromTotal = excludeFromTotal
		timer:start()
	end
end

local function stopTimer(name)
	if profilingEnabled then
		local timer = timers[name]
		if not timer then
			error("Attempted to stop a timer that does not exist!")
		end
		timer:stop()
	end
end

local function getTimingProfile()
	local timings = util.map(function(timer) return timer:getElapsedTime() end, timers)
	local total = 0
	for name,timer in pairs(timers) do
		if not timer.excludeFromTotal then
			total = total + timer:getElapsedTime()
		end
	end
	timings["TOTAL"] = total
	return timings
end


------------------------------------
-- Publicly visible functionality --
------------------------------------

-- A statement block that forms the current trace through the program
local trace = nil

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


-- Create an IR node corresponding to a random variable with
-- the name 'name'
local name2index = nil
local function makeRandomVariableNode(name)
	return IR.ArraySubscriptNode:new(name2index[name], randomVarsNode)
end

-- Create an IR variable node corresponding to an inference
-- hyperparameter with Terra type 'type'
local hyperparams = nil
local function makeParameterNode(type, name)
	local node = IR.VarNode:new(symbol(type, name))
	hyperparams[node] = true
	return node
end

-- Create an IR variable node which holds an intermediate result
local function makeIntermediateVarNode(type)
	return IR.VarNode:new(symbol(type), true)
end


-- These functions set up / tear down the modifications
-- necessary to trace over precompiled functions
local terra terrafn()
	return 0
end
local terrafncall = nil
local function setupPrecompiledFuncTracing()
	local mt = getmetatable(terrafn)
	terrafncall = mt.__call
	mt.__call = function(fn, ...)
		-- If any of the arguments to the function are IR.Nodes, we'll trace
		-- over this call. Else, we just call the function normally
		local isTraceCall = false
		local numargs = select("#", ...)
		for i=1,numargs do
			if util.inheritsFrom(select(i, ...), IR.Node) then
				isTraceCall = true
				break
			end
		end
		if isTraceCall then
			-- We don't (yet?) support overloaded functions
			assert(table.getn(fn.definitions) == 1)
			-- Assign the result(s) of the function call to intermediates,
			-- and return a VarNode for each intermediate
			local funcNode = IR.CompiledFuncCall:new(fn, {...})
			local t = fn.definitions[1]:gettype()
			local vars = {}
			for i,r in ipairs(t.returns) do
				table.insert(vars, makeIntermediateVarNode(r))
			end
			if table.getn(vars) == 0 then
				table.insert(trace.statements, IR.Statement:new(funcNode))
			else
				table.insert(trace.statements, IR.VarAssignmentStatement:new(vars, {funcNode}))
				return unpack(vars)
			end
		else
			return terrafncall(fn, ...)
		end
	end
end
local function teardownPrecompiledFuncTracing()
	local mt = getmetatable(terrafn)
	mt.__call = terrafncall
end

-- Toggling mathtracing mode --
local gmath = nil
local _on = false
local function on()
	_on = true
	hyperparams = {}
	trace = IR.Block:new()
	setupPrecompiledFuncTracing()
	randomVarsNode = IR.VarNode:new(symbol(&realnumtype))
	gmath = math
	_G["math"] = irmath
end
local function off()
	_on = false
	teardownPrecompiledFuncTracing()
	_G["math"] = gmath
end
local function isOn()
	return _on
end

-- Trace the access to a nonstructural random variable
local function traceNonstructuralVariable(record)
	assert(isOn() and not record.structural)
	record.val = makeRandomVariableNode(record.name)
	record.logprob = record.erp:logprob(record.val, record.params)
end

-- Find all the named parameter varaibles that occur in an IR
local function findNamedParameters(root)
	local visitor = 
	{
		vars = {},
		__call =
		function(self, node)
			if util.inheritsFrom(node, IR.VarNode) and hyperparams[node] then
				table.insert(self.vars, node)
			end
		end
	}
	setmetatable(visitor, visitor)
	IR.traverse(root, visitor)
	return visitor.vars
end

-- Record and compile a trace of a log probability computation.
-- Returns a compiled function, followed by all of the parameter
--   variables found in the recorded trace.
local function compileLogProbTrace(probTrace)
	-- If profiling is on, run a normal traceUpdate so we can see how much overhead
	-- the IR generation adds to this
	if profilingEnabled then
		startTimer("NormalTraceUpdate", true)
		probTrace:traceUpdate(true)
		stopTimer("NormalTraceUpdate")
	end
	startTimer("IRGeneration")
	-- First, extract and save a consistent ordering of the
	-- random variables
	name2index = {}
	local nonStructNames = probTrace:freeVarNames(false, true)
	for i,n in ipairs(nonStructNames) do
		name2index[n] = i-1
	end
	-- Now trace
	local traceCopy = probTrace:deepcopy()	-- since tracing clobbers a bunch of stuff
	on()
	traceCopy:traceUpdate(true)
	local expr = traceCopy.logprob
	off()
	-- Now do compilation
	table.insert(trace.statements, IR.ReturnStatement:new(expr))
	local params = findNamedParameters(trace)
	local fnargs = {randomVarsNode}
	util.appendarray(params, fnargs)
	local fnname = tostring(symbol())
	local fn = IR.FunctionDefinition:new(fnname, realnumtype, fnargs, trace)
	stopTimer("IRGeneration")
	startTimer("LogProbAssemble")
	local cfn = fn:emitTerraCode()
	stopTimer("LogProbAssemble")
	startTimer("LogProbCompile")
	cfn:compile()
	stopTimer("LogProbCompile")

	return cfn, params
end

-- Find all the free (non-intermediate) variables in an IR
local function findFreeVariables(root)
	local visitor =
	{
		vars = {},
		__call = 
		function(self, node)
			if util.inheritsFrom(node, IR.VarNode) and not node.isIntermediate then
				table.insert(self.vars, node)
			end
		end
	}
	setmetatable(visitor, visitor)
	IR.traverse(root, visitor)
	return visitor.vars
end

-- Compile a recorded trace
-- 'expr' is an (optional) expression to use as the return value of the compiled function
-- Returns the compiled function
local function compileTrace(expr)
	if expr then
		table.insert(trace.statements, IR.ReturnStatement:new(expr))
	end
	local vars = findFreeVariables(trace)
	local fn = IR.FunctionDefinition:new(nil, nil, vars, trace)
	local cfn = fn:emitTerraCode()
	--cfn:printpretty()
	return cfn
end


-- exports
return
{
	IR = IR,
	toggleProfiling = toggleProfiling,
	startTimer = startTimer,
	stopTimer = stopTimer,
	getTimingProfile = getTimingProfile,
	on = on,
	off = off,
	isOn = isOn,
	traceNonstructuralVariable = traceNonstructuralVariable,
	realNumberType = realNumberType,
	setRealNumberType = setRealNumberType,
	makeParameterNode = makeParameterNode,
	compileLogProbTrace = compileLogProbTrace,
	compileTrace = compileTrace
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
