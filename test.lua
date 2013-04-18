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

function mhtest(name, computation, trueExpectation, tolerance)
	tolerance = tolerance or errorTolerance
	test(name, replicate(runs, function() return expectation(computation, traceMH, samples, lag) end), trueExpectation, tolerance)
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

mhtest(
	"setting a flip",
	function()
		local a = 1 / 1000
		condition(flip(a))
		return a
	end,
	1/1000,
	0.000000000000001)

mhtest(
	"unconditioned flip",
	function() return flip(0.7) end,
	0.7)

print("tests done!")