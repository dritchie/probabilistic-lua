local trace = require "probabilistic.trace"

module(..., package.seeall)


function mean(values)
	local m = values[1]
	local n = table.getn(values)
	for i=2,n do
		m = m + values[i]
	end
	return m / n
end