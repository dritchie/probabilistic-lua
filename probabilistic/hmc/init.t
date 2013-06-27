local util = terralib.require("probabilistic.util")

-- Compile the the shared library, if it doesn't exist.
local sourcefile = debug.getinfo(1, "S").source
local soname = sourcefile:gsub("init.t", "hmc.so")
local f = io.open(soname, "r")
if f then
	f:close()
else
	local cppname = sourcefile:gsub("init.t", "hmc.cpp")
	local stanroot = os.getenv("STAN_ROOT")
	if not stanroot then
		error("Environment variable STAN_ROOT not defined--couldn't find stan headers!")
	end
	local srcdir = string.format("%s/src", stanroot)
	local eigendir = string.format("%s/lib/eigen_3.1.2", stanroot)
	local boostdir = string.format("%s/lib/boost_1.53.0", stanroot)
	local varstack = string.format("%s/src/stan/agrad/rev/var_stack.cpp", stanroot)
	util.wait(string.format("clang++ -shared -O3 -I%s -I%s -I%s %s %s -o %s 2>&1", srcdir, eigendir, boostdir, cppname, varstack, soname))
end

-- Link the library
local hname = sourcefile:gsub("init.t", "hmc.h")
local hmc = terralib.includec(hname)
terralib.linklibrary(soname)

return hmc