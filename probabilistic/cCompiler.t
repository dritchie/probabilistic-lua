local util = require("probabilistic.util")
local hmc = terralib.require("probabilistic.hmc")


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
		-- We need to convert the argument type/return type
		-- from/to stan::agrad::var
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