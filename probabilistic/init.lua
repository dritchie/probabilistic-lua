local trace = require "probabilistic.trace"
local erp = require "probabilistic.erp"

module(...)

-- Forward the trace exports
factor = trace.factor
condition = trace.condition

-- Forward the ERP exports
flip = erp.flip