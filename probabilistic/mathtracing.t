local util = require("probabilistic.util")
local IR = terralib.require("probabilistic.IR")
local cc = terralib.require("probabilistic.cCompiler")
local prof = require("probabilistic.profiling")


-- What's the fundamental number type we're using?
local realnumtype = double
local function realNumberType()
	return realnumtype
end
local function setRealNumberType(newnumtype)
	realnumtype = newnumtype
end

-- Compilation options --
-------------------------
-- Can be "C" or "Terra"
-- [Must be "C" for HMC]
local targetLang = "C"
-- Can be "External" or "ThroughTerra" (only applies when targetLang = "C")
-- [Must be "External" for HMC]
local cCompiler = "External"



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
	{"atan2", "atan2", math.atan2},
	{"fmod", "fmod", math.fmod},
	{"max", "fmax", math.max},
	{"min", "fmin", math.min},
	{"pow", "pow", math.pow}
})


-----------------------------
-- Putting it all together --
-----------------------------

-- A statement block that forms the current trace through the program
local trace = nil

-- An IR expression which represents the array of random variable
-- values that's the input to a compiled log probability function
local randomVarsNode = nil


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

local function compileCLogProbFunctionThroughTerra(fnir)
	local code = string.format([[
		#include <math.h>
		%s
		%s
	]], fnir:cReturnTypeDefinition(), fnir:emitCCode())
	local C = terralib.includecstring(code)
	return C[fnir.name]
end

local function compileLogProbFunction(fnir, targetLang)
	if targetLang == "Terra" then
		local fn = fnir:emitTerraCode()
		return fn
	elseif targetLang == "C" then
		fnir:fixMultipleReturns()
		local fn = nil
		if cCompiler == "ThroughTerra" then
			fn = compileCLogProbFunctionThroughTerra(fnir)
		elseif cCompiler == "External" then
			fn = cc.compile(fnir, realnumtype)
		else
			error("Unsupported C Compiler")
		end
		-- If the number of return values is greater than 1, this function
		-- extracts each value from the returned struct and returns them as a list
		if fnir.hasMultipleReturns then
			local rstructType = fn.definitions[1]:gettype().returns[1]
			local args = util.map(function(arg) return arg.value end, fnir.args)
			local function fields(structvar)
				local retvals = {}
				for i=1,fnir.numMultipleReturns do table.insert(retvals, `structvar.[rstructType.entries[i].field]) end
				return retvals
			end
			fn = terra([args])
				var retval = fn([args])
				return [fields(retval)]
			end
		end
		return fn
	else
		error("Unsupported target language")
	end
end

-- Record and compile a trace of a log probability computation.
-- Returns a compiled function, followed by all of the parameter
--   variables found in the recorded trace.
local function compileLogProbTrace(probTrace)
	-- If profiling is on, run a normal traceUpdate so we can see how much overhead
	-- the IR generation adds to this
	if prof.profilingIsEnabled() then
		prof.startTimer("NormalTraceUpdate", true)
		probTrace:traceUpdate(true)
		prof.stopTimer("NormalTraceUpdate")
	end
	prof.startTimer("IRGeneration")
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
	local exprs = {traceCopy:traceLogprobExp()}
	off()
	-- Now do compilation
	table.insert(trace.statements, IR.ReturnStatement:new(exprs))
	local params = findNamedParameters(trace)
	local fnargs = {randomVarsNode}
	util.appendarray(params, fnargs)
	local fnname = string.format("logprob_%d", symbol().id)
	local fnir = IR.FunctionDefinition:new(fnname, fnargs, trace, realnumtype)
	prof.stopTimer("IRGeneration")
	prof.startTimer("LogProbCompile")
	local cfn = compileLogProbFunction(fnir, targetLang)
	prof.stopTimer("LogProbCompile")
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
	local fn = IR.FunctionDefinition:new(nil, vars, trace)	-- Does this need a return type?
	local cfn = fn:emitTerraCode()
	return cfn
end


-- exports
return
{
	IR = IR,
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
