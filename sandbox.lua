
pr = require("probabilistic")
util = require("probabilistic.util")
erp = require("probabilistic.erp")
util.openpackage(pr)

function circleOfDots()

	-- helpers
	local function norm(v)
		return math.sqrt(v.x*v.x + v.y*v.y)
	end
	local function dist(p1, p2)
		local xdiff = p1.x - p2.x
		local ydiff = p1.y - p2.y
		return math.sqrt(xdiff*xdiff + ydiff*ydiff)
	end
	local function angDP(p1, p2, p3)
		local v1 = { x = p1.x - p2.x, y = p1.y - p2.y}
		local v2 = { x = p3.x - p2.x, y = p3.y - p2.y}
		return (v1.x*v2.x + v1.y*v2.y) / (norm(v1)*norm(v2))
	end

	-- params
	local numDots = 6
	local gmean = 0
	local gsd = 2
	local targetdist = 0.5
	local distsd = 0.1
	local targetdp = -1.0
	local dpsd = 0.1

	-- prior
	local points = {}
	for i=1,numDots do
		table.insert(points, { x = gaussian(gmean, gsd), y = gaussian(gmean, gsd) })
	end

	-- distance between pairs factors
	for i=0,numDots-1 do
		local j = ((i+1) % numDots) + 1
		local d = dist(points[i+1], points[j])
		factor(erp.gaussian_logprob(d, targetdist, distsd))
	end

	-- angle between triples factors
	for i=0,numDots-1 do
		local j = ((i+1) % numDots)+1
		local k = ((i+2) % numDots)+1
		local dp = angDP(points[i+1], points[j], points[k])
		factor(erp.gaussian_logprob(dp, targetdp, dpsd))
	end

	return points
end

-----------

local numsamps = 100000

local res = nil

local t11 = os.clock()
--res = MAP(circleOfDots, LARJMH, numsamps, 1, true, 0)
local t12 = os.clock()

local t21 = os.clock()
res = MAP(circleOfDots, fixedStructureDriftMH, numsamps, 1, true, {}, 0.25)
local t22 = os.clock()

print(string.format("Uncompiled: %g", (t12 - t11)))
print(string.format("Compiled: %g", (t22 - t21)))


local function saveDotCSV(points, filename)
	local f = io.open(filename, "w")
	f:write("dotnum,x,y\n")
	for i,p in ipairs(points) do
		f:write(string.format("%u,%g,%g\n", i, p.x, p.y))
	end
	f:close()
end

saveDotCSV(res, "dotvis/dots.csv")
