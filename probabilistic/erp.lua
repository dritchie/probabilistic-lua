local dirOfThisFile = (...):match("(.-)[^%.]+$")

local trace = require(dirOfThisFile .. "trace")
local util = require(dirOfThisFile .. "util")

module(..., package.seeall)

-- Code for computing log probabilities should be converted to Terra functions

-- Abstract base class for all ERPs
local RandomPrimitive = {}

function RandomPrimitive:new()
	local newobj = {}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function RandomPrimitive:sample_impl(params)
	error("ERP subclasses must implement sample_impl!")
end

function RandomPrimitive:logprob(val, params)
	error("ERP subclasses must implement logprob!")
end

function RandomPrimitive:sample(params, isStructural, conditionedValue, annotation)
	-- NOTE: The 4th arg is 0 instead of 2 because the calls to 'sample'
	-- and 'lookupVariableValue' are both tail calls
	return trace.lookupVariableValue(self, params, isStructural, 0, conditionedValue, annotation)
end

function RandomPrimitive:proposal(currval, params)
	-- Subclasses can override to do more efficient proposals
	return self:sample_impl(params)
end

function RandomPrimitive:logProposalProb(currval, propval, params)
	-- Subclasses can override to do more efficient proposals
	return self:logprob(propval, params)
end

-------------------

local FlipRandomPrimitive = RandomPrimitive:new()

function FlipRandomPrimitive:sample_impl(params)
	local randval = math.random()
	return (randval < params[1]) and 1 or 0
end

function FlipRandomPrimitive:logprob(val, params)
	local p = params[1]
	local prob = (val ~= 0) and p or 1.0-p
	return math.log(prob)
end

function FlipRandomPrimitive:proposal(currval, params)
	return (currval == 0) and 1 or 0
end

function FlipRandomPrimitive:logProposalProb(currval, propval, params)
	return 0.0
end

local flipInst = FlipRandomPrimitive:new()
function flip(p, isStructural, conditionedValue)
	p = (p == nil) and 0.5 or p
	return flipInst:sample({p}, isStructural, conditionedValue)
end

-------------------

local MultinomialRandomPrimitive = RandomPrimitive:new()

local function multinomial_sample(theta)
	local result = 1
	local x = math.random() * util.sum(theta)
	local probAccum = 0.00000001
	local k = table.getn(theta)
	while result <= k and x > probAccum do
		probAccum = probAccum + theta[result]
		result = result + 1
	end
	return result - 1
end

function multinomial_logprob(n, theta)
	if n < 1 or n > table.getn(theta) then
		return -math.huge
	else
		n = math.ceil(n)
		return math.log(theta[n]/util.sum(theta))
	end
end

function MultinomialRandomPrimitive:sample_impl(params)
	return multinomial_sample(params)
end

function MultinomialRandomPrimitive:logprob(val, params)
	return multinomial_logprob(val, params)
end

-- Multinomial with currval projected out
function MultinomialRandomPrimitive:proposal(currval, params)
	local newparams = util.copytable(params)
	newparams[currval] = 0
	return multinomial_sample(newparams)
end

-- Multinomial with currval projected out
function MultinomialRandomPrimitive:logProposalProb(currval, propval, params)
	local newparams = util.copytable(params)
	newparams[currval] = 0
	return multinomial_logprob(propval, newparams)
end

local multinomialInst = MultinomialRandomPrimitive:new()
function multinomial(theta, isStructural, conditionedValue)
	return multinomialInst:sample(theta, isStructural, conditionedValue)
end

function multinomialDraw(items, probs, isStructural)
	return items[multinomial(probs, isStructural)]
end

function uniformDraw(items, isStructural)
	local n = table.getn(items)
	local invn = 1/n
	local probs = {}
	for i=1,n do
		table.insert(probs, invn)
	end
	return items[multinomial(probs, isStructural)]
end

-------------------

local UniformRandomPrimitive = RandomPrimitive:new()

function UniformRandomPrimitive:sample_impl(params)
	local u = math.random()
	return (1-u)*params[1] + u*params[2]
end

function UniformRandomPrimitive:logprob(val, params)
	if val < params[1] or val > params[2] then return -math.huge end
	return -math.log(params[2] - params[1])
end

local uniformInst = UniformRandomPrimitive:new()
function uniform(lo, hi, isStructural, conditionedValue)
	return uniformInst:sample({lo, hi}, isStructural, conditionedValue)
end

-------------------

local GaussianRandomPrimitive = RandomPrimitive:new()

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

function gaussian_logprob(x, mu, sigma)
	return -.5*(1.8378770664093453 + 2*math.log(sigma) + (x - mu)*(x - mu)/(sigma*sigma))
end

function GaussianRandomPrimitive:sample_impl(params)
	return gaussian_sample(unpack(params))
end

function GaussianRandomPrimitive:logprob(val, params)
	return gaussian_logprob(val, unpack(params))
end

-- Drift kernel
function GaussianRandomPrimitive:propval(currval, params)
	return gaussian_sample(currval, params[2])
end

