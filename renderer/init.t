local util = require("probabilistic.util")


local sourcefile = debug.getinfo(1, "S").source
local dir = sourcefile:gsub("init.t", "")


-- Make sure the library exists and is up-to-date
util.wait(string.format("cd %s; make", dir))

-- Load the necessary headers into terra modules
local ifaceHeader = sourcefile:gsub("init.t", "cInterface.h")
local numheader = sourcefile:gsub("init.t", "../probabilistic/hmc/num.h")
local doubleImpl = terralib.includecstring(string.format([[
#define NUMTYPE double
#include "%s"
]], ifaceHeader))
local dualnumImpl = terralib.includecstring(string.format([[
#include "%s"
#define NUMTYPE num
#include "%s"
]], numheader, ifaceHeader))

-- Link the library
local soname = sourcefile:gsub("init.t", "librender.so")
terralib.linklibrary(soname)

-- Create overloaded Terra functions for each of the exported functions
--    in the library
-- Put the hmc.num versions first, so that they'll get resolved faster(?)
local M = {}
for name,val in pairs(dualnumImpl) do
	if terralib.isfunction(val) and name:find("Framebuffer") then
		local rootName = name:gsub("Framebuffernum", "")
		local actualName = name:gsub("Framebuffernum", "Framebuffer")
		M[actualName] = val
		-- Create the overload
		local key = string.format("Framebufferdouble%s", rootName)
		val = doubleImpl[key]
		M[actualName]:adddefinition(val:getdefinitions()[1])
	end
end

return M
