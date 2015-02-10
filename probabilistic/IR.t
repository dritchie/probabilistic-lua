local util = require("probabilistic.util")
local cmath = require("probabilistic.cmath")


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
-- or intermediates created during post-processing of the IR
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


IR.AggregateFieldAccessNode = IR.Node:new()

function IR.AggregateFieldAccessNode:new(field, agg)
	local newobj = IR.Node.new(self, field)
	table.insert(newobj.inputs, agg)
	return newobj
end

function IR.AggregateFieldAccessNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.AggregateFieldAccessNode: %s\n%s", self.value, self.inputs[1]:__tostring(tablevel+1)), tablevel)
end

function IR.AggregateFieldAccessNode:emitCCode()
	return string.format("(%s).%s", self.inputs[1]:emitCCode(), self.value)
end

function IR.AggregateFieldAccessNode:emitTerraCode()
	return `[self.inputs[1]:emitTerraCode()].[self.value]
end


IR.CastNode = IR.Node:new()

function IR.CastNode:new(newtype, exp)
	local newobj = IR.Node.new(self, newtype)
	table.insert(newobj.inputs, exp)
	return newobj
end

function IR.CastNode:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify(string.format("IR.CastNode: %s\n%s", self.value, self.inputs[1]:__tostring(tablevel+1)), tablevel)
end

function IR.CastNode:emitCCode()
	return string.format("((%s)%s)", IR.terraTypeToCType(self.value), self.inputs[1]:emitCCode())
end

function IR.CastNode:emitTerraCode()
	return `[self.value](self.inputs[1]:emitTerraCode())
end


-- For when I have something I want to kludge into the IR without having to write
-- a whole bunch more expression types for it.
IR.ArbitraryCExpression = IR.Node:new()

function IR.ArbitraryCExpression:new(codeGenFn)
	local newobj = IR.Node.new(self, codeGenFn)
	return newobj
end

function IR.ArbitraryCExpression:__tostring(tablevel)
	tablevel = tablevel or 0
	return util.tabify("IR.ArbitraryCExpression", tablevel)
end

function IR.ArbitraryCExpression:emitCCode()
	return self.value()
end

function IR.ArbitraryCExpression:emitTerraCode()
	error("Cannot generate Terra code for an arbitrary C expression")
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

