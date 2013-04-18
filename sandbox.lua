
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

local i = 0

function foo()
	i = i + 1
end

print(i)
foo()
print(i)