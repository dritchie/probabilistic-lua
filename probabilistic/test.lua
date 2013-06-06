local util = require("probabilistic.util")
util.openpackage(util)
local pr = require("probabilistic")
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
	--test(name, replicate(runs, function() return expectation(computation, traceMH, samples, lag) end), trueExpectation, tolerance)
	test(name, replicate(runs, function() return expectation(computation, LARJMH, samples, 0, nil, lag) end), trueExpectation, tolerance)
end

function larjtest(name, computation, trueExpectation, tolerance)
	tolerance = tolerance or errorTolerance
	test(name, replicate(runs, function() return expectation(computation, LARJMH, samples, 10, nil, lag) end), trueExpectation, tolerance)
end

function eqtest(name, estvalues, truevalues, tolerance)
	tolerance = tolerance or errorTolerance
	io.write("test: " .. name .. "...")
	assert(table.getn(estvalues) == table.getn(truevalues))
	for i=1,table.getn(estvalues) do
		local estvalue = estvalues[i]
		local truevalue = truevalues[i]
		if math.abs(estvalue - truevalue) > tolerance then
			print(string.format("failed! True value: %g | Test value: %g", truevalue, estvalue))
			return
		end
	end
	print "passed."
end

-------------------------

local t1 = os.clock()

print("starting tests...")


-- ERP tests

test("flip sample",
	 replicate(runs,
	 	function() return mean(replicate(samples,
	 		function() return flip(0.7) end))
	 	end),
	 0.7)

mhtest(
	"flip query",
	function() return flip(0.7) end,
	0.7)

test("uniform sample",
	 replicate(runs,
	 	function() return mean(replicate(samples,
	 		function() return uniform(0.1, 0.4) end))
	 	end),
	 0.5*(.1+.4))

mhtest(
	"uniform query",
	function() return uniform(0.1, 0.4) end,
	0.5*(.1+.4))

test("multinomial sample",
	 replicate(runs,
	 	function() return mean(replicate(samples,
	 		function() return multinomialDraw({.2, .3, .4}, {.2, .6, .2}) end))
	 	end),
	 0.2*.2 + 0.6*.3 + 0.2*.4)

mhtest(
	"multinomial query",
	function() return multinomialDraw({.2, .3, .4}, {.2, .6, .2}) end,
	0.2*.2 + 0.6*.3 + 0.2*.4)

eqtest(
	"multinomial lp",
	{
		multinomial_logprob(1, {.2, .6, .2}),
		multinomial_logprob(2, {.2, .6, .2}),
		multinomial_logprob(3, {.2, .6, .2})
	},
	{math.log(0.2), math.log(0.6), math.log(0.2)})

test("gaussian sample",
	 replicate(runs,
	 	function() return mean(replicate(samples,
	 		function() return gaussian(0.1, 0.5) end))
	 	end),
	 0.1)

mhtest(
	"gaussian query",
	function() return gaussian(0.1, 0.5) end,
	0.1)

eqtest(
	"gaussian lp",
	{
		gaussian_logprob(0, 0.1, 0.5),
		gaussian_logprob(0.25, 0.1, 0.5),
		gaussian_logprob(0.6, 0.1, 0.5)
	},
	{-0.2457913526447274, -0.27079135264472737, -0.7257913526447274})

test("gamma sample",
	 replicate(runs,
	 	function() return mean(replicate(samples,
	 		function() return gamma(2, 2)/10 end))
	 	end),
	0.4)

mhtest(
	"gamma query",
	function() return gamma(2, 2)/10 end,
	0.4)

eqtest(
	"gamma lp",
	{
		gamma_logprob(1, 2, 2),
		gamma_logprob(4, 2, 2),
		gamma_logprob(8, 2, 2)
	},
	{-1.8862944092546166, -2.000000048134726, -3.306852867574781})

test("beta sample",
	 replicate(runs,
	 	function() return mean(replicate(samples,
	 		function() return beta(2, 5) end))
	 	end),
	2.0/(2+5))

