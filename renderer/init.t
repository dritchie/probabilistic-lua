local util = require("probabilistic.util")


local sourcefile = debug.getinfo(1, "S").source:gsub("@", "")
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

local distImpl = terralib.includecstring(string.format([[
#include "%s"
]], sourcefile:gsub("init.t", "dist.h")),
string.format("-I%s", sourcefile:gsub("init.t", "../probabilistic/hmc/")))

local extras = terralib.includecstring(string.format([[
#include "%s"
]], sourcefile:gsub("init.t", "extra.h")),
string.format("-I%s", sourcefile:gsub("init.t", "../probabilistic/hmc/")))

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

-- Add extra overloads for the Framebuffer distance function.
local n_d_dist = distImpl["Framebuffer_num_double_distance"]
M["Framebuffer_distance"]:adddefinition(n_d_dist:getdefinitions()[1])

-- Add in anything from extras
for n,v in pairs(extras) do
	if terralib.isfunction(v) and n:find("Framebuffer") then
		M[n] = v
	end
end

return M
