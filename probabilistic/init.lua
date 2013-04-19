local trace = require "probabilistic.trace"
local erp = require "probabilistic.erp"
local inference = require "probabilistic.inference"
local control = require "probabilistic.control"
local memoize = require "probabilistic.memoize"

module(...)

-- Forward trace exports
factor = trace.factor
condition = trace.condition

-- Forward ERP exports
flip = erp.flip
multinomial = erp.multinomial
multinomialDraw = erp.multinomialDraw
uniformDraw = erp.uniformDraw
uniform = erp.uniform
gaussian = erp.gaussian
gamma = erp.gamma
beta = erp.beta
binomial = erp.binomial
poisson = erp.poisson
dirichlet = erp.dirichlet

-- Forward inference exports
mean = inference.mean
distrib = inference.distrib
expectation = inference.expectation
MAP = inference.MAP
rejectionSample = inference.rejectionSample
traceMH = inference.traceMH

-- Forward control exports
ntimes = control.ntimes
foreach = control.foreach
whilst = control.whilst
replicate = control.replicate

-- Forward mem export
mem = memoize.mem