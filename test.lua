local util = require "util"
util.openpackage(util)
local pr = require "probabilistic"
openpackage(pr)

samples = 150
lag = 20
runs = 5
errorTolerance = 0.07

function test(name, estimates, trueExpectation, tolerance)
	tolerance = tolerance or errorTolerance
	io.write("test: " .. name .. "...")
	local errors = util.map(function(est) return math.abs(est - trueExpectation) end, estimates)
	local meanAbsError = mean(errors)
	if meanAbsError > tolerance then
		print(string.format("failed! True mean: %g | Test mean: %g", trueExpectation, mean(estimates)))
	else
		print("passed.")
	end
end

-------------------------

print("starting tests...")


-- Tests adapted from Church

test("random, no query",
	 replicate(runs,
	 	function() return mean(replicate(samples,
	 		function() return flip(0.7) end))
	 	end),
	 0.7)

print("tests done!")