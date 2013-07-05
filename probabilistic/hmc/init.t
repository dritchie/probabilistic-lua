local util = terralib.require("probabilistic.util")

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
local sourcefile = debug.getinfo(1, "S").source
local soname = sourcefile:gsub("init.t", "libhmc.so")
local f = io.open(soname, "r")
if f then
	f:close()
else
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



return hmc