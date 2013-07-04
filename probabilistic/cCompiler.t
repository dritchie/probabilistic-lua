local util = require("probabilistic.util")
local hmc = terralib.require("probabilistic.hmc")
local IR = terralib.require("probabilistic.IR")


local function interfacePreamble(ishmc)
	if not ishmc then
		return ""
	else
		return hmc.lpInterfacePreamble()
	end
end

local function implementationPreamble(ishmc)
	if not ishmc then
		return "#include <math.h>"
	else
		return hmc.lpImplementationPreamble()
	end
end

local function compileCommand(ishmc)
	if not ishmc then
		return "clang -shared -O3"
	else
		return hmc.lpCompileCommand()
	end
end

local function preprocessIR(fnir, ishmc)
	if ishmc then
		-- Introduce a variable which casts the argument vals pointer
		-- from num* to stan::agrad::var*.
		-- Make all the references to the original argument refer to this new
		-- varaible instead
		local vals = table.remove(fnir.args, 1)
		local origValSymbol = vals.value
		local newValSymbol = {displayname = "stanVals", type = "stan::agrad::var*"}
		vals.value = newValSymbol
		local stanVals = vals
		stanVals.isIntermediate = true
		vals = IR.VarNode:new(origValSymbol)
		table.insert(fnir.args, 1, vals)
		local castExpr = IR.CastNode:new("stan::agrad::var*", vals)
		table.insert(fnir.body.statements, 1, IR.VarAssignmentStatement:new({stanVals}, {castExpr}))
		-- Cast all return values back to num.
		if not fnir.hasMultipleReturns then
			local returnStatement = table.remove(fnir.body.statements)
			local returnExp = returnStatement.exps[1]
			local tempVar = IR.VarNode:new({displayname = "numCastTmp", type = "stan::agrad::var"}, true)
			table.insert(fnir.body.statements, IR.VarAssignmentStatement:new({tempVar}, {returnExp}))
			local castedRetExp = IR.ArbitraryCExpression:new(
				function() return string.format("*((num*)&(%s))", tempVar:emitCCode()) end)
			table.insert(fnir.body.statements, IR.ReturnStatement:new({castedRetExp}))
		else
			local fieldAssign = table.remove(fnir.body.statements, #fnir.body.statements - 1)
			local tempVars = {}
			local castExprs = {}
			for i=1,fnir.numMultipleReturns do
				local tv = IR.VarNode:new({displayname = string.format("numCastTmp_%d", i), type = "stan::agrad::var"})
				table.insert(tempVars, tv)
				table.insert(castExprs, IR.ArbitraryCExpression:new(function()
					return string.format("*((num*)&(%s))", tv:emitCCode()) end))
			end
			table.insert(fnir.body.statements, #fnir.body.statements-1, IR.VarAssignmentStatement:new(tempVars, fieldAssign.rhslist))
			table.insert(fnir.body.statements, #fnir.body.statements-1, IR.AssignmentStatement(fieldAssign.lhslist, castExprs))
		end
	end
end

local function compile(fnir, realnumtype)
	local ishmc = false
	if realnumtype == hmc.num then
		ishmc = true
	end
	if not ishmc and not realnumtype == double then
		error("Unsupported real number type -- must be 'double' or 'hmc.num'")
	end

	preprocessIR(fnir, ishmc)

	local cppname = string.format("__%s.cpp", fnir.name)
	local soname = string.gsub(cppname, ".cpp", ".so")
	local code = string.format([[
#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__ ((visibility ("default")))
#endif
%s
extern "C" {
%s
EXPORT %s
}
	]], implementationPreamble(ishmc), fnir:cReturnTypeDefinition(), fnir:emitCCode())
	--print(code)
	local srcfile = io.open(cppname, "w")
	srcfile:write(code)
	srcfile:close()
	util.wait(string.format("%s %s -o %s", compileCommand(ishmc), cppname, soname))
	local cdecs = string.format([[
%s
%s
%s;
	]], interfacePreamble(ishmc), fnir:cReturnTypeDefinition(), fnir:cPrototype())
	local C = terralib.includecstring(cdecs)
	terralib.linklibrary(soname)
	local fn = C[fnir.name]
	fn:compile()
	util.wait(string.format("rm -f %s 2>&1", cppname))
	util.wait(string.format("rm -f %s 2>&1", soname))
	return fn
end

return 
{
	compile = compile
}