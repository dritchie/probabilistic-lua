
-- local C = terralib.includecstring[[
-- int incrementNumber(int x) { return x + 1; }
-- ]]
-- terralib.saveobj("test.o", {incrementNumber = C.incrementNumber})


-- local C = terralib.includecstring[[
-- int incrementNumber(int x);
-- ]]
-- terralib.linklibrary("test.o")
-- print(C.incrementNumber(41))

-----------------

-- local C1 = terralib.includecstring[[
-- int val = 5;
-- int getVal
-- ]]

------------------

-- local ffi = require("ffi")
-- ffi.cdef([[
-- double sqrt(double x)
-- ]])
-- local function sqrtWrapper(x)
-- 	return ffi.C.sqrt(x)
-- end
-- sqrtWrapper = terralib.cast({double} -> {double}, sqrtWrapper)
-- terra callSqrt(x: double)
-- 	return sqrtWrapper(x)
-- end
-- print(callSqrt(25))

-------------------

-- A = terralib.includecstring[[
-- typedef struct { int val; } Thing;
-- int getValA(Thing t) { return t.val; }
-- ]]

-- B = terralib.includecstring[[
-- typedef struct { int val; } Thing;
-- int getValB(Thing t) { return t.val; }
-- ]]

-- a = terralib.new(A.Thing)
-- b = terralib.new(B.Thing)

-- function A.Thing.metamethods.__cast(from, to, exp)
-- 	if from == A.Thing and to == B.Thing then
-- 		local bthing = terralib.new(B.Thing)
-- 		bthing.val = exp.val
-- 		return bthing
-- 	elseif from == B.Thing and to == A.Thing then
-- 		local athing = terralib.new(A.Thing)
-- 		athing.val = exp.val
-- 		return athing
-- 	else
-- 		error("Invalid cast between 'Thing's")
-- 	end
-- end	

-- local terra cast(a: A.Thing) : {B.Thing}
-- 	return [B.Thing](a)
-- end

-- print(B.getValB(cast(a)))

---------------------

-- C = terralib.includecstring [[
-- typedef struct { int val; } Derp;
-- int getVal(Derp d) { return d.val; }
-- ]]

-- dtemplate = terralib.new(C.Derp)
-- ffi = require("ffi")
-- ffi.metatype(dtemplate,
-- {
-- 	__add =
-- 	function(d1, d2)
-- 		local d = terralib.new(C.Derp)
-- 		d.val = d1.val + d2.val
-- 		return d
-- 	end 
-- })
-- -- function C.Derp.metamethods.__add(d1, d2)
-- -- 	local d = terralib.new(C.Derp)
-- -- 	d.val = d1.val + d2.val
-- -- end

-- d1 = terralib.new(C.Derp)
-- d1.val = 1
-- d2 = terralib.new(C.Derp)
-- d2.val = 2

-- dsum = d1 + d2
-- print(dsum.val)

-------------------------


-- struct Derp { val: int }

-- d = nil

-- terra derefDerp(dptr: &Derp)
-- 	return @dptr
-- end

-- function setD(newd)
-- 	d = derefDerp(newd)
-- end

-- terra tsetD(newd: Derp)
-- 	setD(&newd)
-- end

-- terra tsetDNoArg()
-- 	var newd = Derp { 42 };
-- 	tsetD(newd)
-- end

-- newd = terralib.new(Derp, 42)
-- tsetD(newd)
-- print(d.val)

---------------------------

-- terra foo(val: int)
-- 	return val + 1
-- end

-- terra bar(fn: {int} -> {int}, val: int)
-- 	return fn(val)
-- end

-- print(bar(foo.definitions[1]:getpointer(), 1))

-----------------------------

-- terra retBool()
-- 	var i : int = 1
-- 	var b : bool = [bool](i)
-- 	return b
-- end

-- print(retBool())

-------------------------------

-- C = terralib.includec("stdio.h")

-- terra retpi()
-- 	var p = [math.pi]
-- 	C.printf("%g\n", p)
-- 	return p
-- end

-- print(retpi())

---------------------------------

-- hmc = terralib.require("probabilistic.hmc")
-- hmc.toggleLuaAD(true)
-- n1 = hmc.makeNum(42)
-- n2 = hmc.makeNum(1)
-- n3 = n1 + n2 + 1
-- print(hmc.getValue(n3))

--------------------------

-- random = require("probabilistic.random")
-- hmc = terralib.require("probabilistic.hmc")
-- mean = 0.1
-- sd = 0.5
-- print(random.gaussian_logprob(0.2, mean, sd))
-- print(math.sqrt(354))
-- hmc.toggleLuaAD(true)
-- print(hmc.getValue(random.gaussian_logprob(hmc.makeNum(0.2), hmc.makeNum(mean), hmc.makeNum(sd))))
-- print(hmc.getValue(math.sqrt(hmc.makeNum(354))))

-- local Foo = terralib.includecstring[[
-- double foo(double d)
-- {
-- 	return 2.0*d;
-- }

-- typedef struct
-- {
-- 	double d;
-- } Foo;

-- Foo foo(Foo f)
-- {
-- 	Foo retf;
-- 	retf.d = 2.0*f.d;
-- 	return retf;
-- }
-- ]]


--------------------------






