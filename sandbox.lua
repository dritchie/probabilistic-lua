
-- Can't have the JIT if we're using the debug library
jit.off()

-- function foo()
-- 	local function bar(num1, num2)
-- 		print(num1)
-- 		print(num2)
-- 		print(debug.getinfo(1, 'p').fnprotoid)
-- 	end
-- 	bar(debug.getinfo(1, 'p').bytecodepos, debug.getinfo(1, 'p').bytecodepos)
-- end

-- foo()
-- foo()

-- function docall()
-- 	print("herp derp")
-- end
-- obj = {}
-- setmetatable(obj, {__call = docall})
-- obj()


---------------

-- trace = require "probabilistic.trace"

-- tr = trace.newTrace(function() return 5 end)

-- function foo()
-- 	print(tr:currentName(0))
-- 	local function bar()
-- 		print(tr:currentName(0))
-- 		local function baz()
-- 			print(tr:currentName(0))
-- 		end
-- 		baz()
-- 	end
-- 	bar()
-- end
-- foo()

---------------

-- local i = 0

-- function foo()
-- 	i = i + 1
-- end

-- print(i)
-- foo()
-- print(i)

-----------------

-- bar = function ()
-- 	local function foo(x)
-- 		print(debug.getinfo(1, 'p').frameid)
-- 		if x > 0 then
-- 			foo(x-1)
-- 		end
-- 	end
-- 	foo(4)
-- end
-- bar()

----------------

-- function bar(x)
-- 	print(debug.getinfo(1, 'p').frameid)
-- 	if x == 0 then
-- 		return x
-- 	else
-- 		return foo(x-1)
-- 	end
-- end

-- function foo(x)
-- 	print(debug.getinfo(1, 'p').frameid)
-- 	if x == 0 then
-- 		return x
-- 	else
-- 		return bar(x-1)
-- 	end
-- end

-- foo(5)

-------------------

-- obj = {num = 42}

-- function obj:call()
-- 	print(self.num)
-- end

-- setmetatable(obj, {__call = obj.call})

-- obj()

--------------------

-- memoize = require "probabilistic.memoize"
-- erp = require "probabilistic.erp"

-- function flip(x)
--    return erp.flip(x)
-- end

-- memflip = memoize.mem(flip)

-- for i=1,100 do
--    --print(memflip(0.5))
--    print(flip(0.5))
-- end

-------------------

-- function foo()
--    local x, y, z
--    x  = 0
--    print(x)
--    print(y)
--    y = 4
-- end
-- foo()

-- print(y)

-------------------

-- function foo(x, y, z)
--    print(x + y + z)
-- end

-- tbl = {1, 2, 3}
-- foo(unpack(tbl))

-------------------

local thing = 2
local function foo()
   print(thing)
end
foo()