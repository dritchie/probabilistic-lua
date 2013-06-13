
local mt = terralib.require("probabilistic.mathtracing")

local function traceCompileRun(fn, args)
	mt.setRealNumberType(double)
	mt.on()
	local retval = fn()
	mt.off()
	local compiledFn = mt.compileTrace(retval)
	return compiledFn(unpack(args))
end

local function eqtest(name, fn, args, val)
	io.write(string.format("test: %s...", name))
	local retval = traceCompileRun(fn, args)
	if retval == val then
		print("passed")
	else
		print(string.format("failed! Got %g, expected %g", retval, val))
	end
end


eqtest(
	"calling precompiled function with no return values",
	function()
		local C = terralib.includec("stdio.h")
		local x = mt.makeParameterNode("x", int)
		x = x+1
		C.printf("%d", x)
		return x
	end,
	{0},
	1)

eqtest(
	"calling precompiled function with one return value",
	function()
		local terra incr(y: int) : int
			return y + 1
		end
		local x = mt.makeParameterNode("x", int)
		return incr(x)
	end,
	{0},
	1)

eqtest(
	"calling precompiled function with multiple return values",
	function()
		local terra incr(u: int, v: int) : {int, int}
			return u+1, v+1
		end
		local x = mt.makeParameterNode("x", int)
		local y = mt.makeParameterNode("y", int)
		x, y = incr(x, y)
		return x+y
	end,
	{0, 0},
	2)