mhtest(
	"beta query",
	function() return beta(2, 5) end,
	2.0/(2+5))

eqtest(
	"beta lp",
	{
		beta_logprob(.1, 2, 5),
		beta_logprob(.2, 2, 5),
		beta_logprob(.6, 2, 5)
	},
	{0.677170196389683, 0.899185234324094, -0.7747911992475776})

test("binomial sample",
	 replicate(runs,
	 	function() return mean(replicate(samples,
	 		function() return binomial(.5, 40)/40 end))
	 	end),
	0.5)

mhtest(
	"binomial query",
	function() return binomial(.5, 40)/40 end,
	0.5)

eqtest(
	"binomial lp",
	{
		binomial_logprob(15, .5, 40),
		binomial_logprob(20, .5, 40),
		binomial_logprob(30, .5, 40)
	},
	{-3.3234338674089985, -2.0722579911387817, -7.2840211276953575})

test("poisson sample",
	 replicate(runs,
	 	function() return mean(replicate(samples,
	 		function() return poisson(4)/10 end))
	 	end),
	0.4)

mhtest(
	"poisson query",
	function() return poisson(4)/10 end,
	0.4)

eqtest(
	"poisson lp",
	{
		poisson_logprob(2, 4),
		poisson_logprob(5, 4),
		poisson_logprob(7, 4)
	},
	{-1.9205584583201643, -1.8560199371825927, -2.821100833226181})


-- Tests adapted from Church

mhtest(
	"setting a flip",
	function()
		local a = 1 / 1000
		condition(int2bool(flip(a)))
		--condition(flip(a))
		return a
	end,
	1/1000,
	0.000000000000001)

mhtest(
	"and conditioned on or",
	function()
		local a = int2bool(flip())
		local b = int2bool(flip())
		condition(a or b)
		return bool2int(a and b)
	end,
	1/3)

mhtest(
	"and conditioned on or, biased flip",
	function()
		local a = int2bool(flip(0.3))
		local b = int2bool(flip(0.3))
		condition(a or b)
		return bool2int(a and b)
	end,
	(0.3*0.3) / (0.3*0.3 + 0.7*0.3 + 0.3*0.7))

mhtest(
	"contitioned flip",
	function()
		local bitflip = function(fidelity, x) return flip(int2bool(x) and fidelity or 1-fidelity) end
		local hyp = flip(0.7)
		condition(int2bool(bitflip(0.8, hyp)))
		return hyp
	end,
	(0.7*0.8) / (0.7*0.8 + 0.3*0.2))

mhtest(
	"random 'if' with random branches, unconditioned",
	function()
		if int2bool(flip(0.7)) then
			return flip(0.2)
		else
			return flip(0.8)
		end
	end,
	0.7*0.2 + 0.3*0.8)

mhtest(
	"flip with random weight, unconditioned",
	function() return flip(int2bool(flip(0.7)) and 0.2 or 0.8) end,
	0.7*0.2 + 0.3*0.8)

mhtest(
	"random procedure application, unconditioned",
	function()
		local proc = int2bool(flip(0.7)) and (function(x) return flip(0.2) end) or (function(x) return flip(0.8) end)
		return proc(1)
	end,
	0.7*0.2 + 0.3*0.8)

mhtest(
	"conditioned multinomial",
	function()
		local hyp = multinomialDraw({"b", "c", "d"}, {0.1, 0.6, 0.3})
		local function observe(x)
			if int2bool(flip(0.8)) then
				return x
			else
				return "b"
			end
		end
		condition(observe(hyp) == "b")
		return bool2int(hyp == "b")
	end,
	0.357)

mhtest(
	"recursive stochastic fn, unconditioned (tail recursive)",
	function()
		local function powerLaw(prob, x)
			if int2bool(flip(prob, true)) then
				return x
			else
				return powerLaw(prob, x+1)
			end
		end
		local a = powerLaw(0.3, 1)
		return bool2int(a < 5)
	end, 
	0.7599)

