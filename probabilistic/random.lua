local util = require("probabilistic.util")


local function flip_sample(p)
	local randval = math.random()
	return (randval < p) and 1 or 0
end

local function flip_logprob(val, p)
	local prob = (val ~= 0) and p or 1.0-p
	return math.log(prob)
end


local function multinomial_sample(...)
	local result = 1
	local x = math.random() * util.sum(...)
	local probAccum = 0.00000001
	local k = select("#", ...)
	while result <= k and x > probAccum do
		probAccum = probAccum + select(result, ...)
		result = result + 1
	end
	return result - 1
end

local function multinomial_logprob(n, ...)
	if n < 1 or n > select("#", ...) then
		return -math.huge
	else
		n = math.ceil(n)
		return math.log(select(n, ...)/util.sum(...))
	end
end


function uniform_sample(lo, hi)
	local u = math.random()
	return (1-u)*lo + u*hi
end

function uniform_logprob(val, lo, hi)
	if val < lo or val > hi then return -math.huge end
	return -math.log(hi - lo)
end


local function gaussian_sample(mu, sigma)
	local u, v, x, y, q
	repeat
		u = 1 - math.random()
		v = 1.7156 * (math.random() - 0.5)
		x = u - 0.449871
		y = math.abs(v) + 0.386595
		q = x*x + y*(0.196*y - 0.25472*x)
	until not(q >= 0.27597 and (q > 0.27846 or v*v > -4 * u * u * math.log(u)))
	return mu + sigma*v/u
end

local function gaussian_logprob(x, mu, sigma)
	local xminusmu = x - mu
	return -.5*(1.8378770664093453 + 2*math.log(sigma) + xminusmu*xminusmu/(sigma*sigma))
end


local function gamma_sample(a, b)
	if a < 1 then return gamma_sample(1+a,b) * math.pow(math.random(), 1/a) end
	local x, v, u
	local d = a - 1/3
	local c = 1/math.sqrt(9*d)
	while true do
		repeat
			x = gaussian_sample(0, 1)
			v = 1+c*x
		until v > 0
		v = v*v*v
		u = math.random()
		if (u < 1 - .331*x*x*x*x) or (math.log(u) < .5*x*x + d*(1 - v + math.log(v))) then
			return b*d*v
		end
	end
end

local gamma_cof = {76.18009172947146, -86.50532032941677, 24.01409824083091, -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5}
local function log_gamma(xx)
	local x = xx - 1
	local tmp = x + 5.5
	tmp = tmp - (x + 0.5)*math.log(tmp)
	local ser = 1.000000000190015
	for j=1,5 do
		x = x + 1
		ser = ser + gamma_cof[j] / x
	end
	return -tmp + math.log(2.5066282746310005*ser)
end

local function gamma_logprob(x, a, b)
	return (a - 1)*math.log(x) - x/b - log_gamma(a) - a*math.log(b)
end


local function beta_sample(a, b)
	local x = gamma_sample(a, 1)
	return x / (x + gamma_sample(b, 1))	
end

local function log_beta(a, b)
	return log_gamma(a) + log_gamma(b) - log_gamma(a+b)
end

local function beta_logprob(x, a, b)
	if x > 0 and x < 1 then
		return (a-1)*math.log(x) + (b-1)*math.log(1-x) - log_beta(a,b)
	else
		return -math.huge
	end
end


local function binomial_sample(p, n)
	local k = 0
	local N = 10
	local a, b
	while n > N do
		a = 1 + math.floor(n/2)
		b = 1 + n-a
		local x = beta_sample(a, b)
		if x >= p then
			n = a - 1
			p = p / x
		else
			k = k + a
			n = b - 1
			p = (p-x) / (1 - x)
		end
	end
	local u = 0
	for i=1,n do
		u = math.random()
		if u < p then k = k + 1 end
	end
	return k
end

