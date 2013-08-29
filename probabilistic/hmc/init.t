local util = terralib.require("probabilistic.util")
local ffi = require("ffi")

local unaryOps = 
{
	{"unm", "-"}
}	
local unaryFns = 
{
	{"abs"},
	{"acos"},
	{"asin"},
	{"atan"},
	{"ceil"},
	{"cos"},
	{"cosh"},
	{"exp"},
	{"floor"},
	{"log"},
	{"log10"},
	{"sin"},
	{"sinh"},
	{"sqrt"},
	{"tan"},
	{"tanh"}
}
local binaryOps =
{	
	{"add", "+"}, 
	{"sub", "-"},
	{"mul", "*"},
	{"div", "/"},
	{"eq", "==", true},
	{"lt", "<", true},
	{"le", "<=", true}
}
local binaryFns = 
{
	{"atan2"},
	{"fmin"},
	{"fmax"},
	{"fmod"},
	{"pow"}
}


local stanroot = os.getenv("STAN_ROOT")
if not stanroot then
	error(
	[[
Environment variable STAN_ROOT not defined--couldn't find stan source code!
Download stan v1.3.0 at http://mc-stan.org/
	]])
end

local srcdir = string.format("%s/src", stanroot)
local eigendir = string.format("%s/lib/eigen_3.1.2", stanroot)
local boostdir = string.format("%s/lib/boost_1.53.0", stanroot)

-- Compile the the shared library, if it doesn't exist.
local sourcefile = debug.getinfo(1, "S").source:gsub("@", "")
local soname = sourcefile:gsub("init.t", "libhmc.so")
local f = io.open(soname, "r")
if f then
	f:close()
else

	-- Generate C++ prototypes and implementations for all the arithmetic functions we need
	-- Write them to files that are included by hmc.h and hmc.cpp

	local function genUnaryCppProto(record)
		local name = record[1]
		return string.format("num %s_AD(num x)", name)
	end

	local function genUnaryCppImpl(record)
		local name = record[1]
		local op = record[2] or name
		return string.format([[
			EXPORT %s
			{
				stan::agrad::var xx = *(stan::agrad::var*)(&x);
				xx = %s(xx);
				return *(num*)(&xx);
			}
		]], genUnaryCppProto(record), op)
	end

	local function genBinaryCppProto(record)
		local name = record[1]
		local isBool = record[3]
		if isBool then
			return string.format("int %s_AD(num x, num y)", name)
		else
			return string.format("num %s_AD(num x, num y)", name)
		end
	end

	local function genBinaryCppImpl_Op(record)
		local name = record[1]
		local op = record[2]
		local isBool = record[3]
		if isBool then
			return string.format([[
			EXPORT %s
			{
				stan::agrad::var xx = *(stan::agrad::var*)(&x);
				stan::agrad::var yy = *(stan::agrad::var*)(&y);
				bool b = xx %s yy;
				return (int)b;
			}
			]], genBinaryCppProto(record), op)
		else
			return string.format([[
			EXPORT %s
			{
				stan::agrad::var xx = *(stan::agrad::var*)(&x);
				stan::agrad::var yy = *(stan::agrad::var*)(&y);
				xx = xx %s yy;
				return *(num*)(&xx);
			}
			]], genBinaryCppProto(record), op)
		end
	end

	local function genBinaryCppImpl_Fn(record)
		local name = record[1]
		return string.format([[
			EXPORT %s
			{
				stan::agrad::var xx = *(stan::agrad::var*)(&x);
				stan::agrad::var yy = *(stan::agrad::var*)(&y);
				xx = %s(xx, yy);
				return *(num*)(&xx);
			}
		]], genBinaryCppProto(record), name)	
	end

	local headerFile = io.open(sourcefile:gsub("init.t", "adMath.h"), "w")
	local cppFile = io.open(sourcefile:gsub("init.t", "adMath.cpp"), "w")
	for i,v in ipairs(util.joinarrays(unaryOps, unaryFns)) do
		headerFile:write(string.format("%s;\n", genUnaryCppProto(v)))
		cppFile:write(string.format("%s\n", genUnaryCppImpl(v)))
	end
	for i,v in ipairs(binaryOps) do
		headerFile:write(string.format("%s;\n", genBinaryCppProto(v)))
		cppFile:write(string.format("%s\n", genBinaryCppImpl_Op(v)))
	end
	for i,v in ipairs(binaryFns) do
		headerFile:write(string.format("%s;\n", genBinaryCppProto(v)))
		cppFile:write(string.format("%s\n", genBinaryCppImpl_Fn(v)))
	end
	headerFile:close()
	cppFile:close()

	-- Actually build the shared library
	local cppname = sourcefile:gsub("init.t", "hmc.cpp")
	local varstack = string.format("%s/src/stan/agrad/rev/var_stack.cpp", stanroot)
	util.wait(string.format("clang++ -shared -O3 -I%s -I%s -I%s %s %s -o %s", srcdir, eigendir, boostdir, cppname, varstack, soname))
	--util.wait(string.format("clang++ -O0 -g -shared -I%s -I%s -I%s %s %s -o %s", srcdir, eigendir, boostdir, cppname, varstack, soname))
