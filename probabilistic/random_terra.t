
local cmath = require("probabilistic.cmath")

-- Information about templated Terra functions goes in this array.
-- Entries have the following form:
--    fn: a Lua function which takes a number type and outputs
--        a specialized Terra function for that type.
--    name: the name the specialized function should have.
-- NOTE: Entries must be added to this array in dependency order,
--    as the array will be walked from front to back when specialized
--    code is generated.
local templates = {}

-- All specialized functions will be available as members of this table
local fns = {}

-- Add a new template to the list of templates
local function template(name, fn)
	table.insert(templates, {name=name, fn=fn})
end


-- What's our base RNG?
--local random = terralib.cast({} -> double, math.random)
local random = terralib.includecstring([[
	#include <stdlib.h>
	#define FLT_RAND_MAX 0.999999
	double random_() { return ((double)(rand()) / RAND_MAX)*FLT_RAND_MAX; }
]]).random_


-- Define all the samplers/scorers!

local terra flip_sample(p: double)
	var randval = random()
	if randval < p then
		return 1
	else
		return 0
	end
end

template("flip_logprob",
function(numtype)
	return terra(val: numtype, p: numtype)
		var prob: numtype
		if val ~= 0 then
			prob = p
		else
			prob = 1.0 - p
		end
		return cmath.log(prob)
	end
end)


local terra multinomial_sample_t(params: &double, n: int)
	var sum = 0.0
	for i=0,n do sum = sum + params[i] end
	var result: int = 0
	var x = random() * sum
	var probAccum = 0.00000001
	while result <= n and x > probAccum do
		probAccum = probAccum + params[result]
		result = result + 1
	end
	return result - 1
end

local function multinomial_sample(...)
	local n = select("#", ...)
	local params = terralib.new(double[n], {...})
	return multinomial_sample_t(params, n) + 1	-- Convert from 0- to 1-based indexing
end

template("multinomial_logprob",
function(numtype)
	local terra logprob(val: int, params: &numtype, n: int)
		var sum: numtype = 0.0
		for i=0,n do
			sum = sum + params[i]
		end
		return cmath.log(params[val]/sum)
	end
	return function(val, ...)
		local n = select("#", ...)
		if val < 1 or val > n then return -math.huge end
		local params = terralib.new(numtype[n], {...})
		return logprob(val-1, params, n)	-- Convert from 1- to 0-based indexing
	end
end)


local terra uniform_sample(lo: double, hi: double)
	var u = random()
	return (1.0-u)*lo + u*hi
end

template("uniform_logprob",
function(numtype)
	return terra(val: numtype, lo: numtype, hi: numtype)
		if val < lo or val > hi then return [-math.huge] end
		return -cmath.log(hi - lo)
	end
end)


local terra gaussian_sample(mu: double, sigma: double)
	var u:double, v:double, x:double, y:double, q:double
	repeat
		u = 1.0 - random()
		v = 1.7156 * (random() - 0.5)
		x = u - 0.449871
		y = cmath.fabs(v) + 0.386595
		q = x*x + y*(0.196*y - 0.25472*x)
	until not(q >= 0.27597 and (q > 0.27846 or v*v > -4 * u * u * cmath.log(u)))
	return mu + sigma*v/u
end

template("gaussian_logprob",
function(numtype)
	return terra(x: numtype, mu: numtype, sigma: numtype)
		var xminusmu = x - mu
		return -.5*(1.8378770664093453 + 2*cmath.log(sigma) + xminusmu*xminusmu/(sigma*sigma))
	end
end)


local terra gamma_sample(a: double, b: double) : double
	if a < 1 then return gamma_sample(1+a,b) * cmath.pow(random(), 1.0/a) end
	var x:double, v:double, u:double
	var d = a - 1.0/3
	var c = 1.0/cmath.sqrt(9*d)
	while true do
		repeat
			x = gaussian_sample(0.0, 1.0)
			v = 1+c*x
		until v > 0
		v = v*v*v
		u = random()
		if (u < 1 - .331*x*x*x*x) or (cmath.log(u) < .5*x*x + d*(1 - v + cmath.log(v))) then
			return b*d*v
		end
	end
end

local gamma_cof = terralib.new(double[6], {76.18009172947146, -86.50532032941677, 24.01409824083091, -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5})
template("log_gamma",
function(numtype)
	return terra(xx: numtype)
		var x = xx - 1
		var tmp = x + 5.5
		tmp = tmp - (x + 0.5)*cmath.log(tmp)
		var ser: numtype = 1.000000000190015
		for j=0,5 do
			x = x + 1
			ser = ser + gamma_cof[j] / x
		end
		return -tmp + cmath.log(2.5066282746310005*ser)
	end
end)

template("gamma_logprob",
function(numtype)
	return terra(x: numtype, a: numtype, b:numtype)
		return (a - 1)*cmath.log(x) - x/b - fns.log_gamma(a) - a*cmath.log(b)
	end
end)


local terra beta_sample(a: double, b: double)
	var x = gamma_sample(a, 1)
	return x / (x + gamma_sample(b, 1))
end

template("log_beta",
function(numtype)
	return terra(a: numtype, b: numtype)
		return fns.log_gamma(a) + fns.log_gamma(b) - fns.log_gamma(a+b)
	end
end)

template("beta_logprob",
function(numtype)
	return terra(x: numtype, a: numtype, b: numtype)
		if x > 0 and x < 1 then
			return (a-1)*cmath.log(x) + (b-1)*cmath.log(1-x) - fns.log_beta(a,b)
		else
			return [-math.huge]
		end
	end
end)