local function g(x)
	if x == 0 then return 1 end
	if x == 1 then return 0 end
	local d = 1 - x
	return (1 - (x * x) + (2 * x * math.log(x))) / (d * d)
end

local function binomial_logprob(s, p, n)
	local inv2 = 1/2
	local inv3 = 1/3
	local inv6 = 1/6
	if s >= n then return -math.huge end
	local q = 1-p
	local S = s + inv2
	local T = n - s - inv2
	local d1 = s + inv6 - (n + inv3) * p
	local d2 = q/(s+inv2) - p/(T+inv2) + (q-inv2)/(n+1)
	d2 = d1 + 0.02*d2
	local num = 1 + q * g(S/(n*p)) + p * g(T/(n*q))
	local den = (n + inv6) * p * q
	local z = num / den
	local invsd = math.sqrt(z)
	z = d2 * invsd
	return gaussian_logprob(z, 0, 1) + math.log(invsd)
end


local function poisson_sample(mu)
	local k = 0
	while mu > 10 do
		local m = 7/8*mu
		local x = gamma_sample(m, 1)
		if x > mu then
			return k + binomial_sample(mu/x, m-1)
		else
			mu = mu - x
			k = k + 1
		end
	end
	local emu = math.exp(-mu)
	local p = 1
	while p > emu do
		p = p * math.random()
		k = k + 1
	end
	return k-1
end

local function fact(x)
	local t = 1
	while x > 1 do
		t = t * x
		x = x - 1
	end
	return t
end

local function lnfact(x)
	if x < 1 then x = 1 end
	if x < 12 then return math.log(fact(math.floor(x))) end
	local invx = 1 / x
	local invx2 = invx*invx
	local invx3 = invx2*invx
	local invx5 = invx3*invx2
	local invx7 = invx5*invx2
	local ssum = ((x + 0.5) * math.log(x)) - x
	ssum = ssum + math.log(2*math.pi) / 2.0
	ssum = ssum + (invx / 12) - (invx / 360)
	ssum = ssum + (invx5 / 1260) - (invx7 / 1680)
	return ssum
end

local function poisson_logprob(k, mu)
	return k * math.log(mu) - mu - lnfact(k)
end


local function dirichlet_sample(...)
	local ssum = 0
	local theta = {}
	local n = select("#", ...)
	for i=1,n do
		local t = gamma_sample(select(i, ...), 1)
		table.insert(theta, t)
		ssum = ssum + t
	end
	for i,t in ipairs(theta) do
		theta[i] = theta[i] / ssum
	end
	return theta
end

local function dirichlet_logprob(theta, ...)
	local logp = log_gamma(util.sum(...))
	for i=1,select("#", ...) do
		local a = select(i, ...)
		logp = logp + (a - 1)*math.log(theta[i])
		logp = logp - log_gamma(a)
	end
	return logp
end


-- exports
local random = 
{
	flip_sample = flip_sample,
	flip_logprob = flip_logprob,
	multinomial_sample = multinomial_sample,
	multinomial_logprob = multinomial_logprob,
	uniform_sample = uniform_sample,
	uniform_logprob = uniform_logprob,
	gaussian_sample = gaussian_sample,
	gaussian_logprob = gaussian_logprob,
	gamma_sample = gamma_sample,
	gamma_logprob = gamma_logprob,
	beta_sample = beta_sample,
	beta_logprob = beta_logprob,
	binomial_sample = binomial_sample,
	binomial_logprob = binomial_logprob,
	poisson_sample = poisson_sample,
	poisson_logprob = poisson_logprob,
	dirichlet_sample = dirichlet_sample,
	dirichlet_logprob = dirichlet_logprob
}


-- If we're running under Terra, then use the compiled samplers/scorers
-- instead of the interpreted ones below.
local randomt = nil
--randomt = util.guardedTerraRequire("probabilistic.random_terra")
if randomt then
	for name,fn in pairs(random) do
		local tfn = randomt[name]
		if tfn then
			random[name] = tfn
		end
	end
end


return random