mhtest(
	"recursive stochastic fn, unconditioned",
	function()
		local function powerLaw(prob, x)
			if int2bool(flip(prob, true)) then
				return x
			else
				return 0 + powerLaw(prob, x+1)
			end
		end
		local a = powerLaw(0.3, 1)
		return bool2int(a < 5)
	end, 
	0.7599)

mhtest(
	"memoized flip, unconditioned",
	function()
		local proc = mem(function(x) return int2bool(flip(0.8)) end)
		local p11 = proc(1)
		local p21 = proc(2)
		local p12 = proc(1)
		local p22 = proc(2)
		return bool2int(p11 and p21 and p12 and p22)
	end,
	0.64)

mhtest(
	"memoized flip, conditioned",
	function()
		local proc = mem(function(x) return int2bool(flip(0.2)) end)
		local p1 = proc(1)
		local p21 = proc(2)
		local p22 = proc(2)
		local p23 = proc(2)
		condition(p1 or p21 or p22 or p23)
		return bool2int(proc(1))
	end,
	0.5555555555555555)

mhtest(
	"bound symbol used inside memoizer, unconditioned",
	function()
		local a = flip(0.8)
		local proc = mem(function(x) return int2bool(a) end)
		local p11 = proc(1)
		local p12 = proc(1)
		return bool2int(p11 and p12)
	end,
	0.8)

mhtest(
	"memoized flip with random argument, unconditioned",
	function()
		local proc = mem(function(x) return int2bool(flip(0.8)) end)
		local p1 = proc(uniformDraw({1,2,3}, true))
		local p2 = proc(uniformDraw({1,2,3}, true))
		return bool2int(p1 and p2)
	end,
	0.6933333333333334)

mhtest(
	"memoized random procedure, unconditioned",
	function()
		local proc = int2bool(flip(0.7)) and
			(function(x) return int2bool(flip(0.2)) end) or
			(function(x) return int2bool(flip(0.8)) end)
		local memproc = mem(proc)
		local mp1 = memproc(1)
		local mp2 = memproc(2)
		return bool2int(mp1 and mp2)
	end,
	0.22)

mhtest(
	"mh-query over rejection query for conditioned flip",
	function()
		local function bitflip(fidelity, x)
			return int2bool(flip(x and fidelity or 1-fidelity))
		end
		local function innerQuery()
			local a = int2bool(flip(0.7))
			condition(bitflip(0.8, a))
			return bool2int(a)
		end
		return rejectionSample(innerQuery)
	end,
	0.903225806451613)

mhtest(
	"trans-dimensional",
	function()
		local a = int2bool(flip(0.9, true)) and beta(1,5) or 0.7
		local b = flip(a)
		condition(int2bool(b))
		return a
	end,
	0.417)

larjtest(
	"trans-dimensional (LARJ)",
	function()
		local a = int2bool(flip(0.9, true)) and beta(1,5) or 0.7
		local b = flip(a)
		condition(int2bool(b))
		return a
	end,
	0.417)

mhtest(
	"memoized flip in if branch (create/destroy memprocs), unconditioned",
	function()
		local a = int2bool(flip()) and mem(flip) or mem(flip)
		local b = a()
		return b
	end,
	0.5)

-- Tests for things specific to new implementation

mhtest(
	"native loop",
	function()
		local accum = 0
		for i=1,4 do
			accum = accum + flip()
		end
		return accum / 4
	end,
	0.5)

mhtest(
	"directly conditioning variable values",
	function()
		local accum = 0
		for i=1,10 do
			if i < 5 then
				accum = accum + flip(0.5, false, 1)
			else
				accum = accum + flip(0.5)
			end 
		end
		return accum / 10
	end,
	0.75)

print("tests done!")

local t2 = os.clock()
print("time: " .. (t2 - t1))


