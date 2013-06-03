
-- Can't have the JIT if we're using the debug library
--jit.off()

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
--          print(tr:currentName(0))
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

-- local thing = 2
-- local function foo()
--    print(thing)
-- end
-- foo()

-------------------

-- pr = require "probabilistic"
-- util = require "util"
-- util.openpackage(pr)
-- util.openpackage(util)

-- function testcomp()
--    local a = int2bool(flip())
--    local b = int2bool(flip())
--    condition(a or b)
--    return bool2int(a and b)
-- end

-- traceMH(testcomp, 1000)

-------------------

pr = require("probabilistic")
util = require("probabilistic.util")
erp = require("probabilistic.erp")
util.openpackage(pr)

function circleOfDots()

	-- helpers
	local function norm(v)
		return math.sqrt(v.x*v.x + v.y*v.y)
	end
	local function dist(p1, p2)
		local xdiff = p1.x - p2.x
		local ydiff = p1.y - p2.y
		return math.sqrt(xdiff*xdiff + ydiff*ydiff)
	end
	local function angDP(p1, p2, p3)
		local v1 = { x = p1.x - p2.x, y = p1.y - p2.y}
		local v2 = { x = p3.x - p2.x, y = p3.y - p2.y}
		return (v1.x*v2.x + v1.y*v2.y) / (norm(v1)*norm(v2))
	end

	-- params
	local numDots = 6
	local gmean = 0
	local gsd = 2
	local targetdist = 0.5
	local distsd = 0.1
	local targetdp = -1.0
	local dpsd = 0.1

	-- prior
	local points = {}
	for i=1,numDots do
		table.insert(points, { x = gaussian(gmean, gsd), y = gaussian(gmean, gsd) })
	end

	-- distance between pairs factors
	for i=0,numDots-1 do
		local j = ((i+1) % numDots) + 1
		local d = dist(points[i+1], points[j])
		factor(erp.gaussian_logprob(d, targetdist, distsd))
	end

	-- angle between triples factors
	for i=0,numDots-1 do
		local j = ((i+1) % numDots)+1
		local k = ((i+2) % numDots)+1
		local dp = angDP(points[i+1], points[j], points[k])
		factor(erp.gaussian_logprob(dp, targetdp, dpsd))
	end

	return points
end

-----------

local numsamps = 100000

local t11 = os.clock()
LARJMH(circleOfDots, numsamps, 0, nil, 1, true)
local t12 = os.clock()

local t21 = os.clock()
fixedStructureDriftMH(circleOfDots, {}, 0.25, numsamps, 1, true)
local t22 = os.clock()

print(string.format("Uncompiled: %g", (t12 - t11)))
print(string.format("Compiled: %g", (t22 - t21)))