function IR.ReturnStatement:new(exps)
	local newobj = 
	{
		exps = exps
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.ReturnStatement:childNodes()
	return self.exps
end

function IR.ReturnStatement:__tostring(tablevel)
	tablevel = tablevel or 0
	local str = util.tabify("IR.ReturnStatement:", tablevel)
	for i,e in ipairs(self.exps) do
		str = string.format("%s\n%s", str, util.tabify(e:__tostring(tablevel+1)))
	end
	return str
end

function IR.ReturnStatement:emitCCode()
	-- It's an error to generate C code for a return statement with more than one return value
	-- (See IR.FunctionDefinition:fixMultipleReturns)
	assert(table.getn(self.exps) == 1)
	return string.format("return %s;", self.exps[1]:emitCCode())
end

function IR.ReturnStatement:emitTerraCode()
	local expscode = util.map(function(e) return e:emitTerraCode() end, self.exps)
	return quote
		return [expscode]
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
	assert(table.getn(self.exps) == 0 or table.getn(self.vars) == table.getn(self.exps))
	-- We'll do one line for each, since C can't handle everything in one statment
	local hasexps = table.getn(self.exps) > 0
	local str = ""
	for i,v in ipairs(self.vars) do
		str = string.format("%s%s %s", str, IR.terraTypeToCType(v:type()), v:emitCCode())
		-- Differentiating between assignments and declarations
		if hasexps then
			local e = self.exps[i]
			str = string.format("%s = %s", str, e:emitCCode())
		end
		str = string.format("%s;\n", str)
	end
	return str
end

function IR.VarAssignmentStatement:emitTerraCode()
	local vars = util.map(function(v) return v.value end, self.vars)
	-- If we have no rhs, then these are just declarations
	if table.getn(self.exps) == 0 then
		return quote
			var [vars]
		end
	-- Otherwise, it's an assignment
	else
		local exps = util.map(function(e) return e:emitTerraCode() end, self.exps)
		return quote
			var [vars] = [exps]
		end
	end
end


-- A statement assigning the result of one set of expressions to another
IR.AssignmentStatement = {}

function IR.AssignmentStatement:new(lhslist, rhslist)
	local newobj = 
	{
		lhslist = lhslist,
		rhslist = rhslist
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.AssignmentStatement:childNodes()
	return util.joinarrays(self.lhslist, self.rhslist)
end

function IR.AssignmentStatement:__tostring(tablevel)
	tablevel = 0 or tablevel
	local str = string.format("IR.AssignmentStatement:\n%s", util.tabify("LHS:", tablevel+1))
	for i,v in ipairs(self.lhslist) do
		str = string.format("%s\n%s", str, v:__tostring(tablevel+2))
	end
	str = string.format("%s\n%s", str, util.tabify("RHS:", tablevel+1))
	for i,e in ipairs(self.rhslist) do
		str = string.format("%s\n%s", str, e:__tostring(tablevel+2))
	end
	return str
end

function IR.AssignmentStatement:emitCCode()
	-- This check will fail for function calls with multiple return values, which
	-- C can't handle.
	assert(table.getn(self.lhslist) == table.getn(self.rhslist))
	-- We'll do one line for each, since C can't handle everything in one statment
	local str = ""
	for i,l in ipairs(self.lhslist) do
		local r = self.rhslist[i]
		str = string.format("%s%s = %s;\n", str, l:emitCCode(), r:emitCCode())
	end
	return str
end

function IR.AssignmentStatement:emitTerraCode()
	local lhs = util.map(function(l) return l:emitTerraCode() end, self.lhslist)
	local rhs = util.map(function(r) return r:emitTerraCode() end, self.rhslist)
	return quote
		[lhs] = [rhs]
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
-- 'rettype' is a Terra or C type indicating the desired return type of the function
function IR.FunctionDefinition:new(name, args, body, rettype)
	local newobj =
	{
		name = name,
		args = args,
		body = body,
		returnType = rettype
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function IR.FunctionDefinition:lastStatement()
	return self.body.statements[table.getn(self.body.statements)]
end

function IR.FunctionDefinition:numReturnValues()
	local last = self:lastStatement()
	if util.inheritsFrom(last, IR.ReturnStatement) then
		return table.getn(last.exps)
	else
		return 0
	end
end

-- If a function has multiple return values, we can't generate C code for it.
-- Running this pass over the IR wil detect multiple returns, pack them into a
--    struct (specialized to this function), and return that struct.
-- IMPORTANT: Running this pass will break Terra code generation for this function,
--    since the IR will refer to a struct type that will only exist in generated C code. 
function IR.FunctionDefinition:fixMultipleReturns()
	local numretvals = self:numReturnValues()
	if numretvals > 1 then
		self.hasMultipleReturns = true
		self.numMultipleReturns = numretvals
		-- Remove the last (return) statement
		local origReturn = table.remove(self.body.statements)
		-- Declare a struct to hold the return values
		local newStructVar = IR.VarNode:new({displayname = "retvals", type = self:cReturnType()}, true)
		table.insert(self.body.statements, IR.VarAssignmentStatement:new({newStructVar}, {}))
		-- Assign to each of the fields of this struct
		local fieldnodes = {}
		for i=1,numretvals do
			table.insert(fieldnodes, IR.AggregateFieldAccessNode:new(string.format("val%d", i), newStructVar))
		end
		table.insert(self.body.statements, IR.AssignmentStatement:new(fieldnodes, origReturn.exps))
		-- Return the struct
		table.insert(self.body.statements, IR.ReturnStatement:new({newStructVar}))
	end
end

function IR.FunctionDefinition:cPrototype()
	local str = string.format("%s %s(", tostring(IR.terraTypeToCType(self:cReturnType())), self.name)
	local numargs = table.getn(self.args)
	for i,a in ipairs(self.args) do
		local postfix = i == numargs and "" or ", "
		str = string.format("%s%s %s%s", str, tostring(IR.terraTypeToCType(a:type())), a:emitCCode(), postfix)
	end
	str = string.format("%s)", str)
	return str
end

function IR.FunctionDefinition:cReturnType()
	if not self.hasMultipleReturns then
		return IR.terraTypeToCType(self.returnType)
	else
		return string.format("returnStruct_%s", self.name)
	end
end

function IR.FunctionDefinition:cReturnTypeDefinition()
	if not self.hasMultipleReturns then
		return ""
	else
		local rettype = self:cReturnType()
		local str = "typedef struct\n{\n"
		for i=1,self.numMultipleReturns do
			str = string.format("%s    %s val%d;\n", str, IR.terraTypeToCType(self.returnType), i)
		end
		str = string.format("%s} %s;\n", str, rettype)
		return str
	end
end

function IR.FunctionDefinition:childNodes()
	return util.joinarrays(self.args, {self.body})
end

function IR.FunctionDefinition:__tostring(tablevel)
	tablevel = tablevel or 0
	local str = util.tabify(string.format("IR.FunctionDefinition: %s", self.name), tablevel)
	str = str .. util.tabify("\nargs:", tablevel+1)
	for i,a in ipairs(self.args) do
		str = str .. string.format("\n%s", a:__tostring(tablevel+2))
	end
	str = str .. util.tabify(string.format("\nbody:\n%s", self.body:__tostring(tablevel+2)), tablevel+1)
	return str
end

function IR.FunctionDefinition:emitCCode()
	return string.format("%s\n{\n%s\n}\n", self:cPrototype(), util.tabify(self.body:emitCCode(), 1))
end

function IR.FunctionDefinition:emitTerraCode()
	local arglist = util.map(function(argvar) return argvar.value end, self.args)
	return
		terra([arglist])
			[self.body:emitTerraCode()]
		end
end


return IR