local terra binomial_sample(p: double, n: int) : int
	var k:int = 0
	var N:int = 10
	var a:int, b:int
	while n > N do
		a = 1 + n/2
		b = 1 + n-a
		var x = beta_sample(a, b)
		if x >= p then
			n = a - 1
			p = p / x
		else
			k = k + a
			n = b - 1
			p = (p-x) / (1 - x)
		end
	end
	var u:double
	for i=0,n do
		u = random()
		if u < p then k = k + 1 end
	end
	return k
end

template("g",
function(numtype)
	return terra(x: numtype)
		if x == 0 then return 1 end
		if x == 1 then return 0 end
		var d = 1 - x
		return (1 - (x * x) + (2 * x * cmath.log(x))) / (d * d)
	end
end)

template("binomial_logprob",
function(numtype)
	local inv2 = 1/2
	local inv3 = 1/3
	local inv6 = 1/6
	return terra(s: int, p: numtype, n: int)
		if s >= n then return [-math.huge] end
		var q = 1-p
		var S = s + inv2
		var T = n - s - inv2
		var d1 = s + inv6 - (n + inv3) * p
		var d2 = q/(s+inv2) - p/(T+inv2) + (q-inv2)/(n+1)
		d2 = d1 + 0.02*d2
		var num = 1 + q * fns.g(S/(n*p)) + p * fns.g(T/(n*q))
		var den = (n + inv6) * p * q
		var z = num / den
		var invsd = cmath.sqrt(z)
		z = d2 * invsd
		return fns.gaussian_logprob(z, 0, 1) + cmath.log(invsd)
	end
end)


local terra poisson_sample(mu: int)
	var k:int = 0
	while mu > 10 do
		var m = (7.0/8)*mu
		var x = gamma_sample(m, 1)
		if x > mu then
			return k + binomial_sample(mu/x, m-1)
		else
			mu = mu - x
			k = k + 1
		end
	end
	var emu = cmath.exp(-mu)
	var p = 1.0
	while p > emu do
		p = p * random()
		k = k + 1
	end
	return k-1
end


local terra fact(x: int)
	var t:int = 1
	while x > 1 do
		t = t * x
		x = x - 1
	end
	return t	
end


local terra lnfact(x: int)
	if x < 1 then x = 1 end
	if x < 12 then return cmath.log(fact(x)) end
	var invx = 1.0 / x
	var invx2 = invx*invx
	var invx3 = invx2*invx
	var invx5 = invx3*invx2
	var invx7 = invx5*invx2
	var ssum = ((x + 0.5) * cmath.log(x)) - x
	ssum = ssum + cmath.log(2*[math.pi]) / 2.0
	ssum = ssum + (invx / 12) - (invx / 360)
	ssum = ssum + (invx5 / 1260) - (invx7 / 1680)
	return ssum
end


local terra poisson_logprob(k: int, mu: int)
	return k * cmath.log(mu) - mu - lnfact(k)
end


-- Samples a new vector in place by overwriting 'params'
local terra dirichlet_sample_t(params: &double, n: int)
	var ssum = 0.0
	for i=0,n do
		var t = gamma_sample(params[i], 1)
		params[i] = t
		ssum = ssum + t
	end
	for i=0,n do
		params[i] = params[i] / ssum
	end
end

local function dirichlet_sample(...)
	local n = select("#", ...)
	local params = terralib.new(double[n], {...})
	dirichlet_sample_t(params, n)
	local result = {}
	for i=0,n do result[i+1] = params[i] end
	return result
end

template("dirichlet_logprob",
function(numtype)
	local terra logprob(theta: &double, params: &double, n: int)
		var sum: numtype = 0.0
		for i=0,n do sum = sum + params[i] end
		var logp = fns.log_gamma(sum)
		for i=0,n do
			var a = params[i]
			logp = logp + (a - 1)*cmath.log(theta[i])
			logp = logp - fns.log_gamma(a)
		end
		return logp
	end
	return function(theta, ...)
		local n = select("#", ...)
		local thetaArray = terralib.new(numtype[n], theta)
		local paramArray = terralib.new(numtype[n], {...})
		return logprob(thetaArray, paramArray, n)
	end
end)





-- Here, we walk through the set of templates and generate specialized code for
-- all the number types we care about
local numtypes = {double}
for i,template in ipairs(templates) do
	-- Generate a function for the first type
	fns[template.name] = template.fn(numtypes[1])
	-- Add additional definitons for any other types
	for ntype=2,table.getn(numtypes) do
		fns[template.name]:adddefinition(template.fn(ntype))
	end
end



-- Module exports
return
{
	-- flip_sample = flip_sample,
	-- flip_logprob = fns.flip_logprob,
	-- multinomial_sample = multinomial_sample,
	-- multinomial_logprob = fns.multinomial_logprob,
	uniform_sample = uniform_sample,
	uniform_logprob = fns.uniform_logprob,
	gaussian_sample = gaussian_sample,
	gaussian_logprob = fns.gaussian_logprob,
	gamma_sample = gamma_sample,
	gamma_logprob = fns.gamma_logprob,
	beta_sample = beta_sample,
	beta_logprob = fns.beta_logprob--,
	-- binomial_sample = binomial_sample,
	-- binomial_logprob = fns.binomial_logprob,
	-- poisson_sample = poisson_sample,
	-- poisson_logprob = poisson_logprob,
	-- dirichlet_sample = dirichlet_sample,
	-- dirichlet_logprob = fns.dirichlet_logprob
}