-- Drift kernel
function GaussianRandomPrimitive:logProposalProb(currval, propval, params)
	return gaussian_logprob(propval, currval, params[2])
end

local gaussianInst = GaussianRandomPrimitive:new()
function gaussian(mu, sigma, isStructural, conditionedValue)
	return gaussianInst:sample({mu, sigma}, isStructural, conditionedValue)
end

--------------------

local GammaRandomPrimitive = RandomPrimitive:new()

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

function gamma_logprob(x, a, b)
	return (a - 1)*math.log(x) - x/b - log_gamma(a) - a*math.log(b)
end

function GammaRandomPrimitive:sample_impl(params)
	return gamma_sample(unpack(params))
end

function GammaRandomPrimitive:logprob(val, params)
	return gamma_logprob(val, unpack(params))
end

local gammaInst = GammaRandomPrimitive:new()
function gamma(a, b, isStructural, conditionedValue)
	return gammaInst:sample({a, b}, isStructural, conditionedValue)
end

-----------------------

local BetaRandomPrimitive = RandomPrimitive:new()

local function beta_sample(a, b)
	local x = gamma_sample(a, 1)
	return x / (x + gamma_sample(b, 1))	
end

local function log_beta(a, b)
	return log_gamma(a) + log_gamma(b) - log_gamma(a+b)
end

function beta_logprob(x, a, b)
	if x > 0 and x < 1 then
		return (a-1)*math.log(x) + (b-1)*math.log(1-x) - log_beta(a,b)
	else
		return -math.huge
	end
end

function BetaRandomPrimitive:sample_impl(params)
	return beta_sample(unpack(params))
end

function BetaRandomPrimitive:logprob(val, params)
	return beta_logprob(val, unpack(params))
end

local betaInst = BetaRandomPrimitive:new()
function beta(a, b, isStructural, conditionedValue)
	return betaInst:sample({a, b}, isStructural, conditionedValue)
end

------------------------

local BinomialRandomPrimitive = RandomPrimitive:new()

local function binomial_sample(p, n)
	local k = 0
	local N = 10
	local a, b
	while n > N do
		a = 1 + math.floor(n/2)
		b = 1 + n-a
		x = beta_sample(a, b)
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

function binomial_logprob(s, p, n)
	local inv2 = 1/2
	local inv3 = 1/3
	local inv6 = 1/6
	if s >= n then return -math.huge end
	local q = 1-p
	local S = s + inv2
	local T = n - s - inv2
	local d1 = s + inv6 - (n + inv3) * p
	local d2 = q/(s+inv2) - p/(T+inv2) + (q-inv2)/(n+1)
	local d2 = d1 + 0.02*d2
	local num = 1 + q * g(S/(n*p)) + p * g(T/(n*q))
	local den = (n + inv6) * p * q
	local z = num / den
	local invsd = math.sqrt(z)
	z = d2 * invsd
	return gaussian_logprob(z, 0, 1) + math.log(invsd)
end

function BinomialRandomPrimitive:sample_impl(params)
	return binomial_sample(unpack(params))
end

function BinomialRandomPrimitive:logprob(val, params)
	return binomial_logprob(val, unpack(params))
end

local binomialInst = BinomialRandomPrimitive:new()
function binomial(p, n, isStructural, conditionedValue)
	return binomialInst:sample({p, n}, isStructural, conditionedValue)
end

----------------------

local PoissonRandomPrimitive = RandomPrimitive:new()

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

function poisson_logprob(k, mu)
	return k * math.log(mu) - mu - lnfact(k)
end

function PoissonRandomPrimitive:sample_impl(params)
	return poisson_sample(params[1])
end

function PoissonRandomPrimitive:logprob(val, params)
	return poisson_logprob(val, params[1])
end

local poissonInst = PoissonRandomPrimitive:new()
function poisson(mu, isStructural, conditionedValue)
	return poissonInst:sample({mu}, isStructural, conditionedValue)
end

---------------------

local DirichletRandomPrimitive = RandomPrimitive:new()

local function dirichlet_sample(alpha)
	local ssum = 0
	local theta = {}
	for i,a in ipairs(alpha) do
		local t = gamma_sample(a, 1)
		table.insert(theta, t)
		ssum = ssum + t
	end
	for i,t in ipairs(theta) do
		theta[i] = theta[i] / ssum
	end
	return theta
end

function dirichlet_logprob(theta, alpha)
	local logp = log_gamma(util.sum(alpha))
	for i=1,table.getn(alpha) do
		logp = logp + (alpha[i] - 1)*math.log(theta[i])
		logp = logp - log_gamma(alpha[i])
	end
	return logp
end

function DirichletRandomPrimitive:sample_impl(params)
	return dirichlet_sample(params)
end

function DirichletRandomPrimitive:logprob(val, params)
	return dirichlet_logprob(val, params)
end

local dirichletInst = DirichletRandomPrimitive:new()
function dirichlet(alpha, isStructural, conditionedValue)
	return dirichletInst:sample(alpha, isStructural, conditionedValue)
end