end



-- Link the library
local hname = sourcefile:gsub("init.t", "hmc.h")
local hmc = terralib.includec(hname)
terralib.linklibrary(soname)



-- Add some extra utility functions

local hmcdir = sourcefile:gsub("init.t", "")
function hmc.lpCompileCommand()
	return string.format("clang++ -shared -O3 -I%s -I%s -I%s -L%s -lhmc", srcdir, eigendir, boostdir, hmcdir)
end

local numDef = io.open(sourcefile:gsub("init.t", "num.h"), "r"):read("*all")
function hmc.lpInterfacePreamble()
	return numDef
end

local varDef = io.open(sourcefile:gsub("init.t", "var.h"), "r"):read("*all")
function hmc.lpImplementationPreamble()
	return string.format([[
	%s
	%s
	]], varDef, numDef)
end


-- Add LuaJIT ctype metamethods/functions for arithmetic to hmc.num

local function checkConvertToNum(n)
	-- Not a complete check, but hopefully fast-ish
	local t = type(n)
	if t == "number"
		then return hmc.makeNum(n)
	else
		return n
	end
end

local numMT = {}
for i,v in ipairs(unaryOps) do
	local cfnname = string.format("%s_AD", v[1])
	local cfn = hmc[cfnname]
	numMT[string.format("__%s", v[1])] =
		function(n) return cfn(checkConvertToNum(n)) end
end
for i,v in ipairs(binaryOps) do
	local cfnname = string.format("%s_AD", v[1])
	local cfn = hmc[cfnname]
	local isBool = v[3]
	if isBool then
		numMT[string.format("__%s", v[1])] =
			function(n1, n2) return util.int2bool(cfn(checkConvertToNum(n1), checkConvertToNum(n2))) end
	else
		numMT[string.format("__%s", v[1])] =
			function(n1, n2) return cfn(checkConvertToNum(n1), checkConvertToNum(n2)) end
	end
end
local dummynum = hmc.makeNum(42)
ffi.metatype(dummynum, numMT)

local admath = util.copytable(math)
for i,v in ipairs(unaryFns) do
	local origMathFn = math[v[1]]
	local cfnname = string.format("%s_AD", v[1])
	local cfn = hmc[cfnname]
	admath[v[1]] =
		function(n)
			if type(n) == "number" then
				return origMathFn(n)
			else
				return cfn(checkConvertToNum(n)) 
			end
		end
end
for i,v in ipairs(binaryFns) do
	local origMathFn = math[v[1]]
	local cfnname = string.format("%s_AD", v[1])
	local cfn = hmc[cfnname]
	admath[v[1]] =
		function(n1, n2)
			if type(n1) == "number" and type(n2) == "number" then
				return origMathFn(n1, n2)
			else
				return cfn(checkConvertToNum(n1), checkConvertToNum(n2))
			end
		end
end

local _math = nil
local _luaADon = false
function hmc.toggleLuaAD(flag)
	if flag then
		_luaADon = true
		_math = math
		_G["math"] = admath
	else
		_luaADon = false
		_G["math"] = _math
		_math = nil
	end
end
function hmc.luaADIsOn()
	return _luaADon
end

return hmc



